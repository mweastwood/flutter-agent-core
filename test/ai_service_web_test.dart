import 'dart:typed_data';

import 'package:flutter_agent_core/flutter_agent_core.dart';
import 'package:flutter_agent_core/src/ai_service_web.dart';
import 'package:flutter_test/flutter_test.dart';

class TestChromeAiClient implements ChromeAiClient {
  String? statusResult;
  Object? statusError;
  int checkStatusCallCount = 0;

  bool triggerDownloadCalled = false;
  Object? triggerDownloadError;
  int triggerDownloadCallCount = 0;

  String? nextStrokeResult;
  Object? nextStrokeError;
  String? capturedPrompt;
  String? capturedSystemInstruction;
  int nextStrokeCallCount = 0;

  @override
  Future<String?> checkStatus() async {
    checkStatusCallCount++;
    if (statusError != null) {
      throw statusError!;
    }
    return statusResult;
  }

  @override
  Future<void> triggerDownload() async {
    triggerDownloadCallCount++;
    triggerDownloadCalled = true;
    if (triggerDownloadError != null) {
      throw triggerDownloadError!;
    }
  }

  @override
  Future<String?> getNextStroke(String prompt, String systemInstruction) async {
    nextStrokeCallCount++;
    capturedPrompt = prompt;
    capturedSystemInstruction = systemInstruction;
    if (nextStrokeError != null) {
      throw nextStrokeError!;
    }
    return nextStrokeResult;
  }
}

