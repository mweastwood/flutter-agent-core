import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai_service_stub.dart' if (dart.library.html) 'ai_service_web.dart';

enum AiCoreStatus { unavailable, downloadable, downloading, available }

class AiResponse {
  final String text;
  final bool isTruncated;
  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
  final double? estimatedCostUsd;

  AiResponse({
    required this.text,
    this.isTruncated = false,
    this.inputTokens,
    this.outputTokens,
    int? totalTokens,
    this.estimatedCostUsd,
  }) : totalTokens =
           totalTokens ??
           (inputTokens != null && outputTokens != null
               ? inputTokens + outputTokens
               : null);
}

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

  // Strip starting code fences
  if (cleaned.trimLeft().startsWith('```')) {
    final lines = cleaned.split('\n');
    if (lines.isNotEmpty && lines.first.trim().startsWith('```')) {
      lines.removeAt(0);
    }
    cleaned = lines.join('\n');
  }

  // Strip ending code fences
  if (cleaned.trimRight().endsWith('```')) {
    final idx = cleaned.lastIndexOf('```');
    if (idx != -1) {
      cleaned = cleaned.substring(0, idx);
    }
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
  for (var offset = 0; offset < 50; offset++) {
    if (text.length <= offset) break;
    final subText = offset == 0
        ? text
        : text.substring(0, text.length - offset);

    var maxOverlap = subText.length < nextText.length
        ? subText.length
        : nextText.length;
    if (maxOverlap > 500) {
      maxOverlap = 500;
    }
    for (var i = maxOverlap; i >= 3; i--) {
      final suffix = subText.substring(subText.length - i);
      final prefix = nextText.substring(0, i);
      if (suffix == prefix) {
        return subText + nextText.substring(i);
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

abstract class AiService {
  Future<AiCoreStatus> checkStatus();
  Future<void> triggerDownload();
  Future<void> setModelConfig({
    required String releaseStage,
    required String preference,
  });
  Future<String?> generateContent({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int? maxOutputTokens,
  });

  Future<int> countTokens({required String prompt, Uint8List? imageBytes});

  Future<AiResponse?> generateContentRaw({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int? maxOutputTokens,
  }) async {
    final text = await generateContent(
      prompt: prompt,
      imageBytes: imageBytes,
      temperature: temperature,
      maxOutputTokens: maxOutputTokens,
    );
    if (text == null) return null;
    return AiResponse(text: text, isTruncated: false);
  }
}

class MethodChannelAiService extends AiService {
  static const _channel = MethodChannel('com.mweastwood.local_agent');

  @override
  Future<AiCoreStatus> checkStatus() async {
    try {
      final String? result = await _channel.invokeMethod<String>('checkStatus');
      switch (result) {
        case 'available':
          return AiCoreStatus.available;
        case 'downloading':
          return AiCoreStatus.downloading;
        case 'downloadable':
          return AiCoreStatus.downloadable;
        default:
          return AiCoreStatus.unavailable;
      }
    } catch (e, stack) {
      debugPrint('Error invoking checkStatus via MethodChannel: $e');
      debugPrint(stack.toString());
      return AiCoreStatus.unavailable;
    }
  }

  @override
  Future<void> triggerDownload() async {
    try {
      await _channel.invokeMethod<void>('triggerDownload');
    } catch (e, stack) {
      debugPrint('Error invoking triggerDownload via MethodChannel: $e');
      debugPrint(stack.toString());
    }
  }

  @override
  Future<void> setModelConfig({
    required String releaseStage,
    required String preference,
  }) async {
    try {
      await _channel.invokeMethod<void>('setModelConfig', {
        'releaseStage': releaseStage,
        'preference': preference,
      });
    } catch (e, stack) {
      debugPrint('Error invoking setModelConfig via MethodChannel: $e');
      debugPrint(stack.toString());
    }
  }

  @override
  Future<AiResponse?> generateContentRaw({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int? maxOutputTokens,
  }) async {
    try {
      dynamic result;
      dynamic lastError;
      StackTrace? lastStackTrace;
      final List<String> attemptErrors = [];

      for (int attempt = 1; attempt <= 4; attempt++) {
        try {
          result = await _channel.invokeMethod<dynamic>('generateContent', {
            'prompt': prompt,
            'image': imageBytes,
            'temperature': temperature,
            'maxOutputTokens': maxOutputTokens,
          });
          break; // Success! Exit the retry loop.
        } catch (e, stack) {
          lastError = e;
          lastStackTrace = stack;
          attemptErrors.add('Attempt $attempt: $e');
          debugPrint(
            'Error generating content (attempt $attempt/4) via MethodChannel (generateContent): $e',
          );
          if (attempt < 4) {
            final backoffMs = attempt * 500; // 500ms, 1000ms, 1500ms
            await Future.delayed(Duration(milliseconds: backoffMs));
          }
        }
      }

      if (result == null) {
        if (lastError != null) {
          debugPrint(lastStackTrace.toString());
          return AiResponse(
            text: '{"error": "${lastError.toString().replaceAll('"', '\\"')}"}',
            isTruncated: false,
          );
        }
        return null;
      }

      String? text;
      bool isTruncated = false;
      if (result is Map) {
        text = result['text'] as String?;
        isTruncated = result['isTruncated'] as bool? ?? false;
      } else if (result is String) {
        text = result;
      }

      if (text == null) return null;
      return AiResponse(text: text, isTruncated: isTruncated);
    } catch (e, stack) {
      debugPrint('Error generating content via MethodChannel: $e');
      debugPrint(stack.toString());
      return AiResponse(
        text: '{"error": "${e.toString().replaceAll('"', '\\"')}"}',
        isTruncated: false,
      );
    }
  }

  @override
  Future<String?> generateContent({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int? maxOutputTokens,
  }) async {
    final res = await generateContentRaw(
      prompt: prompt,
      imageBytes: imageBytes,
      temperature: temperature,
      maxOutputTokens: maxOutputTokens,
    );
    return res?.text;
  }

  @override
  Future<int> countTokens({
    required String prompt,
    Uint8List? imageBytes,
  }) async {
    try {
      final int? result = await _channel.invokeMethod<int>('countTokens', {
        'prompt': prompt,
        'image': imageBytes,
      });
      return result ?? 0;
    } catch (e, stack) {
      debugPrint('Error invoking countTokens via MethodChannel: $e');
      debugPrint(stack.toString());
      return 0;
    }
  }
}

class MockAiService extends AiService {
  AiCoreStatus _status = AiCoreStatus.available;

  @override
  Future<AiCoreStatus> checkStatus() async {
    return _status;
  }

  void setMockStatus(AiCoreStatus status) {
    _status = status;
  }

  @override
  Future<void> triggerDownload() async {
    if (_status == AiCoreStatus.downloadable) {
      _status = AiCoreStatus.downloading;
      Future.delayed(const Duration(seconds: 2), () {
        _status = AiCoreStatus.available;
      });
    }
  }

  @override
  Future<void> setModelConfig({
    required String releaseStage,
    required String preference,
  }) async {}

  @override
  Future<AiResponse?> generateContentRaw({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int? maxOutputTokens,
  }) async {
    await Future.delayed(const Duration(milliseconds: 100));

    if (prompt.contains('simulate_truncation')) {
      if (prompt.contains('[Assistant (Partial Response)]:')) {
        return AiResponse(text: ' finished successfully.', isTruncated: false);
      }
      return AiResponse(text: 'Response is partial and', isTruncated: true);
    }

    if (temperature <= 0.5) {
      return AiResponse(text: '["#000000", "#ffffff"]', isTruncated: false);
    }

    return AiResponse(
      text:
          '{\n'
          '  "understanding": "Mock generic reasoning.",\n'
          '  "tool": "finish",\n'
          '  "params": []\n'
          '}',
      isTruncated: false,
    );
  }

  @override
  Future<String?> generateContent({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int? maxOutputTokens,
  }) async {
    final res = await generateContentRaw(
      prompt: prompt,
      imageBytes: imageBytes,
      temperature: temperature,
      maxOutputTokens: maxOutputTokens,
    );
    return res?.text;
  }

  @override
  Future<int> countTokens({
    required String prompt,
    Uint8List? imageBytes,
  }) async {
    int count = (prompt.length / 4).round();
    if (imageBytes != null && imageBytes.isNotEmpty) {
      count += 256;
    }
    return count;
  }
}

AiService getAiService() {
  if (kIsWeb) {
    return getWebAiService();
  } else if (defaultTargetPlatform == TargetPlatform.android) {
    return MethodChannelAiService();
  }
  return MockAiService();
}

final aiServiceProvider = Provider<AiService>((ref) => getAiService());

extension AiServiceContinuationExtension on AiService {
  Future<String?> generateContentWithContinuation({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int? maxOutputTokens,
    int autoContinueLimit = 0,
  }) async {
    if (autoContinueLimit <= 0) {
      final res = await generateContentRaw(
        prompt: prompt,
        imageBytes: imageBytes,
        temperature: temperature,
        maxOutputTokens: maxOutputTokens,
      );
      return res?.text;
    }

    return runWithAutoContinuation(
      initialPrompt: prompt,
      autoContinueLimit: autoContinueLimit,
      runCompletion: (currentPrompt) => generateContentRaw(
        prompt: currentPrompt,
        imageBytes: imageBytes,
        temperature: temperature,
        maxOutputTokens: maxOutputTokens,
      ),
    );
  }
}

extension AiServiceJsonExtension on AiService {
  /// Queries the model for a single-turn completion, strips markdown fence blocks,
  /// and parses the response into a JSON Map or List.
  Future<dynamic> generateJson({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int autoContinueLimit = 0,
  }) async {
    final raw = await generateContentWithContinuation(
      prompt: prompt,
      imageBytes: imageBytes,
      temperature: temperature,
      autoContinueLimit: autoContinueLimit,
    );
    if (raw == null) return null;

    var cleaned = raw.trim();
    if (cleaned.startsWith('```')) {
      final lines = cleaned.split('\n');
      if (lines.first.startsWith('```')) lines.removeAt(0);
      if (lines.isNotEmpty && lines.last.startsWith('```')) lines.removeLast();
      cleaned = lines.join('\n').trim();
    }
    try {
      return jsonDecode(cleaned);
    } catch (_) {
      return null;
    }
  }
}
