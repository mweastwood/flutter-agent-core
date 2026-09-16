export 'json_repair.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ai_service.dart';
import 'json_utils.dart';

final _reTruncatedTerminator = RegExp(r'[.!?}\]]');
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

  // JSON heuristic: starts with JSON structural character but does not end with matching delimiter
  if (trimmed.startsWith('{') && !trimmed.endsWith('}')) {
    return true;
  }
  if (trimmed.startsWith('[') && !trimmed.endsWith(']')) {
    return true;
  }

  // Code fence heuristic: starts with opening code fence but not closed at the end
  if (trimmed.startsWith('```') && !trimmed.endsWith('```')) {
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
    // ignore: invalid_use_of_visible_for_testing_member
    return repairJson(text);
  }
  return text;
}
