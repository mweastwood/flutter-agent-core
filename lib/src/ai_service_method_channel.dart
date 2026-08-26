import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ai_service.dart';

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
  Future<void> triggerDownload({Duration? delay}) async {
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
            isError: true,
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
      return AiResponse(text: text, isTruncated: isTruncated, isError: false);
    } catch (e, stack) {
      debugPrint('Error generating content via MethodChannel: $e');
      debugPrint(stack.toString());
      return AiResponse(
        text: '{"error": "${e.toString().replaceAll('"', '\\"')}"}',
        isTruncated: false,
        isError: true,
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
