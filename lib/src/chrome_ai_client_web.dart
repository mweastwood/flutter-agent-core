import 'dart:js_interop';

import 'package:flutter/foundation.dart';

import 'chrome_ai_client.dart';

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

class WebChromeAiClient implements ChromeAiClient {
  const WebChromeAiClient();

  @override
  Future<String?> checkStatus() async {
    final ai = chromeAi;
    if (ai == null) {
      debugPrint(
        'Web AI checkStatus: window.chromeAi is null (check if script in index.html ran successfully)',
      );
      return null;
    }

    final jsStatus = await ai.checkStatus().toDart;
    return (jsStatus as JSString).toDart;
  }

  @override
  Future<void> triggerDownload() async {
    final ai = chromeAi;
    if (ai == null) return;

    await ai.triggerDownload().toDart;
  }

  @override
  Future<String?> getNextStroke(String prompt, String systemInstruction) async {
    final ai = chromeAi;
    if (ai == null) return null;

    final jsResponse =
        await ai.getNextStroke(prompt.toJS, systemInstruction.toJS).toDart;
    return (jsResponse as JSString?)?.toDart;
  }
}

ChromeAiClient? createDefaultChromeAiClient() => const WebChromeAiClient();
