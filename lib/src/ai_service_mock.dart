import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ai_service.dart';

class MockAiService extends AiService {
  AiCoreStatus _status = AiCoreStatus.available;
  Future<void>? _activeDownloadFuture;

  /// Default delay for simulated download operations in [triggerDownload].
  ///
  /// Defaults to [Duration.zero] if not specified.
  Duration downloadDelay;

  MockAiService({this.downloadDelay = Duration.zero});

  @override
  Future<AiCoreStatus> checkStatus() async {
    return _status;
  }

  void setMockStatus(AiCoreStatus status) {
    _status = status;
  }

  /// Triggers a simulated download operation when [_status] is [AiCoreStatus.downloadable].
  ///
  /// The optional [delay] parameter overrides [downloadDelay] when starting a new download operation.
  /// If omitted or `null`, [downloadDelay] (which defaults to [Duration.zero]) is used.
  /// If [_status] is already [AiCoreStatus.downloading] or a download is active, this method returns
  /// the active download [Future] so concurrent callers can await completion of the ongoing download;
  /// note that any [delay] parameter provided in concurrent calls while a download is active is ignored.
  /// If [_status] is not downloadable, this method returns immediately.
  @override
  Future<void> triggerDownload({Duration? delay}) {
    if (_activeDownloadFuture != null) {
      return _activeDownloadFuture!;
    }
    if (_status == AiCoreStatus.downloadable) {
      _status = AiCoreStatus.downloading;
      final effectiveDelay = delay ?? downloadDelay;
      final future = _runDownload(effectiveDelay);
      _activeDownloadFuture = future;
      future.whenComplete(() {
        _activeDownloadFuture = null;
      });
      return future;
    }
    return Future.value();
  }

  Future<void> _runDownload(Duration delay) async {
    if (delay > Duration.zero) {
      await Future.delayed(delay);
    }
    _status = AiCoreStatus.available;
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
  }) async =>
      AiService.estimateTokenCount(prompt, imageBytes: imageBytes);
}
