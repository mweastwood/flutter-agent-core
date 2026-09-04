import 'package:flutter/foundation.dart';

import 'ai_service.dart';
import 'chrome_ai_client.dart';

export 'chrome_ai_client.dart';

AiService getWebAiService() {
  return WebAiService();
}

class WebAiService extends AiService {
  final ChromeAiClient? _client;

  WebAiService({ChromeAiClient? client})
    : _client = client ?? defaultChromeAiClient;

  @override
  Future<AiCoreStatus> checkStatus() async {
    try {
      final client = _client;
      if (client == null) {
        debugPrint(
          'Web AI checkStatus: window.chromeAi is null (check if script in index.html ran successfully)',
        );
        return AiCoreStatus.unavailable;
      }

      final status = await client.checkStatus();
      switch (status) {
        case 'readily':
          return AiCoreStatus.available;
        case 'after-download':
          return AiCoreStatus.downloadable;
        default:
          return AiCoreStatus.unavailable;
      }
    } catch (e) {
      debugPrint('Error checking Web AI status: $e');
      return AiCoreStatus.unavailable;
    }
  }

  @override
  Future<void> triggerDownload({Duration? delay}) async {
    try {
      if (delay != null) {
        await Future.delayed(delay);
      }
      final client = _client;
      if (client == null) return;

      await client.triggerDownload();
    } catch (e) {
      debugPrint('Error triggering download: $e');
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
    try {
      final client = _client;
      if (client == null) return null;

      final response = await client.getNextStroke(prompt, '');
      if (response == null) return null;

      return AiResponse(
        text: response,
        isTruncated: isTruncatedHeuristic(response, false),
        isError: false,
      );
    } catch (e) {
      debugPrint('Error generating content from Web AI: $e');
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
  }) async => AiService.estimateTokenCount(prompt, imageBytes: imageBytes);
}
