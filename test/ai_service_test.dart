import 'package:flutter/foundation.dart';
import 'package:flutter_agent_core/flutter_agent_core.dart';
import 'package:flutter_agent_core/src/ai_service_stub.dart'
    if (dart.library.html) 'package:flutter_agent_core/src/ai_service_web.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class TestFakeAiService extends AiService {
  String? mockContent;
  String? capturedPrompt;
  Uint8List? capturedImageBytes;
  double? capturedTemperature;
  int? capturedMaxOutputTokens;
  int generateContentCallCount = 0;

  @override
  Future<AiCoreStatus> checkStatus() async => AiCoreStatus.available;

  @override
  Future<void> triggerDownload() async {}

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
    generateContentCallCount++;
    capturedPrompt = prompt;
    capturedImageBytes = imageBytes;
    capturedTemperature = temperature;
    capturedMaxOutputTokens = maxOutputTokens;
    return mockContent;
  }

  @override
  Future<int> countTokens({
    required String prompt,
    Uint8List? imageBytes,
  }) async => 10;
}

class TestContinuationAiService extends AiService {
  final List<AiResponse?> rawResponses;
  int callIndex = 0;
  final List<String> capturedPrompts = [];
  Uint8List? capturedImageBytes;
  double? capturedTemperature;
  int? capturedMaxOutputTokens;

  TestContinuationAiService(this.rawResponses);

  @override
  Future<AiCoreStatus> checkStatus() async => AiCoreStatus.available;

  @override
  Future<void> triggerDownload() async {}

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
  }) async => null;

  @override
  Future<AiResponse?> generateContentRaw({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int? maxOutputTokens,
  }) async {
    capturedPrompts.add(prompt);
    capturedImageBytes = imageBytes;
    capturedTemperature = temperature;
    capturedMaxOutputTokens = maxOutputTokens;
    if (callIndex < rawResponses.length) {
      return rawResponses[callIndex++];
    }
    return null;
  }

  @override
  Future<int> countTokens({
    required String prompt,
    Uint8List? imageBytes,
  }) async => 10;
}

