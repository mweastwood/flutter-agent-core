import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ai_service.dart';
import 'json_utils.dart';

final _reTruncatedTerminator = RegExp(r'[.!?}]');
final _reTruncatedContinue = RegExp(r'[a-zA-Z0-9,"-]');
final _reLeadingNewlines = RegExp(r'^\r?\n+');
final _reTrailingNewlines = RegExp(r'\r?\n+$');
final _reConversationalHeader = RegExp(
  r'^[a-zA-Z\s\n]+[:.]\s*(?=[{\["",\-\]])',
);
final _reCommonConversationalHeaders = [
  RegExp(r'^\s*here is the continuation:\s*', caseSensitive: false),
  RegExp(r'^\s*continuing:\s*', caseSensitive: false),
  RegExp(r'^\s*continuation:\s*', caseSensitive: false),
];

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
  final isEndingPunctuation = _reTruncatedTerminator.hasMatch(lastChar);
  if (!isEndingPunctuation) {
    if (_reTruncatedContinue.hasMatch(lastChar)) {
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
  cleaned = cleaned.replaceFirst(_reLeadingNewlines, '');
  cleaned = cleaned.replaceFirst(_reTrailingNewlines, '');

  // Remove conversational headers ending with colon or period followed by structural JSON chars or list item markers
  cleaned = cleaned.replaceFirst(_reConversationalHeader, '');
  cleaned = cleaned.replaceFirst(_reLeadingNewlines, '');

  // Remove common conversational headers
  for (final header in _reCommonConversationalHeaders) {
    if (cleaned.startsWith(header)) {
      cleaned = cleaned.replaceFirst(header, '');
    }
  }

  return cleaned;
}

List<int> _buildKmpFailureTable(String pattern) {
  final failure = List<int>.filled(pattern.length, 0);
  var j = 0;
  for (var i = 1; i < pattern.length; i++) {
    while (j > 0 && pattern.codeUnitAt(i) != pattern.codeUnitAt(j)) {
      j = failure[j - 1];
    }
    if (pattern.codeUnitAt(i) == pattern.codeUnitAt(j)) {
      j++;
    }
    failure[i] = j;
  }
  return failure;
}

@visibleForTesting
String stitchContinuation(String text, String nextText) {
  final textLen = text.length;
  final nextLen = nextText.length;

  if (textLen < 3 || nextLen < 3) {
    return text + nextText;
  }

  final pattern = nextLen > 500 ? nextText.substring(0, 500) : nextText;
  final failure = _buildKmpFailureTable(pattern);

  final start = textLen > 550 ? textLen - 550 : 0;
  final count = textLen - start;
  final states = List<int>.filled(count, 0);

  var j = 0;
  for (var i = start; i < textLen; i++) {
    final code = text.codeUnitAt(i);
    while (j > 0 && (j == pattern.length || code != pattern.codeUnitAt(j))) {
      j = failure[j - 1];
    }
    if (code == pattern.codeUnitAt(j)) {
      j++;
    }
    states[i - start] = j;
  }

  final maxOffset = textLen < 50 ? textLen : 50;
  for (var offset = 0; offset < maxOffset; offset++) {
    final subTextLen = textLen - offset;
    if (subTextLen < 3) break;

    final overlap = states[subTextLen - 1 - start];
    if (overlap >= 3) {
      final prefixPart = offset == 0 ? text : text.substring(0, subTextLen);
      return prefixPart + nextText.substring(overlap);
    }
  }

  return text + nextText;
}

enum _ContainerType { object, array }

enum _ObjectState {
  expectingKey,
  expectingColon,
  expectingValue,
  expectingCommaOrClose,
}

enum _ArrayState { expectingValue, expectingCommaOrClose }

class _StackFrame {
  final _ContainerType type;
  _ObjectState objectState;
  _ArrayState arrayState;
  int lastCompleteEntryEndPos;
  int lastCommaPos;

  _StackFrame.object(this.lastCompleteEntryEndPos)
    : type = _ContainerType.object,
      objectState = _ObjectState.expectingKey,
      arrayState = _ArrayState.expectingValue,
      lastCommaPos = -1;

  _StackFrame.array(this.lastCompleteEntryEndPos)
    : type = _ContainerType.array,
      objectState = _ObjectState.expectingKey,
      arrayState = _ArrayState.expectingValue,
      lastCommaPos = -1;
}

@visibleForTesting
String repairJson(String json) {
  if (json.isEmpty) return '';

  final stack = <_StackFrame>[];
  final output = <String>[];

  void onValueCompleted(int endPos) {
    if (stack.isNotEmpty) {
      final top = stack.last;
      if (top.type == _ContainerType.object) {
        top.objectState = _ObjectState.expectingCommaOrClose;
        top.lastCompleteEntryEndPos = endPos;
      } else {
        top.arrayState = _ArrayState.expectingCommaOrClose;
        top.lastCompleteEntryEndPos = endPos;
      }
    }
  }

  var i = 0;
  while (i < json.length) {
    final char = json[i];

    if (char == ' ' || char == '\t' || char == '\r' || char == '\n') {
      output.add(char);
      i++;
      continue;
    }

    if (char == '"') {
      output.add('"');
      i++;
      var escape = false;
      var stringClosed = false;
      while (i < json.length) {
        final strChar = json[i];
        output.add(strChar);
        i++;
        if (escape) {
          escape = false;
        } else if (strChar == r'\') {
          escape = true;
        } else if (strChar == '"') {
          stringClosed = true;
          break;
        }
      }

      if (!stringClosed) {
        if (escape) {
          output.add(r'\');
        }
        output.add('"');
      }

      if (stack.isNotEmpty) {
        final top = stack.last;
        if (top.type == _ContainerType.object) {
          if (top.objectState == _ObjectState.expectingKey) {
            top.objectState = _ObjectState.expectingColon;
          } else if (top.objectState == _ObjectState.expectingValue) {
            top.objectState = _ObjectState.expectingCommaOrClose;
            top.lastCompleteEntryEndPos = output.length;
          }
        } else {
          if (top.arrayState == _ArrayState.expectingValue) {
            top.arrayState = _ArrayState.expectingCommaOrClose;
            top.lastCompleteEntryEndPos = output.length;
          }
        }
      }
      continue;
    }

    if (char == '{') {
      output.add('{');
      i++;
      stack.add(_StackFrame.object(output.length));
      continue;
    }

    if (char == '[') {
      output.add('[');
      i++;
      stack.add(_StackFrame.array(output.length));
      continue;
    }

    if (char == ':') {
      output.add(':');
      i++;
      if (stack.isNotEmpty && stack.last.type == _ContainerType.object) {
        if (stack.last.objectState == _ObjectState.expectingColon) {
          stack.last.objectState = _ObjectState.expectingValue;
        }
      }
      continue;
    }

    if (char == ',') {
      output.add(',');
      i++;
      if (stack.isNotEmpty) {
        final top = stack.last;
        top.lastCommaPos = output.length - 1;
        if (top.type == _ContainerType.object) {
          top.objectState = _ObjectState.expectingKey;
        } else {
          top.arrayState = _ArrayState.expectingValue;
        }
      }
      continue;
    }

    if (char == '}') {
      while (stack.isNotEmpty && stack.last.type != _ContainerType.object) {
        final frame = stack.removeLast();
        if (frame.arrayState == _ArrayState.expectingValue &&
            frame.lastCommaPos != -1) {
          output.length = frame.lastCompleteEntryEndPos;
        }
        output.add(']');
      }

      if (stack.isNotEmpty && stack.last.type == _ContainerType.object) {
        stack.removeLast();
        output.add('}');
        i++;
        onValueCompleted(output.length);
      } else {
        output.add('}');
        i++;
      }
      continue;
    }

    if (char == ']') {
      while (stack.isNotEmpty && stack.last.type == _ContainerType.object) {
        final frame = stack.removeLast();
        if (frame.objectState != _ObjectState.expectingCommaOrClose) {
          output.length = frame.lastCompleteEntryEndPos;
        }
        output.add('}');
        if (stack.isNotEmpty) {
          onValueCompleted(output.length);
        }
      }

      if (stack.isNotEmpty && stack.last.type == _ContainerType.array) {
        final frame = stack.removeLast();
        if (frame.arrayState == _ArrayState.expectingValue &&
            frame.lastCommaPos != -1) {
          output.length = frame.lastCompleteEntryEndPos;
        }
        output.add(']');
        i++;
        onValueCompleted(output.length);
      } else {
        output.add(']');
        i++;
      }
      continue;
    }

    // Literals (numbers, boolean, null)
    while (i < json.length && !'{}[]:, \t\r\n"'.contains(json[i])) {
      output.add(json[i]);
      i++;
    }
    onValueCompleted(output.length);
  }

  while (stack.isNotEmpty) {
    final frame = stack.removeLast();
    if (frame.type == _ContainerType.object) {
      if (frame.objectState != _ObjectState.expectingCommaOrClose) {
        output.length = frame.lastCompleteEntryEndPos;
      }
      output.add('}');
      if (stack.isNotEmpty) {
        onValueCompleted(output.length);
      }
    } else {
      if (frame.arrayState == _ArrayState.expectingValue &&
          frame.lastCommaPos != -1) {
        output.length = frame.lastCompleteEntryEndPos;
      }
      output.add(']');
      if (stack.isNotEmpty) {
        onValueCompleted(output.length);
      }
    }
  }

  return output.join();
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
