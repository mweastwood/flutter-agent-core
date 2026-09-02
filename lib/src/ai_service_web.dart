import 'dart:js_interop';

import 'package:flutter/foundation.dart';

import 'ai_service.dart';

AiService getWebAiService() {
  return WebAiService();
}

@JS('chromeAi')
external ChromeAi? get chromeAi;

@JS()
@staticInterop
class ChromeAi {}

extension ChromeAiExtension on ChromeAi {
  external JSPromise checkStatus();
  external JSPromise triggerDownload();
  external JSPromise getNextStroke(JSString prompt, JSString systemInstruction);
}

class WebAiService extends AiService {
  @override
  Future<AiCoreStatus> checkStatus() async {
    try {
      final ai = chromeAi;
      if (ai == null) {
        debugPrint(
          'Web AI checkStatus: window.chromeAi is null (check if script in index.html ran successfully)',
        );
        return AiCoreStatus.unavailable;
      }

      final jsStatus = await ai.checkStatus().toDart;
      final String result = (jsStatus as JSString).toDart;

      switch (result) {
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
      final ai = chromeAi;
      if (ai == null) return;

      await ai.triggerDownload().toDart;
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
      final ai = chromeAi;
      if (ai == null) return null;

      final jsResponse = await ai.getNextStroke(prompt.toJS, ''.toJS).toDart;
      final String? response = (jsResponse as JSString?)?.toDart;
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
  }) async {
    int count = (prompt.length / 4).round();
    if (imageBytes != null && imageBytes.isNotEmpty) {
      count += 256;
    }
    return count;
  }
}
