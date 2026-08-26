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
  Future<void> triggerDownload() async {
    try {
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
  Future<String?> generateContent({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int? maxOutputTokens,
  }) async {
    try {
      final ai = chromeAi;
      if (ai == null) return null;

      if (temperature <= 0.5) {
        // Fallback for suggesting exactly 16 hex color strings on web
        await Future.delayed(const Duration(milliseconds: 500));
        final List<String> mockPalette = List.generate(16, (i) {
          final val = (i * 0x11).toRadixString(16).padLeft(2, '0');
          return '#$val$val$val';
        });
        return '["${mockPalette.join('", "')}"]';
      }

      final jsResponse = await ai.getNextStroke(prompt.toJS, ''.toJS).toDart;
      final String? response = (jsResponse as JSString?)?.toDart;
      return response;
    } catch (e) {
      debugPrint('Error generating content from Web AI: $e');
    }
    return null;
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
