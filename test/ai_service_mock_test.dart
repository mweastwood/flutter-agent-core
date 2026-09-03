import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_core/flutter_agent_core.dart';

void main() {
  group('MockAiService Tests', () {
    test(
      'triggerDownload transitions status to available immediately when delay is zero',
      () async {
        final service = MockAiService();
        service.setMockStatus(AiCoreStatus.downloadable);
        expect(await service.checkStatus(), equals(AiCoreStatus.downloadable));

        await service.triggerDownload();
        expect(await service.checkStatus(), equals(AiCoreStatus.available));
      },
    );

    test(
      'triggerDownload updates status to downloading then available with delay',
      () async {
        final service = MockAiService(
          downloadDelay: const Duration(milliseconds: 50),
        );
        service.setMockStatus(AiCoreStatus.downloadable);

        final downloadFuture = service.triggerDownload();
        expect(await service.checkStatus(), equals(AiCoreStatus.downloading));

        await downloadFuture;
        expect(await service.checkStatus(), equals(AiCoreStatus.available));
      },
    );

    test('triggerDownload allows overriding delay parameter', () async {
      final service = MockAiService(downloadDelay: const Duration(seconds: 10));
      service.setMockStatus(AiCoreStatus.downloadable);

      final downloadFuture = service.triggerDownload(
        delay: const Duration(milliseconds: 50),
      );
      expect(await service.checkStatus(), equals(AiCoreStatus.downloading));

      await downloadFuture;
      expect(await service.checkStatus(), equals(AiCoreStatus.available));
    });

    test(
      'triggerDownload allows overriding non-zero downloadDelay with Duration.zero',
      () async {
        final service = MockAiService(
          downloadDelay: const Duration(seconds: 10),
        );
        service.setMockStatus(AiCoreStatus.downloadable);

        await service.triggerDownload(delay: Duration.zero);
        expect(await service.checkStatus(), equals(AiCoreStatus.available));
      },
    );

    test(
      'concurrent triggerDownload calls share and await active download Future',
      () async {
        final service = MockAiService(
          downloadDelay: const Duration(milliseconds: 50),
        );
        service.setMockStatus(AiCoreStatus.downloadable);

        final downloadFuture1 = service.triggerDownload();
        expect(await service.checkStatus(), equals(AiCoreStatus.downloading));

        final downloadFuture2 = service.triggerDownload();
        expect(await service.checkStatus(), equals(AiCoreStatus.downloading));

        await Future.wait([downloadFuture1, downloadFuture2]);
        expect(await service.checkStatus(), equals(AiCoreStatus.available));
      },
    );

    test('triggerDownload works via polymorphic AiService reference', () async {
      final AiService service = MockAiService(
        downloadDelay: const Duration(milliseconds: 50),
      );
      (service as MockAiService).setMockStatus(AiCoreStatus.downloadable);

      final downloadFuture = service.triggerDownload();
      await downloadFuture;
      expect(await service.checkStatus(), equals(AiCoreStatus.available));
    });

    test(
      'triggerDownload can be re-triggered after zero-delay download completes',
      () async {
        final service = MockAiService(downloadDelay: Duration.zero);
        service.setMockStatus(AiCoreStatus.downloadable);

        await service.triggerDownload();
        expect(await service.checkStatus(), equals(AiCoreStatus.available));

        service.setMockStatus(AiCoreStatus.downloadable);
        expect(await service.checkStatus(), equals(AiCoreStatus.downloadable));

        await service.triggerDownload();
        expect(await service.checkStatus(), equals(AiCoreStatus.available));
      },
    );

    test('MockAiService downloadDelay is mutable', () {
      final service = MockAiService(downloadDelay: Duration.zero);
      expect(service.downloadDelay, equals(Duration.zero));
      service.downloadDelay = const Duration(seconds: 5);
      expect(service.downloadDelay, equals(const Duration(seconds: 5)));
    });

    test(
      'triggerDownload does nothing if status is not downloadable',
      () async {
        final service = MockAiService();
        expect(await service.checkStatus(), equals(AiCoreStatus.available));

        await service.triggerDownload();
        expect(await service.checkStatus(), equals(AiCoreStatus.available));
      },
    );

    group('generateContentRaw', () {
      test(
        'simulates initial truncated response when prompt contains simulate_truncation without partial marker',
        () async {
          final service = MockAiService();
          final response = await service.generateContentRaw(
            prompt: 'Please simulate_truncation in this test',
          );

          expect(response, isNotNull);
          expect(response!.text, equals('Response is partial and'));
          expect(response.isTruncated, isTrue);
          expect(response.isError, isFalse);
        },
      );

      test(
        'simulates completed continuation response when prompt contains simulate_truncation and partial marker',
        () async {
          final service = MockAiService();
          final response = await service.generateContentRaw(
            prompt:
                'simulate_truncation [Assistant (Partial Response)]: Response is partial and',
          );

          expect(response, isNotNull);
          expect(response!.text, equals(' finished successfully.'));
          expect(response.isTruncated, isFalse);
          expect(response.isError, isFalse);
        },
      );

      test('returns mock palette color JSON when temperature <= 0.5', () async {
        final service = MockAiService();

        final responseAtThreshold = await service.generateContentRaw(
          prompt: 'generate a color palette',
          temperature: 0.5,
        );
        expect(responseAtThreshold, isNotNull);
        expect(responseAtThreshold!.text, equals('["#000000", "#ffffff"]'));
        expect(responseAtThreshold.isTruncated, isFalse);

        final responseBelowThreshold = await service.generateContentRaw(
          prompt: 'generate a color palette',
          temperature: 0.1,
        );
        expect(responseBelowThreshold, isNotNull);
        expect(responseBelowThreshold!.text, equals('["#000000", "#ffffff"]'));
        expect(responseBelowThreshold.isTruncated, isFalse);
      });

      test(
        'returns default ReAct tool finish JSON when temperature > 0.5 and truncation is not requested',
        () async {
          final service = MockAiService();

          final response = await service.generateContentRaw(
            prompt: 'Explain what you can do',
            temperature: 1.0,
            imageBytes: Uint8List.fromList([1, 2, 3]),
            maxOutputTokens: 100,
          );

          expect(response, isNotNull);
          expect(response!.isTruncated, isFalse);
          expect(
            response.text,
            equals(
              '{\n'
              '  "understanding": "Mock generic reasoning.",\n'
              '  "tool": "finish",\n'
              '  "params": []\n'
              '}',
            ),
          );
        },
      );
    });

    group('generateContent', () {
      test(
        'forwards parameters to generateContentRaw and returns extracted text',
        () async {
          final service = MockAiService();

          final defaultText = await service.generateContent(
            prompt: 'Tell me a story',
          );
          expect(
            defaultText,
            equals(
              '{\n'
              '  "understanding": "Mock generic reasoning.",\n'
              '  "tool": "finish",\n'
              '  "params": []\n'
              '}',
            ),
          );

          final paletteText = await service.generateContent(
            prompt: 'Theme colors',
            temperature: 0.3,
          );
          expect(paletteText, equals('["#000000", "#ffffff"]'));

          final truncatedText = await service.generateContent(
            prompt: 'simulate_truncation test',
          );
          expect(truncatedText, equals('Response is partial and'));
        },
      );
    });

    group('countTokens', () {
      test(
        'estimates text tokens as (prompt.length / 4).round() when imageBytes is null or empty',
        () async {
          final service = MockAiService();

          expect(await service.countTokens(prompt: ''), equals(0));
          expect(await service.countTokens(prompt: '1234'), equals(1));
          expect(await service.countTokens(prompt: '12345'), equals(1));
          expect(await service.countTokens(prompt: '123456'), equals(2));
          expect(await service.countTokens(prompt: '12345678'), equals(2));

          expect(
            await service.countTokens(
              prompt: '12345678',
              imageBytes: Uint8List(0),
            ),
            equals(2),
          );
        },
      );

      test(
        'adds 256 tokens when imageBytes is not null and not empty',
        () async {
          final service = MockAiService();
          final image = Uint8List.fromList([0, 1, 2, 3, 4]);

          expect(
            await service.countTokens(prompt: '12345678', imageBytes: image),
            equals(2 + 256),
          );
          expect(
            await service.countTokens(prompt: '', imageBytes: image),
            equals(0 + 256),
          );
        },
      );
    });

    group('setModelConfig', () {
      test('executes stub successfully without error', () async {
        final service = MockAiService();
        await expectLater(
          service.setModelConfig(
            releaseStage: 'production',
            preference: 'fast',
          ),
          completes,
        );
      });
    });

    group('dispose', () {
      test('executes safely without errors', () {
        final service = MockAiService();
        expect(() => service.dispose(), returnsNormally);
      });

      test('executes safely via polymorphic AiService reference', () {
        final AiService service = MockAiService();
        expect(() => service.dispose(), returnsNormally);
      });
    });
  });
}
