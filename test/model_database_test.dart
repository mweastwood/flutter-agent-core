import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_core/flutter_agent_core.dart';

void main() {
  group('CloudModelDatabase Tests', () {
    test('CloudModelDatabase query APIs return expected models', () {
      final allModels = CloudModelDatabase.getAvailableModels();
      expect(allModels, isNotEmpty);
      expect(allModels.any((m) => m.modelName == 'gemini-3.5-flash'), isTrue);
      expect(allModels.any((m) => m.modelName == 'glm-4.7-flash'), isTrue);

      final geminiOnly = CloudModelDatabase.getAvailableModels(
        provider: CloudProvider.gemini,
      );
      expect(
        geminiOnly.every((m) => m.provider == CloudProvider.gemini),
        isTrue,
      );
      expect(geminiOnly.any((m) => m.modelName == 'gemini-3.5-flash'), isTrue);
      expect(geminiOnly.any((m) => m.modelName == 'glm-4.7-flash'), isFalse);

      final zhipuOnly = CloudModelDatabase.getAvailableModels(
        provider: CloudProvider.zhipu,
      );
      expect(zhipuOnly.every((m) => m.provider == CloudProvider.zhipu), isTrue);
      expect(zhipuOnly.any((m) => m.modelName == 'glm-4.7-flash'), isTrue);
      expect(zhipuOnly.any((m) => m.modelName == 'gemini-3.5-flash'), isFalse);
    });

    test('CloudModelDatabase getAvailableModelNames returns names', () {
      final allNames = CloudModelDatabase.getAvailableModelNames();
      expect(allNames, contains('gemini-3.5-flash'));
      expect(allNames, contains('glm-4.7-flash'));

      final geminiNames = CloudModelDatabase.getAvailableModelNames(
        provider: CloudProvider.gemini,
      );
      expect(geminiNames, contains('gemini-3.5-flash'));
      expect(geminiNames, isNot(contains('glm-4.7-flash')));
    });

    test('CloudModelDatabase getModelInfo retrieves details', () {
      final info36 = CloudModelDatabase.getModelInfo('gemini-3.6-flash');
      expect(info36, isNotNull);
      expect(info36!.provider, equals(CloudProvider.gemini));
      expect(info36.isVision, isTrue);
      expect(info36.limitRpm, equals(5));

      final info35Lite = CloudModelDatabase.getModelInfo(
        'gemini-3.5-flash-lite',
      );
      expect(info35Lite, isNotNull);
      expect(info35Lite!.limitRpm, equals(15));
      expect(info35Lite.limitRpd, equals(500));

      final flashLite = CloudModelDatabase.getModelInfo(
        'gemini-3.1-flash-lite',
      );
      expect(flashLite, isNotNull);
      expect(flashLite!.limitRpm, equals(15));
      expect(flashLite.limitRpd, equals(500));

      final gemma31b = CloudModelDatabase.getModelInfo('gemma-4-31b-it');
      expect(gemma31b, isNotNull);
      expect(gemma31b!.provider, equals(CloudProvider.gemini));
      expect(gemma31b.isVision, isTrue);
      expect(gemma31b.limitRpm, equals(15));
      expect(gemma31b.limitRpd, equals(1500));

      final nonExistent = CloudModelDatabase.getModelInfo('some-fake-model');
      expect(nonExistent, isNull);
    });

    test('CloudModelDatabase supports filtering by isVision', () {
      final visionModels = CloudModelDatabase.getAvailableModels(
        isVision: true,
      );
      expect(visionModels.every((m) => m.isVision), isTrue);
      expect(visionModels.any((m) => m.modelName == 'glm-4v-flash'), isTrue);
      expect(visionModels.any((m) => m.modelName == 'glm-4.7-flash'), isFalse);

      final zhipuVisionNames = CloudModelDatabase.getAvailableModelNames(
        provider: CloudProvider.zhipu,
        isVision: true,
      );
      expect(zhipuVisionNames, contains('glm-4v-flash'));
      expect(zhipuVisionNames, contains('glm-5v-turbo'));
      expect(zhipuVisionNames, isNot(contains('glm-4.7-flash')));
    });

    test(
      'CloudModelDatabase calculateEstimatedCost calculates USD costs correctly',
      () {
        // gemini-3.6-flash: $1.50 / 1M input, $7.50 / 1M output
        final costFlash = CloudModelDatabase.calculateEstimatedCost(
          'gemini-3.6-flash',
          inputTokens: 1000000,
          outputTokens: 1000000,
        );
        expect(costFlash, closeTo(9.00, 0.0001));

        // gemini-3.1-pro: $2.00 / 1M input, $12.00 / 1M output
        final costPro = CloudModelDatabase.calculateEstimatedCost(
          'gemini-3.1-pro',
          inputTokens: 2000000,
          outputTokens: 500000,
        );
        expect(costPro, closeTo(4.00 + 6.00, 0.0001));

        // Free tier gemma model: $0.0
        final costFree = CloudModelDatabase.calculateEstimatedCost(
          'gemma-4-31b-it',
          inputTokens: 500000,
          outputTokens: 100000,
        );
        expect(costFree, equals(0.0));

        // Unknown model returns 0.0
        final costUnknown = CloudModelDatabase.calculateEstimatedCost(
          'unknown-model',
          inputTokens: 1000,
          outputTokens: 1000,
        );
        expect(costUnknown, equals(0.0));
      },
    );
  });
}