void main() {
  group('AiResponse Tests', () {
    test('verifies constructor default property values', () {
      final response = AiResponse(text: 'hello');
      expect(response.isTruncated, isFalse);
      expect(response.isError, isFalse);
      expect(response.estimatedCostUsd, isNull);
    });

    test(
      'calculates totalTokens automatically when input and output tokens are set',
      () {
        final response = AiResponse(
          text: 'hello',
          inputTokens: 15,
          outputTokens: 25,
        );
        expect(response.totalTokens, equals(40));
      },
    );

    test('uses explicit totalTokens when provided', () {
      final response = AiResponse(
        text: 'hello',
        inputTokens: 10,
        outputTokens: 20,
        totalTokens: 100,
      );
      expect(response.totalTokens, equals(100));
    });

    test(
      'leaves totalTokens as null when inputTokens or outputTokens are missing',
      () {
        final response1 = AiResponse(text: 'hello', inputTokens: 10);
        expect(response1.totalTokens, isNull);

        final response2 = AiResponse(text: 'hello', outputTokens: 20);
        expect(response2.totalTokens, isNull);
      },
    );
  });

  group('AiService Base Class Tests', () {
    test(
      'generateContentRaw returns null when generateContent returns null',
      () async {
        final service = TestFakeAiService()..mockContent = null;
        final raw = await service.generateContentRaw(prompt: 'test');
        expect(raw, isNull);
      },
    );

    test(
      'generateContentRaw wraps generateContent text in AiResponse',
      () async {
        final service = TestFakeAiService()..mockContent = 'Hello world';
        final raw = await service.generateContentRaw(
          prompt: 'test prompt',
          temperature: 0.8,
          maxOutputTokens: 50,
        );
        expect(raw, isNotNull);
        expect(raw!.text, equals('Hello world'));
        expect(raw.isTruncated, isFalse);
        expect(service.capturedPrompt, equals('test prompt'));
        expect(service.capturedTemperature, equals(0.8));
        expect(service.capturedMaxOutputTokens, equals(50));
      },
    );
  });

  group('AiServiceJsonExtension.generateJson Tests', () {
    test('parses fenced JSON Map into a Dart Map', () async {
      final service = TestFakeAiService()
        ..mockContent = '```json\n{"name": "agent", "version": 1.2}\n```';

      final json = await service.generateJson(prompt: 'give map');
      expect(json, isA<Map<String, dynamic>>());
      expect(json['name'], equals('agent'));
      expect(json['version'], equals(1.2));
    });

    test('parses fenced JSON List into a Dart List', () async {
      final service = TestFakeAiService()
        ..mockContent = '```json\n["apple", "banana", "cherry"]\n```';

      final json = await service.generateJson(prompt: 'give list');
      expect(json, isA<List<dynamic>>());
      expect(json, equals(['apple', 'banana', 'cherry']));
    });

    test('parses unfenced raw JSON Map and List', () async {
      final serviceMap = TestFakeAiService()..mockContent = '{"status": "ok"}';
      final mapResult = await serviceMap.generateJson(prompt: 'give raw map');
      expect(mapResult, equals({'status': 'ok'}));

      final serviceList = TestFakeAiService()..mockContent = '[10, 20, 30]';
      final listResult = await serviceList.generateJson(
        prompt: 'give raw list',
      );
      expect(listResult, equals([10, 20, 30]));
    });

    test('integrates auto-continuation when autoContinueLimit > 0', () async {
      final service = TestContinuationAiService([
        AiResponse(text: '```json\n{"items": ["first",', isTruncated: true),
        AiResponse(text: ' "second"]}\n```', isTruncated: false),
      ]);

      final dummyImage = Uint8List.fromList([5, 10]);
      final result = await service.generateJson(
        prompt: 'get continuation json',
        imageBytes: dummyImage,
        temperature: 0.5,
        autoContinueLimit: 2,
      );

      expect(result, isA<Map<String, dynamic>>());
      expect(result['items'], equals(['first', 'second']));
      expect(service.capturedPrompts.length, equals(2));
      expect(service.capturedImageBytes, equals(dummyImage));
      expect(service.capturedTemperature, equals(0.5));
    });

    test(
      'returns null when generateContentWithContinuation returns null',
      () async {
        final service = TestFakeAiService()..mockContent = null;
        final result = await service.generateJson(prompt: 'null prompt');
        expect(result, isNull);
      },
    );

    test(
      'returns null fallback when AI response contains invalid JSON syntax',
      () async {
        final service = TestFakeAiService()
          ..mockContent = '```json\n{invalid json syntax:\n```';

        final result = await service.generateJson(prompt: 'invalid json');
        expect(result, isNull);
      },
    );

    test('returns null fallback for plain non-JSON text', () async {
      final service = TestFakeAiService()
        ..mockContent = 'This is plain text with no json structure';

      final result = await service.generateJson(prompt: 'plain text');
      expect(result, isNull);
    });
  });

  group('getAiService Platform Factory Tests', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test(
      'instantiates MethodChannelAiService when defaultTargetPlatform is Android',
      () {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final service = getAiService();
        expect(service, isA<MethodChannelAiService>());
      },
    );

    test('instantiates MockAiService as fallback on non-Android platforms', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(getAiService(), isA<MockAiService>());

      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(getAiService(), isA<MockAiService>());

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(getAiService(), isA<MockAiService>());

      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(getAiService(), isA<MockAiService>());

      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
      expect(getAiService(), isA<MockAiService>());
    });

    test(
      'getWebAiService throws UnsupportedError when invoked on non-Web platform',
      () {
        expect(() => getWebAiService(), throwsA(isA<UnsupportedError>()));
      },
      skip: kIsWeb,
    );
  });

  group('aiServiceProvider Tests', () {
    test('Riverpod provider initializes AiService instance without throw', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final service = container.read(aiServiceProvider);
      expect(service, isA<AiService>());
    });
  });

  group('AiServiceContinuationExtension Tests', () {
    test(
      'generateContentWithContinuation returns raw text directly when autoContinueLimit <= 0',
      () async {
        final service = TestFakeAiService()..mockContent = 'Simple content';
        final text = await service.generateContentWithContinuation(
          prompt: 'test prompt',
          autoContinueLimit: 0,
        );
        expect(text, equals('Simple content'));
      },
    );

    test(
      'generateContentWithContinuation triggers auto-continuation loop when autoContinueLimit > 0',
      () async {
        final service = TestContinuationAiService([
          AiResponse(text: 'Hello ', isTruncated: true),
          AiResponse(text: 'world!', isTruncated: false),
        ]);

        final text = await service.generateContentWithContinuation(
          prompt: 'continue prompt',
          autoContinueLimit: 2,
        );
        expect(text, equals('Hello world!'));
      },
    );

    test(
      'forwards maxOutputTokens down through auto-continuation calls',
      () async {
        final service = TestContinuationAiService([
          AiResponse(text: 'Hello ', isTruncated: true),
          AiResponse(text: 'world!', isTruncated: false),
        ]);

        final text = await service.generateContentWithContinuation(
          prompt: 'continue prompt',
          maxOutputTokens: 256,
          autoContinueLimit: 2,
        );
        expect(text, equals('Hello world!'));
        expect(service.capturedMaxOutputTokens, equals(256));
      },
    );

    test(
      'returns null when generateContentRaw returns null (autoContinueLimit <= 0)',
      () async {
        final service = TestContinuationAiService([]);
        final text = await service.generateContentWithContinuation(
          prompt: 'null prompt',
          autoContinueLimit: 0,
        );
        expect(text, isNull);
      },
    );

    test(
      'returns null when generateContentRaw returns null (autoContinueLimit > 0)',
      () async {
        final service = TestContinuationAiService([]);
        final text = await service.generateContentWithContinuation(
          prompt: 'null prompt',
          autoContinueLimit: 2,
        );
        expect(text, isNull);
      },
    );
  });
}
