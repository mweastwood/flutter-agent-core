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

    test('triggerDownload allows overriding delay parameter with Duration.zero', () async {
      final service = MockAiService(downloadDelay: const Duration(seconds: 10));
      service.setMockStatus(AiCoreStatus.downloadable);

      await service.triggerDownload(delay: Duration.zero);
      expect(await service.checkStatus(), equals(AiCoreStatus.available));
    });

    test('triggerDownload works via polymorphic AiService reference with optional delay', () async {
      final AiService service = MockAiService(downloadDelay: const Duration(milliseconds: 50));
      (service as MockAiService).setMockStatus(AiCoreStatus.downloadable);

      final downloadFuture = service.triggerDownload(delay: Duration.zero);
      await downloadFuture;
      expect(await service.checkStatus(), equals(AiCoreStatus.available));
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
  });
}
