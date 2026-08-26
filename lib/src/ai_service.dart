import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai_service_method_channel.dart';
import 'ai_service_mock.dart';
import 'ai_service_stub.dart' if (dart.library.html) 'ai_service_web.dart';
import 'continuation_helper.dart';
import 'json_utils.dart';

export 'ai_service_method_channel.dart';
export 'ai_service_mock.dart';
export 'continuation_helper.dart';

enum AiCoreStatus { unavailable, downloadable, downloading, available }

class AiResponse {
  final String text;
  final bool isTruncated;
  final bool isError;
  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
  final double? estimatedCostUsd;

  AiResponse({
    required this.text,
    this.isTruncated = false,
    this.isError = false,
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

abstract class AiService {
  Future<AiCoreStatus> checkStatus();
  /// Triggers a simulated or platform model download operation.
  ///
  /// Accepts an optional [delay] parameter to override default download delay
  /// in mock or stub implementations.
  Future<void> triggerDownload({Duration? delay});
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

    return parseJsonWithFenceFallback(raw);
  }
}
