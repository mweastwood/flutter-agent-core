import 'chrome_ai_client_stub.dart'
    if (dart.library.js_interop) 'chrome_ai_client_web.dart'
    if (dart.library.html) 'chrome_ai_client_web.dart';

abstract class ChromeAiClient {
  Future<String?> checkStatus();
  Future<void> triggerDownload();
  Future<String?> getNextStroke(String prompt, String systemInstruction);
}

ChromeAiClient? get defaultChromeAiClient => createDefaultChromeAiClient();