void main() {
  group('WebAiService Tests', () {
    group('Status Mapping in checkStatus', () {
      test('maps "readily" to AiCoreStatus.available', () async {
        final client = TestChromeAiClient()..statusResult = 'readily';
        final service = WebAiService(client: client);

        final status = await service.checkStatus();
        expect(status, equals(AiCoreStatus.available));
        expect(client.checkStatusCallCount, equals(1));
      });

      test('maps "after-download" to AiCoreStatus.downloadable', () async {
        final client = TestChromeAiClient()..statusResult = 'after-download';
        final service = WebAiService(client: client);

        final status = await service.checkStatus();
        expect(status, equals(AiCoreStatus.downloadable));
        expect(client.checkStatusCallCount, equals(1));
      });

      test('maps unhandled status strings to AiCoreStatus.unavailable', () async {
        for (final unhandled in ['no', 'downloading', 'unknown', '']) {
          final client = TestChromeAiClient()..statusResult = unhandled;
          final service = WebAiService(client: client);

          final status = await service.checkStatus();
          expect(status, equals(AiCoreStatus.unavailable));
        }
      });

      test('maps null status to AiCoreStatus.unavailable', () async {
        final client = TestChromeAiClient()..statusResult = null;
        final service = WebAiService(client: client);

        final status = await service.checkStatus();
        expect(status, equals(AiCoreStatus.unavailable));
      });

      test('catches client exceptions and returns AiCoreStatus.unavailable gracefully', () async {
        final client = TestChromeAiClient()
          ..statusError = Exception('Browser JS error accessing window.chromeAi');
        final service = WebAiService(client: client);

        final status = await service.checkStatus();
        expect(status, equals(AiCoreStatus.unavailable));
      });

      test('returns AiCoreStatus.unavailable when client is null', () async {
        final service = WebAiService(client: null);

        final status = await service.checkStatus();
        expect(status, equals(AiCoreStatus.unavailable));
      });
    });

    group('Download Trigger Handling in triggerDownload', () {
      test('triggers download on client without delay', () async {
        final client = TestChromeAiClient();
        final service = WebAiService(client: client);

        await service.triggerDownload();
        expect(client.triggerDownloadCalled, isTrue);
        expect(client.triggerDownloadCallCount, equals(1));
      });

      test('respects optional delay parameter', () async {
        final client = TestChromeAiClient();
        final service = WebAiService(client: client);

        final stopwatch = Stopwatch()..start();
        await service.triggerDownload(delay: const Duration(milliseconds: 50));
        stopwatch.stop();

        expect(client.triggerDownloadCalled, isTrue);
        expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(40));
      });

      test('catches client exceptions during triggerDownload without propagating', () async {
        final client = TestChromeAiClient()
          ..triggerDownloadError = Exception('Download failed in browser');
        final service = WebAiService(client: client);

        await expectLater(service.triggerDownload(), completes);
        expect(client.triggerDownloadCalled, isTrue);
      });

      test('null client is a safe no-op with and without delay', () async {
        final service = WebAiService(client: null);

        await expectLater(service.triggerDownload(), completes);
        await expectLater(
          service.triggerDownload(delay: const Duration(milliseconds: 10)),
          completes,
        );
      });
    });

    group('Content Generation in generateContentRaw', () {
      test('returns AiResponse with isError: false and properly computed isTruncated', () async {
        final client = TestChromeAiClient()..nextStrokeResult = 'This is a complete response.';
        final service = WebAiService(client: client);

        final response = await service.generateContentRaw(prompt: 'Hello AI');
        expect(response, isNotNull);
        expect(response!.text, equals('This is a complete response.'));
        expect(response.isError, isFalse);
        expect(response.isTruncated, isFalse);
        expect(client.capturedPrompt, equals('Hello AI'));
        expect(client.capturedSystemInstruction, equals(''));
      });

      test('returns isTruncated: true for cut-off code block', () async {
        final client = TestChromeAiClient()
          ..nextStrokeResult = '```dart\nvoid main() {\n  print("incomplete code';
        final service = WebAiService(client: client);

        final response = await service.generateContentRaw(prompt: 'Write code');
        expect(response, isNotNull);
        expect(response!.isTruncated, isTrue);
        expect(response.isError, isFalse);
      });

      test('returns null when client returns null', () async {
        final client = TestChromeAiClient()..nextStrokeResult = null;
        final service = WebAiService(client: client);

        final response = await service.generateContentRaw(prompt: 'Hello');
        expect(response, isNull);
      });

      test('returns null when client is null', () async {
        final service = WebAiService(client: null);

        final response = await service.generateContentRaw(prompt: 'Hello');
        expect(response, isNull);
      });

      test('catches exception and returns AiResponse with isError: true and escaped JSON', () async {
        final client = TestChromeAiClient()
          ..nextStrokeError = Exception('Prompt failed: "rate-limited"');
        final service = WebAiService(client: client);

        final response = await service.generateContentRaw(prompt: 'Hello');
        expect(response, isNotNull);
        expect(response!.isError, isTrue);
        expect(response.isTruncated, isFalse);
        expect(
          response.text,
          equals('{"error": "Exception: Prompt failed: \\"rate-limited\\""}'),
        );
      });
    });

    group('Delegation in generateContent & Utilities', () {
      test('generateContent delegates to generateContentRaw and extracts text string', () async {
        final client = TestChromeAiClient()..nextStrokeResult = 'Extracted answer';
        final service = WebAiService(client: client);

        final text = await service.generateContent(prompt: 'What is 2+2?');
        expect(text, equals('Extracted answer'));
      });

      test('generateContent returns null when generateContentRaw returns null', () async {
        final client = TestChromeAiClient()..nextStrokeResult = null;
        final service = WebAiService(client: client);

        final text = await service.generateContent(prompt: 'What is 2+2?');
        expect(text, isNull);
      });

      test('setModelConfig completes safely as a no-op', () async {
        final service = WebAiService(client: TestChromeAiClient());

        await expectLater(
          service.setModelConfig(releaseStage: 'experimental', preference: 'speed'),
          completes,
        );
      });

      test('countTokens estimates token count based on prompt and imageBytes', () async {
        final service = WebAiService(client: TestChromeAiClient());

        final promptOnlyTokens = await service.countTokens(prompt: 'Hello world! 1234');
        expect(promptOnlyTokens, greaterThan(0));

        final withImageTokens = await service.countTokens(
          prompt: 'Hello world! 1234',
          imageBytes: Uint8List(100),
        );
        expect(withImageTokens, greaterThan(promptOnlyTokens));
      });

      test('getWebAiService factory returns WebAiService instance', () {
        final service = getWebAiService();
        expect(service, isA<WebAiService>());
      });
    });
  });
}
