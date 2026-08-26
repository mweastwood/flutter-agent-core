import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ai_service.dart';
import 'json_utils.dart';

@visibleForTesting
bool isTruncatedHeuristic(String text, bool nativeIsTruncated) {
  if (nativeIsTruncated) return true;

  final trimmed = text.trim();
  if (trimmed.isEmpty) return false;

  // JSON heuristic: starts with JSON structural character but does not end with one
  final startsWithJson = trimmed.startsWith('[') || trimmed.startsWith('{');
  if (startsWithJson) {
    final endsWithJson = trimmed.endsWith(']') || trimmed.endsWith('}');
    if (!endsWithJson) {
      return true;
    }
  }

  // Code fence heuristic: has opening code fence but not closing, or ends inside one
  if (trimmed.contains('```') && !trimmed.endsWith('```')) {
    return true;
  }

  // Alphanumeric/comma end heuristic: if it ends with a letter, digit, comma, or open quote
  // and does not have ending punctuation, it might be truncated.
  final lastChar = trimmed.substring(trimmed.length - 1);
  final isEndingPunctuation = RegExp(r'[.!?}]').hasMatch(lastChar);
  if (!isEndingPunctuation) {
    if (RegExp(r'[a-zA-Z0-9,"\-]').hasMatch(lastChar)) {
      return true;
    }
  }

  return false;
}

@visibleForTesting
String cleanContinuationChunk(String chunk) {
  var cleaned = chunk;

  // Strip code fences if present
  if (cleaned.trimLeft().startsWith('```') ||
      cleaned.trimRight().endsWith('```')) {
    cleaned = stripMarkdownCodeFences(cleaned);
  }

  // Strip leading and trailing newlines (preserving spaces)
  cleaned = cleaned.replaceFirst(RegExp(r'^\r?\n+'), '');
  cleaned = cleaned.replaceFirst(RegExp(r'\r?\n+$'), '');

  // Remove conversational headers ending with colon or period followed by structural JSON chars or list item markers
  cleaned = cleaned.replaceFirst(
    RegExp(r'^[a-zA-Z\s\n]+[:.]\s*(?=[{\["",\-\]])'),
    '',
  );
  cleaned = cleaned.replaceFirst(RegExp(r'^\r?\n+'), '');

  // Remove common conversational headers
  final headers = [
    RegExp(r'^\s*here is the continuation:\s*', caseSensitive: false),
    RegExp(r'^\s*continuing:\s*', caseSensitive: false),
    RegExp(r'^\s*continuation:\s*', caseSensitive: false),
  ];
  for (final header in headers) {
    if (cleaned.startsWith(header)) {
      cleaned = cleaned.replaceFirst(header, '');
    }
  }

  return cleaned;
}

@visibleForTesting
String stitchContinuation(String text, String nextText) {
  final textLen = text.length;
  final nextLen = nextText.length;

  for (var offset = 0; offset < 50; offset++) {
    if (textLen <= offset) break;
    final subTextLen = textLen - offset;

    var maxOverlap = subTextLen < nextLen ? subTextLen : nextLen;
    if (maxOverlap > 500) {
      maxOverlap = 500;
    }
    for (var i = maxOverlap; i >= 3; i--) {
      final textStart = subTextLen - i;
      var match = true;
      for (var k = 0; k < i; k++) {
        if (text.codeUnitAt(textStart + k) != nextText.codeUnitAt(k)) {
          match = false;
          break;
        }
      }
      if (match) {
        final prefixPart = offset == 0 ? text : text.substring(0, subTextLen);
        return prefixPart + nextText.substring(i);
      }
    }
  }

  return text + nextText;
}

@visibleForTesting
String repairJson(String json) {
  var inString = false;
  var escape = false;
  final stack = <String>[];
  final result = StringBuffer();

  for (var i = 0; i < json.length; i++) {
    final char = json[i];
    if (escape) {
      escape = false;
      result.write(char);
      continue;
    }
    if (char == '\\') {
      escape = true;
      result.write(char);
      continue;
    }
    if (char == '"') {
      inString = !inString;
      result.write(char);
      continue;
    }
    if (inString) {
      result.write(char);
      continue;
    }

    if (char == '{' || char == '[') {
      stack.add(char);
      result.write(char);
    } else if (char == '}') {
      if (stack.isNotEmpty && stack.last == '{') {
        stack.removeLast();
      }
      result.write(char);
    } else if (char == ']') {
      while (stack.isNotEmpty && stack.last == '{') {
        result.write('}');
        stack.removeLast();
      }
      if (stack.isNotEmpty && stack.last == '[') {
        stack.removeLast();
      }
      result.write(char);
    } else {
      result.write(char);
    }
  }

  if (escape) {
    result.write(r'\');
  }
  if (inString) {
    result.write('"');
  }

  while (stack.isNotEmpty) {
    final open = stack.removeLast();
    if (open == '{') {
      result.write('}');
    } else if (open == '[') {
      result.write(']');
    }
  }

  return result.toString();
}

Future<String?> runWithAutoContinuation({
  required String initialPrompt,
  required int autoContinueLimit,
  required Future<AiResponse?> Function(String prompt) runCompletion,
}) async {
  var response = await runCompletion(initialPrompt);
  if (response == null) return null;
  if (response.isError) return response.text;

  var text = response.text;
  var isTruncated = isTruncatedHeuristic(text, response.isTruncated);
  var continuationCount = 0;

  while (isTruncated && continuationCount < autoContinueLimit) {
    continuationCount++;
    final continuationPrompt =
        '$initialPrompt\n\n'
        '[Assistant (Partial Response)]: $text\n\n'
        '[System: Your previous response was truncated. Continue generating the response from where you left off, starting with the next character, without repeating the partial response or adding introductions/explanations.]';

    final nextResponse = await runCompletion(continuationPrompt);
    if (nextResponse == null) break;
    if (nextResponse.isError) break;

    final nextText = cleanContinuationChunk(nextResponse.text);
    text = stitchContinuation(text, nextText);
    isTruncated = isTruncatedHeuristic(nextText, nextResponse.isTruncated);
  }

  final trimmed = text.trim();
  if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
    return repairJson(text);
  }
  return text;
}
