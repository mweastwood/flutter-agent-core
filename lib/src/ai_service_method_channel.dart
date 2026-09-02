import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ai_service.dart';

class MethodChannelAiService extends AiService {
  static const _defaultChannel = MethodChannel('com.mweastwood.local_agent');

  final MethodChannel _channel;
  final int maxRetries;
  final Duration initialRetryDelay;
  final Duration maxRetryDelay;
  final bool enableJitter;
  final Random? _random;

  MethodChannelAiService({
    MethodChannel channel = _defaultChannel,
    this.maxRetries = 3,
    this.initialRetryDelay = const Duration(milliseconds: 500),
    this.maxRetryDelay = const Duration(seconds: 15),
    this.enableJitter = true,
    Random? random,
  }) : _channel = channel,
       _random = random;

  @visibleForTesting
  Duration calculateBackoff(int attempt) {
    final expFactor = 1 << (attempt - 1).clamp(0, 30);
    final calculatedMs = initialRetryDelay.inMilliseconds * expFactor;
    final boundedMs = calculatedMs.clamp(0, maxRetryDelay.inMilliseconds);

    if (boundedMs == 0) {
      return Duration.zero;
    }

    if (!enableJitter) {
      return Duration(milliseconds: boundedMs);
    }

    final random = _random ?? Random();
    final jitterRange = min(1000, (boundedMs * 0.25).round());
    final jitter = jitterRange > 0
        ? (random.nextInt(jitterRange * 2) - jitterRange)
        : 0;
    final finalMs = max(1, boundedMs + jitter);
    return Duration(milliseconds: finalMs);
  }

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
      await _channel.invokeMethod<void>(
        'triggerDownload',
        delay != null ? {'delayMs': delay.inMilliseconds} : null,
      );
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
      final totalAttempts = maxRetries > 0 ? maxRetries + 1 : 1;

      for (int attempt = 1; attempt <= totalAttempts; attempt++) {
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
            'Error generating content (attempt $attempt/$totalAttempts) via MethodChannel (generateContent): $e',
          );
          if (attempt < totalAttempts) {
            final backoff = calculateBackoff(attempt);
            await Future.delayed(backoff);
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
