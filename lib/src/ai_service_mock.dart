import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ai_service.dart';

class MockAiService extends AiService {
  AiCoreStatus _status = AiCoreStatus.available;

  /// Duration to simulate model downloading delay in MockAiService.
  Duration downloadDelay = const Duration(seconds: 2);

  @override
  Future<AiCoreStatus> checkStatus() async {
    return _status;
  }

  void setMockStatus(AiCoreStatus status) {
    _status = status;
  }

  @override
  Future<void> triggerDownload({Duration? delay}) async {
    if (_status == AiCoreStatus.downloadable) {
      _status = AiCoreStatus.downloading;
      final effectiveDelay = delay ?? downloadDelay;
      Future.delayed(effectiveDelay, () {
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
