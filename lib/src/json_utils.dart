import 'dart:convert';

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
    final singleLineMatch = RegExp(
      r'^```[a-zA-Z0-9_-]*\s*([\s\S]*?)\s*```$',
    ).firstMatch(cleaned);
    if (singleLineMatch != null) {
      return singleLineMatch.group(1)!.trim();
    }
    // Single line with unclosed opening fence: ```json {"key": "value"}
    if (cleaned.startsWith('```')) {
      final unclosedMatch = RegExp(
        r'^```[a-zA-Z0-9_-]*\s*(.*)$',
      ).firstMatch(cleaned);
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

  // Multi-line code fence
  final lines = cleaned.split('\n');

  // Strip opening fence line if present
  if (lines.isNotEmpty && lines.first.trim().startsWith('```')) {
    lines.removeAt(0);
  }

  // Strip closing fence line if present
  if (lines.isNotEmpty && lines.last.trim().startsWith('```')) {
    lines.removeLast();
  }

  cleaned = lines.join('\n').trim();

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
