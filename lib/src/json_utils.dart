import 'dart:convert';

final RegExp _singleLineFenceRegex = RegExp(
  r'^```[a-zA-Z0-9_-]*\s*([\s\S]*?)\s*```$',
);

final RegExp _unclosedSingleLineFenceRegex = RegExp(
  r'^```[a-zA-Z0-9_-]*\s*(.*)$',
);

/// Strips markdown code fences (e.g. ```json ... ```) wrapping [text].
///
/// Handles optional language tags (e.g., `json`, `JSON`, `dart`), single-line
/// and multi-line fences, unclosed fences, and trims outer whitespace.
String stripMarkdownCodeFences(String text) {
  var cleaned = text.trim();
  if (cleaned.isEmpty) return '';

  // Single-line code fence: ```json {"key": "value"}``` or ```{"key": "value"}```
  if (!cleaned.contains('\n')) {
    // Check for both opening and closing fence on a single line
    final singleLineMatch = _singleLineFenceRegex.firstMatch(cleaned);
    if (singleLineMatch != null) {
      return singleLineMatch.group(1)!.trim();
    }
    // Single line with unclosed opening fence: ```json {"key": "value"}
    if (cleaned.startsWith('```')) {
      final unclosedMatch = _unclosedSingleLineFenceRegex.firstMatch(cleaned);
      if (unclosedMatch != null) {
        return unclosedMatch.group(1)!.trim();
      }
    }
    // Single line with trailing fence only: {"key": "value"}```
    if (cleaned.endsWith('```')) {
      final idx = cleaned.lastIndexOf('```');
      return cleaned.substring(0, idx).trim();
    }
    return cleaned;
  }

  // Multi-line code fence: scan and slice without full list materialization
  final firstNewline = cleaned.indexOf('\n');
  if (firstNewline != -1) {
    final firstLine = cleaned.substring(0, firstNewline).trim();
    if (firstLine.startsWith('```')) {
      cleaned = cleaned.substring(firstNewline + 1).trim();
    }
  }

  final lastNewline = cleaned.lastIndexOf('\n');
  if (lastNewline != -1) {
    final lastLine = cleaned.substring(lastNewline + 1).trim();
    if (lastLine.startsWith('```')) {
      cleaned = cleaned.substring(0, lastNewline).trim();
    }
  }

  // Strip any trailing fence on the last line if attached directly to content (e.g. `}``` `)
  if (cleaned.endsWith('```')) {
    final idx = cleaned.lastIndexOf('```');
    if (idx != -1) {
      cleaned = cleaned.substring(0, idx).trim();
    }
  }

  return cleaned;
}

/// Parses JSON from [text], first stripping any wrapping markdown code fences.
///
/// Returns the parsed dynamic value (e.g., [Map] or [List]), or `null` if JSON
/// decoding fails or [text] is empty.
dynamic parseJsonWithFenceFallback(String text) {
  final cleaned = stripMarkdownCodeFences(text);
  if (cleaned.isEmpty) return null;
  try {
    return jsonDecode(cleaned);
  } catch (_) {
    return null;
  }
}

/// Parses a JSON Map from [text], first stripping any wrapping markdown code fences.
///
/// Returns [Map<String, dynamic>] if successfully decoded, or `null` if JSON
/// decoding fails, [text] is empty, or the decoded JSON is not a Map.
Map<String, dynamic>? tryParseJsonMap(String text) {
  final result = parseJsonWithFenceFallback(text);
  if (result is Map<String, dynamic>) {
    return result;
  } else if (result is Map) {
    return result.cast<String, dynamic>();
  }
  return null;
}
