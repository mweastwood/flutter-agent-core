@TestOn('chrome')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_agent_core/src/chrome_ai_client.dart';
import 'package:flutter_agent_core/src/chrome_ai_client_web.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    globalContext.delete('chromeAi'.toJS);
  });

  group('WebChromeAiClient Tests', () {
    group('Client Instantiation & Factory', () {
      test(
        'WebChromeAiClient can be constructed and conforms to ChromeAiClient',
        () {
          const client = WebChromeAiClient();
          expect(client, isNotNull);
          expect(client, isA<ChromeAiClient>());
          expect(client, isA<WebChromeAiClient>());
        },
      );

      test(
          'createDefaultChromeAiClient returns a non-null WebChromeAiClient instance',
          () {
        final client = createDefaultChromeAiClient();
        expect(client, isNotNull);
        expect(client, isA<WebChromeAiClient>());
        expect(client, isA<ChromeAiClient>());
      });
    });

    group('Graceful Handling of Null window.chromeAi', () {
      test(
          'checkStatus returns null without throwing when window.chromeAi is null',
          () async {
        globalContext['chromeAi'] = null;
        const client = WebChromeAiClient();
        final status = await client.checkStatus();
        expect(status, isNull);
      });

      test(
          'checkStatus returns null without throwing when window.chromeAi is undefined',
          () async {
        globalContext.delete('chromeAi'.toJS);
        const client = WebChromeAiClient();
        final status = await client.checkStatus();
        expect(status, isNull);
      });

      test(
          'triggerDownload completes normally as a safe no-op when window.chromeAi is null',
          () async {
        globalContext['chromeAi'] = null;
        const client = WebChromeAiClient();
        await expectLater(client.triggerDownload(), completes);
      });

      test(
          'triggerDownload completes normally as a safe no-op when window.chromeAi is undefined',
          () async {
        globalContext.delete('chromeAi'.toJS);
        const client = WebChromeAiClient();
        await expectLater(client.triggerDownload(), completes);
      });

      test(
          'getNextStroke returns null without throwing when window.chromeAi is null',
          () async {
        globalContext['chromeAi'] = null;
        const client = WebChromeAiClient();
        final result = await client.getNextStroke(
          'prompt',
          'system instruction',
        );
        expect(result, isNull);
      });

      test(
          'getNextStroke returns null without throwing when window.chromeAi is undefined',
          () async {
        globalContext.delete('chromeAi'.toJS);
        const client = WebChromeAiClient();
        final result = await client.getNextStroke(
          'prompt',
          'system instruction',
        );
        expect(result, isNull);
      });
    });

    group('JS Interop Bridge Assertions (Mocked window.chromeAi)', () {
      test(
        'checkStatus returns "readily" when JS promise resolves with "readily"',
        () async {
          final mockAi = JSObject();
          mockAi['checkStatus'] = (() {
            return Future<JSString?>.value('readily'.toJS).toJS;
          }).toJS;
          globalContext['chromeAi'] = mockAi;

          const client = WebChromeAiClient();
          final status = await client.checkStatus();
          expect(status, equals('readily'));
        },
      );

      test(
          'checkStatus returns "after-download" when JS promise resolves with "after-download"',
          () async {
        final mockAi = JSObject();
        mockAi['checkStatus'] = (() {
          return Future<JSString?>.value('after-download'.toJS).toJS;
        }).toJS;
        globalContext['chromeAi'] = mockAi;

        const client = WebChromeAiClient();
        final status = await client.checkStatus();
        expect(status, equals('after-download'));
      });

      test(
        'checkStatus returns null cleanly when JS promise resolves to null',
        () async {
          final mockAi = JSObject();
          mockAi['checkStatus'] = (() {
            return Future<JSAny?>.value(null).toJS;
          }).toJS;
          globalContext['chromeAi'] = mockAi;

          const client = WebChromeAiClient();
          final status = await client.checkStatus();
          expect(status, isNull);
        },
      );

      test(
        'triggerDownload invokes mock triggerDownload and awaits completion',
        () async {
          var triggerDownloadCalled = false;
          final mockAi = JSObject();
          mockAi['triggerDownload'] = (() {
            triggerDownloadCalled = true;
            return Future<void>.value().toJS;
          }).toJS;
          globalContext['chromeAi'] = mockAi;

          const client = WebChromeAiClient();
          await expectLater(client.triggerDownload(), completes);
          expect(triggerDownloadCalled, isTrue);
        },
      );

      test(
          'getNextStroke forwards prompt and system instruction and returns resolved string',
          () async {
        String? capturedPrompt;
        String? capturedSystem;
        final mockAi = JSObject();
        mockAi['getNextStroke'] =
            ((JSString prompt, JSString systemInstruction) {
          capturedPrompt = prompt.toDart;
          capturedSystem = systemInstruction.toDart;
          return Future<JSString?>.value('generated response'.toJS).toJS;
        }).toJS;
        globalContext['chromeAi'] = mockAi;

        const client = WebChromeAiClient();
        final result = await client.getNextStroke(
          'draw a circle',
          'system prompt',
        );
        expect(result, equals('generated response'));
        expect(capturedPrompt, equals('draw a circle'));
        expect(capturedSystem, equals('system prompt'));
      });

      test(
        'getNextStroke returns null when JS promise resolves to null',
        () async {
          final mockAi = JSObject();
          mockAi['getNextStroke'] =
              ((JSString prompt, JSString systemInstruction) {
            return Future<JSAny?>.value(null).toJS;
          }).toJS;
          globalContext['chromeAi'] = mockAi;

          const client = WebChromeAiClient();
          final result = await client.getNextStroke(
            'draw a circle',
            'system prompt',
          );
          expect(result, isNull);
        },
      );
    });
  });
}
