import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_core/flutter_agent_core.dart';
import 'package:http/http.dart' as http;

class TestMockAiService extends AiService {
  final List<Map<String, dynamic>> responses;
  int callCount = 0;
  final List<String> capturedPrompts = [];

  TestMockAiService(this.responses);

  @override
  Future<AiCoreStatus> checkStatus() async => AiCoreStatus.available;

  @override
  Future<void> triggerDownload({Duration? delay}) async {}

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
    capturedPrompts.add(prompt);
    if (callCount < responses.length) {
      return jsonEncode(responses[callCount++]);
    }
    return jsonEncode({'tool': 'finish', 'reasoning': 'Done'});
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

class _RawStringMockAiService extends AiService {
  final List<String?> rawResponses;
  int callCount = 0;
  final List<String> capturedPrompts = [];

  _RawStringMockAiService(this.rawResponses);

  @override
  Future<AiCoreStatus> checkStatus() async => AiCoreStatus.available;

  @override
  Future<void> triggerDownload({Duration? delay}) async {}

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
    capturedPrompts.add(prompt);
    if (callCount < rawResponses.length) {
      return rawResponses[callCount++];
    }
    return jsonEncode({'tool': 'finish', 'reasoning': 'Done'});
  }

  @override
  Future<int> countTokens({
    required String prompt,
    Uint8List? imageBytes,
  }) async => 0;
}

class TestStepResult {
  final String tool;
  final String feedback;
  final bool isFinish;

  TestStepResult({
    required this.tool,
    required this.feedback,
    required this.isFinish,
  });
}

class MockTextAgentDelegate implements AgentDelegate<TestStepResult> {
  int counter = 0;
  final List<String> actionsApplied = [];

  @override
  String formatPrompt(String userPrompt, List<TestStepResult> history) {
    final buffer = StringBuffer();
    buffer.write('Prompt: $userPrompt. History:');
    for (var res in history) {
      buffer.write(' [${res.tool}:${res.feedback}]');
    }
    return buffer.toString();
  }

  @override
  Uint8List? getVisualInput() => null;

  @override
  Future<String> applyAction(Map<String, dynamic> actionMap) async {
    final action = actionMap['action'] as String? ?? '';
    actionsApplied.add(action);
    if (action == 'increment') {
      counter++;
      return 'Counter is now $counter';
    }
    return 'Unknown action';
  }

  @override
  bool isFinishAction(Map<String, dynamic> actionMap) {
    return actionMap['action'] == 'stop';
  }

  @override
  TestStepResult parseStepResult(
    Map<String, dynamic> actionMap,
    String feedback,
  ) {
    final tool =
        actionMap['tool'] as String? ?? actionMap['action'] as String? ?? '';
    return TestStepResult(
      tool: tool,
      feedback: feedback,
      isFinish: isFinishAction(actionMap),
    );
  }
}

void main() {
  group('AgentHarness Generic ReAct Loop Tests', () {
    test('harness executes generic steps and updates environment', () async {
      final mockAi = TestMockAiService([
        {
          'action': 'increment',
          'understanding': 'incrementing count',
          'tool': 'inc',
          'params': [],
          'color': 0,
        },
        {
          'action': 'increment',
          'understanding': 'incrementing count again',
          'tool': 'inc',
          'params': [],
          'color': 0,
        },
        {
          'action': 'stop',
          'understanding': 'done now',
          'tool': 'finish',
          'params': [],
          'color': 0,
        },
      ]);
      final delegate = MockTextAgentDelegate();
      final harness = AgentHarness<TestStepResult>(
        aiService: mockAi,
        delegate: delegate,
      );

      final steps = await harness.runLoop(
        userPrompt: 'count to 2',
        maxSteps: 5,
      );

      expect(steps.length, equals(3));
      expect(steps[0].tool, equals('inc'));
      expect(steps[0].feedback, equals('Counter is now 1'));
      expect(steps[0].isFinish, isFalse);

      expect(steps[1].tool, equals('inc'));
      expect(steps[1].feedback, equals('Counter is now 2'));
      expect(steps[1].isFinish, isFalse);

      expect(steps[2].isFinish, isTrue);

      expect(delegate.counter, equals(2));
      expect(delegate.actionsApplied, equals(['increment', 'increment']));
    });

    test('throws Exception when AI service returns null response', () async {
      final mockAi = _RawStringMockAiService([null]);
      final delegate = MockTextAgentDelegate();
      final harness = AgentHarness<TestStepResult>(
        aiService: mockAi,
        delegate: delegate,
      );

      expect(
        () => harness.runLoop(userPrompt: 'test prompt'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('AI service returned empty response'),
          ),
        ),
      );
    });

    test(
      'catches FormatException on malformed non-JSON response and wraps error map',
      () async {
        final mockAi = _RawStringMockAiService(['Not a valid JSON']);
        final delegate = MockTextAgentDelegate();
        final harness = AgentHarness<TestStepResult>(
          aiService: mockAi,
          delegate: delegate,
        );

        final steps = await harness.runLoop(userPrompt: 'parse invalid json');

        expect(steps.length, equals(1));
        expect(steps[0].feedback, startsWith('Error: FormatException:'));
        expect(delegate.actionsApplied, isEmpty);
      },
    );

    test(
      'handles JSON response with explicit error key and terminates early',
      () async {
        final mockAi = TestMockAiService([
          {'error': 'Custom API Error'},
          {'action': 'increment'},
        ]);
        final delegate = MockTextAgentDelegate();
        final harness = AgentHarness<TestStepResult>(
          aiService: mockAi,
          delegate: delegate,
        );

        final steps = await harness.runLoop(userPrompt: 'trigger error');

        expect(steps.length, equals(1));
        expect(steps[0].feedback, equals('Error: Custom API Error'));
        expect(delegate.actionsApplied, isEmpty);
        expect(mockAi.callCount, equals(1));
      },
    );

    test(
      'continues execution when model response contains nullable, false, or empty error field',
      () async {
        final mockAi = TestMockAiService([
          {'action': 'increment', 'tool': 'inc', 'error': null},
          {'action': 'increment', 'tool': 'inc', 'error': false},
          {'action': 'increment', 'tool': 'inc', 'error': '   '},
          {'action': 'stop', 'tool': 'finish', 'error': null},
        ]);
        final delegate = MockTextAgentDelegate();
        final harness = AgentHarness<TestStepResult>(
          aiService: mockAi,
          delegate: delegate,
        );

        final steps = await harness.runLoop(
          userPrompt: 'count with null error fields',
          maxSteps: 5,
        );

        expect(steps.length, equals(4));
        expect(steps[0].feedback, equals('Counter is now 1'));
        expect(steps[1].feedback, equals('Counter is now 2'));
        expect(steps[2].feedback, equals('Counter is now 3'));
        expect(steps[3].isFinish, isTrue);
        expect(delegate.counter, equals(3));
        expect(
          delegate.actionsApplied,
          equals(['increment', 'increment', 'increment']),
        );
        expect(mockAi.callCount, equals(4));
      },
    );

    test(
      'invokes onStep callback with step result and 1-based index for normal, finish, and error steps',
      () async {
        final mockAi = TestMockAiService([
          {'action': 'increment', 'tool': 'inc'},
          {'action': 'increment', 'tool': 'inc'},
          {'action': 'stop', 'tool': 'finish'},
        ]);
        final delegate = MockTextAgentDelegate();
        final harness = AgentHarness<TestStepResult>(
          aiService: mockAi,
          delegate: delegate,
        );

        final recordedSteps = <int>[];
        final recordedResults = <TestStepResult>[];

        final steps = await harness.runLoop(
          userPrompt: 'count to 2',
          maxSteps: 5,
          onStep: (stepResult, currentStep) {
            recordedSteps.add(currentStep);
            recordedResults.add(stepResult);
          },
        );

        expect(steps.length, equals(3));
        expect(recordedSteps, equals([1, 2, 3]));
        expect(recordedResults, equals(steps));
        expect(recordedResults[0].tool, equals('inc'));
        expect(recordedResults[1].tool, equals('inc'));
        expect(recordedResults[2].isFinish, isTrue);

        final errorMockAi = TestMockAiService([
          {'action': 'increment', 'tool': 'inc'},
          {'error': 'Server overloaded'},
        ]);
        final errorDelegate = MockTextAgentDelegate();
        final errorHarness = AgentHarness<TestStepResult>(
          aiService: errorMockAi,
          delegate: errorDelegate,
        );
        final errorRecordedSteps = <int>[];
        final errorRecordedResults = <TestStepResult>[];

        final errorSteps = await errorHarness.runLoop(
          userPrompt: 'fail on step 2',
          maxSteps: 5,
          onStep: (stepResult, currentStep) {
            errorRecordedSteps.add(currentStep);
            errorRecordedResults.add(stepResult);
          },
        );

        expect(errorSteps.length, equals(2));
        expect(errorRecordedSteps, equals([1, 2]));
        expect(errorRecordedResults, equals(errorSteps));
        expect(
          errorRecordedResults[1].feedback,
          equals('Error: Server overloaded'),
        );
      },
    );

    test('stops loop execution when maxSteps count is reached', () async {
      final mockAi = TestMockAiService([
        {'action': 'increment', 'tool': 'inc'},
        {'action': 'increment', 'tool': 'inc'},
        {'action': 'increment', 'tool': 'inc'},
        {'action': 'increment', 'tool': 'inc'},
        {'action': 'increment', 'tool': 'inc'},
      ]);
      final delegate = MockTextAgentDelegate();
      final harness = AgentHarness<TestStepResult>(
        aiService: mockAi,
        delegate: delegate,
      );

      final steps = await harness.runLoop(
        userPrompt: 'keep incrementing',
        maxSteps: 3,
      );

      expect(steps.length, equals(3));
      expect(mockAi.callCount, equals(3));
      expect(delegate.counter, equals(3));
      expect(
        delegate.actionsApplied,
        equals(['increment', 'increment', 'increment']),
      );
    });
  });

  group('AgentHistoryEntry Serialization Tests', () {
    test('toJson and fromJson work correctly with and without image', () {
      final timestamp = DateTime(2026, 7, 12, 12, 0, 0);
      final entry = AgentHistoryEntry(
        timestamp: timestamp,
        prompt: 'test prompt',
        response: 'test response',
        isError: false,
        imageBytes: Uint8List.fromList([1, 2, 3]),
      );

      final jsonMap = entry.toJson();
      expect(jsonMap['timestamp'], equals(timestamp.toIso8601String()));
      expect(jsonMap['prompt'], equals('test prompt'));
      expect(jsonMap['response'], equals('test response'));
      expect(jsonMap['isError'], isFalse);
      expect(jsonMap['image']['mimeType'], equals('image/bmp'));
      expect(jsonMap['image']['base64'], equals(base64Encode([1, 2, 3])));

      final roundTrip = AgentHistoryEntry.fromJson(jsonMap);
      expect(roundTrip.timestamp, equals(timestamp));
      expect(roundTrip.prompt, equals('test prompt'));
      expect(roundTrip.response, equals('test response'));
      expect(roundTrip.isError, isFalse);
      expect(roundTrip.imageBytes, equals(Uint8List.fromList([1, 2, 3])));
      expect(roundTrip.imageMimeType, equals('image/bmp'));
    });

    test(
      'fromJson safely handles image map with metadata only (missing base64)',
      () {
        final timestamp = DateTime(2026, 7, 12, 12, 0, 0);
        final jsonMap = {
          'timestamp': timestamp.toIso8601String(),
          'prompt': 'Analyze screenshot',
          'response': 'Done',
          'isError': false,
          'image': {'mimeType': 'image/png'},
        };

        final entry = AgentHistoryEntry.fromJson(jsonMap);
        expect(entry.timestamp, equals(timestamp));
        expect(entry.prompt, equals('Analyze screenshot'));
        expect(entry.response, equals('Done'));
        expect(entry.isError, isFalse);
        expect(entry.imageBytes, isNull);
        expect(entry.imageMimeType, equals('image/png'));
      },
    );

    test('fromJson safely handles image map with explicit null base64', () {
      final timestamp = DateTime(2026, 7, 12, 12, 0, 0);
      final jsonMap = {
        'timestamp': timestamp.toIso8601String(),
        'prompt': 'Analyze screenshot',
        'response': 'Done',
        'isError': false,
        'image': {'mimeType': 'image/png', 'base64': null},
      };

      final entry = AgentHistoryEntry.fromJson(jsonMap);
      expect(entry.timestamp, equals(timestamp));
      expect(entry.prompt, equals('Analyze screenshot'));
      expect(entry.response, equals('Done'));
      expect(entry.isError, isFalse);
      expect(entry.imageBytes, isNull);
      expect(entry.imageMimeType, equals('image/png'));
    });

    test(
      'fromJson safely defaults imageMimeType when image map omits or has non-string mimeType',
      () {
        final timestamp = DateTime(2026, 7, 12, 12, 0, 0);
        final jsonMapWithoutMimeType = {
          'timestamp': timestamp.toIso8601String(),
          'prompt': 'Analyze screenshot',
          'response': 'Done',
          'isError': false,
          'image': {
            'base64': base64Encode([4, 5, 6]),
          },
        };

        final entry1 = AgentHistoryEntry.fromJson(jsonMapWithoutMimeType);
        expect(entry1.imageBytes, equals(Uint8List.fromList([4, 5, 6])));
        expect(entry1.imageMimeType, equals('image/bmp'));

        final jsonMapWithNullMimeType = {
          'timestamp': timestamp.toIso8601String(),
          'prompt': 'Analyze screenshot',
          'response': 'Done',
          'isError': false,
          'image': {
            'mimeType': null,
            'base64': base64Encode([7, 8, 9]),
          },
        };

        final entry2 = AgentHistoryEntry.fromJson(jsonMapWithNullMimeType);
        expect(entry2.imageBytes, equals(Uint8List.fromList([7, 8, 9])));
        expect(entry2.imageMimeType, equals('image/bmp'));
      },
    );

    test('serializeList formats valid JSON indent', () {
      final timestamp = DateTime(2026, 7, 12, 12, 0, 0);
      final entries = [
        AgentHistoryEntry(
          timestamp: timestamp,
          prompt: 'prompt 1',
          response: 'response 1',
          isError: false,
        ),
      ];

      final jsonStr = AgentHistoryEntry.serializeList(entries);
      expect(jsonStr, contains('"prompt": "prompt 1"'));
      expect(jsonStr, contains('"response": "response 1"'));
      expect(jsonStr, contains('"isError": false'));
    });

    test(
      'AgentHistoryEntry serializes and deserializes token metrics and estimated cost',
      () {
        final entry = AgentHistoryEntry(
          timestamp: DateTime.parse('2026-07-24T12:00:00Z'),
          prompt: 'Test prompt',
          response: 'Test response',
          isError: false,
          modelName: 'gemini-3.6-flash',
          inputTokens: 150,
          outputTokens: 50,
          estimatedCostUsd: 0.00002625,
        );

        expect(entry.inputTokens, equals(150));
        expect(entry.outputTokens, equals(50));
        expect(entry.totalTokens, equals(200));
        expect(entry.estimatedCostUsd, equals(0.00002625));

        final json = entry.toJson();
        expect(json['inputTokens'], equals(150));
        expect(json['outputTokens'], equals(50));
        expect(json['totalTokens'], equals(200));
        expect(json['estimatedCostUsd'], equals(0.00002625));

        final deserialized = AgentHistoryEntry.fromJson(json);
        expect(deserialized.inputTokens, equals(150));
        expect(deserialized.outputTokens, equals(50));
        expect(deserialized.totalTokens, equals(200));
        expect(deserialized.estimatedCostUsd, equals(0.00002625));
      },
    );
  });

  group('MethodChannelAiService Tests', () {
    const channel = MethodChannel('com.mweastwood.local_agent');
    final log = <MethodCall>[];

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
            log.add(methodCall);
            if (methodCall.method == 'checkStatus') {
              return 'available';
            }
            return null;
          });
      log.clear();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('setModelConfig invokes method channel correctly', () async {
      final service = MethodChannelAiService();
      await service.setModelConfig(releaseStage: 'preview', preference: 'fast');

      expect(log.length, equals(1));
      expect(log.first.method, equals('setModelConfig'));
      expect(
        log.first.arguments,
        equals({'releaseStage': 'preview', 'preference': 'fast'}),
      );
    });

    test('setModelConfig handles exceptions gracefully', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
            throw PlatformException(
              code: 'ERROR',
              message: 'Failed to set config',
            );
          });
      final service = MethodChannelAiService();
      await expectLater(
        service.setModelConfig(releaseStage: 'preview', preference: 'fast'),
        completes,
      );
    });

    group('checkStatus', () {
      test('maps available status correctly', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
              return 'available';
            });
        final service = MethodChannelAiService();
        final status = await service.checkStatus();
        expect(status, equals(AiCoreStatus.available));
      });

      test('maps downloading status correctly', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
              return 'downloading';
            });
        final service = MethodChannelAiService();
        final status = await service.checkStatus();
        expect(status, equals(AiCoreStatus.downloading));
      });

      test('maps downloadable status correctly', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
              return 'downloadable';
            });
        final service = MethodChannelAiService();
        final status = await service.checkStatus();
        expect(status, equals(AiCoreStatus.downloadable));
      });

      test('maps unknown string status to unavailable', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
              return 'unknown_status';
            });
        final service = MethodChannelAiService();
        final status = await service.checkStatus();
        expect(status, equals(AiCoreStatus.unavailable));
      });

      test('maps null status to unavailable', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
              return null;
            });
        final service = MethodChannelAiService();
        final status = await service.checkStatus();
        expect(status, equals(AiCoreStatus.unavailable));
      });

      test('catches exception and returns unavailable', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
              throw PlatformException(
                code: 'UNAVAILABLE',
                message: 'Not supported',
              );
            });
        final service = MethodChannelAiService();
        final status = await service.checkStatus();
        expect(status, equals(AiCoreStatus.unavailable));
      });
    });

    group('triggerDownload', () {
      test('invokes method channel triggerDownload', () async {
        final service = MethodChannelAiService();
        await service.triggerDownload();

        expect(log.length, equals(1));
        expect(log.first.method, equals('triggerDownload'));
        expect(log.first.arguments, isNull);
      });

      test(
        'invokes method channel triggerDownload with optional delay',
        () async {
          final service = MethodChannelAiService();
          await service.triggerDownload(delay: const Duration(seconds: 1));

          expect(log.length, equals(1));
          expect(log.first.method, equals('triggerDownload'));
          expect(log.first.arguments, equals({'delayMs': 1000}));
        },
      );

      test(
        'catches exception during triggerDownload without crashing',
        () async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
                throw PlatformException(
                  code: 'DOWNLOAD_ERROR',
                  message: 'Network failed',
                );
              });
          final service = MethodChannelAiService();
          await expectLater(service.triggerDownload(), completes);
        },
      );
    });

    group('countTokens', () {
      test('passes through token count returned by channel', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
              log.add(methodCall);
              if (methodCall.method == 'countTokens') {
                return 42;
              }
              return null;
            });
        final service = MethodChannelAiService();
        final img = Uint8List.fromList([1, 2, 3]);
        final count = await service.countTokens(
          prompt: 'hello',
          imageBytes: img,
        );

        expect(count, equals(42));
        expect(log.first.method, equals('countTokens'));
        expect(log.first.arguments, equals({'prompt': 'hello', 'image': img}));
      });

      test('returns 0 when channel returns null', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
              return null;
            });
        final service = MethodChannelAiService();
        final count = await service.countTokens(prompt: 'hello');
        expect(count, equals(0));
      });

      test('catches exception and returns 0', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
              throw PlatformException(
                code: 'ERROR',
                message: 'Failed to count tokens',
              );
            });
        final service = MethodChannelAiService();
        final count = await service.countTokens(prompt: 'hello');
        expect(count, equals(0));
      });
    });

    group('generateContentRaw and generateContent', () {
      test('parses Map response with text and isTruncated', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
              log.add(methodCall);
              return {'text': 'Generated text from map', 'isTruncated': true};
            });
        final service = MethodChannelAiService();
        final response = await service.generateContentRaw(
          prompt: 'test prompt',
          temperature: 0.7,
          maxOutputTokens: 100,
        );

        expect(response, isNotNull);
        expect(response!.text, equals('Generated text from map'));
        expect(response.isTruncated, isTrue);
        expect(response.isError, isFalse);

        expect(log.first.method, equals('generateContent'));
        expect(log.first.arguments['prompt'], equals('test prompt'));
        expect(log.first.arguments['temperature'], equals(0.7));
        expect(log.first.arguments['maxOutputTokens'], equals(100));
      });

      test(
        'forwards imageBytes payload in MethodChannel invocation arguments',
        () async {
          final imageBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
                log.add(methodCall);
                return {
                  'text': 'Generated text with image',
                  'isTruncated': false,
                };
              });
          final service = MethodChannelAiService();
          final response = await service.generateContentRaw(
            prompt: 'describe image',
            imageBytes: imageBytes,
          );

          expect(response, isNotNull);
          expect(response!.text, equals('Generated text with image'));
          expect(log.first.method, equals('generateContent'));
          expect(log.first.arguments['prompt'], equals('describe image'));
          expect(log.first.arguments['image'], equals(imageBytes));
        },
      );

      test(
        'parses Map response with default isTruncated false when omitted',
        () async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
                return {'text': 'Map without isTruncated'};
              });
          final service = MethodChannelAiService();
          final response = await service.generateContentRaw(
            prompt: 'test prompt',
          );

          expect(response, isNotNull);
          expect(response!.text, equals('Map without isTruncated'));
          expect(response.isTruncated, isFalse);
          expect(response.isError, isFalse);
        },
      );

      test('parses String response', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
              return 'Generated string response';
            });
        final service = MethodChannelAiService();
        final response = await service.generateContentRaw(
          prompt: 'test prompt',
        );

        expect(response, isNotNull);
        expect(response!.text, equals('Generated string response'));
        expect(response.isTruncated, isFalse);
        expect(response.isError, isFalse);
      });

      test('returns null when channel returns null without error', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
              return null;
            });
        final service = MethodChannelAiService();
        final response = await service.generateContentRaw(
          prompt: 'test prompt',
        );
        expect(response, isNull);
      });

      test('returns null when Map response contains null text', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
              return {'text': null, 'isTruncated': false};
            });
        final service = MethodChannelAiService();
        final response = await service.generateContentRaw(
          prompt: 'test prompt',
        );
        expect(response, isNull);
      });

      test(
        'returns null when channel returns non-Map and non-String unexpected return types',
        () async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
                return 42; // Integer payload
              });
          final service = MethodChannelAiService();
          final responseInt = await service.generateContentRaw(
            prompt: 'test prompt',
          );
          expect(responseInt, isNull);

          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
                return ['item1', 'item2']; // List payload
              });
          final serviceList = MethodChannelAiService();
          final responseList = await serviceList.generateContentRaw(
            prompt: 'test prompt',
          );
          expect(responseList, isNull);
        },
      );

      test(
        'retries up to 4 attempts on channel exception and succeeds',
        () async {
          int attempts = 0;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
                attempts++;
                if (attempts < 3) {
                  throw PlatformException(
                    code: 'TEMPORARY_ERROR',
                    message: 'Try again',
                  );
                }
                return 'Success on attempt 3';
              });
          final service = MethodChannelAiService();
          final response = await service.generateContentRaw(
            prompt: 'test prompt',
          );

          expect(attempts, equals(3));
          expect(response, isNotNull);
          expect(response!.text, equals('Success on attempt 3'));
          expect(response.isError, isFalse);
        },
      );

      test(
        'returns error JSON with isError true when all 4 attempts fail',
        () async {
          int attempts = 0;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
                attempts++;
                throw PlatformException(
                  code: 'CHANNEL_FAILED',
                  message: 'Failed "attempt"',
                );
              });
          final service = MethodChannelAiService();
          final response = await service.generateContentRaw(
            prompt: 'test prompt',
          );

          expect(attempts, equals(4));
          expect(response, isNotNull);
          expect(response!.isError, isTrue);
          expect(response.isTruncated, isFalse);
          expect(response.text, contains('"error"'));
          expect(
            response.text,
            contains(
              'PlatformException(CHANNEL_FAILED, Failed \\"attempt\\", null, null)',
            ),
          );
        },
      );

      test(
        'generateContent calls generateContentRaw and returns text string',
        () async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
                return 'Content string';
              });
          final service = MethodChannelAiService();
          final text = await service.generateContent(prompt: 'test prompt');
          expect(text, equals('Content string'));
        },
      );

      test(
        'generateContent returns null when generateContentRaw returns null',
        () async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
                return null;
              });
          final service = MethodChannelAiService();
          final text = await service.generateContent(prompt: 'test prompt');
          expect(text, isNull);
        },
      );

      test('retries configurable maxRetries count on failure', () async {
        int attempts = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
              attempts++;
              throw PlatformException(code: 'FAIL', message: 'Always fail');
            });

        // maxRetries = 0 -> 1 total attempt
        final zeroRetryService = MethodChannelAiService(
          maxRetries: 0,
          initialRetryDelay: Duration.zero,
        );
        final res0 = await zeroRetryService.generateContentRaw(prompt: 'test');
        expect(attempts, equals(1));
        expect(res0!.isError, isTrue);

        // maxRetries = 2 -> 3 total attempts
        attempts = 0;
        final twoRetryService = MethodChannelAiService(
          maxRetries: 2,
          initialRetryDelay: Duration.zero,
        );
        final res2 = await twoRetryService.generateContentRaw(prompt: 'test');
        expect(attempts, equals(3));
        expect(res2!.isError, isTrue);
      });

      test(
        'catches outer exception when response parsing throws TypeError',
        () async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
                return {
                  'text': 123,
                }; // 123 is not String?, throws TypeError on cast
              });
          final service = MethodChannelAiService();
          final response = await service.generateContentRaw(
            prompt: 'test prompt',
          );

          expect(response, isNotNull);
          expect(response!.isError, isTrue);
          expect(response.isTruncated, isFalse);
          expect(response.text, contains('"error"'));
        },
      );
    });

    group('calculateBackoff', () {
      test('scales exponentially without jitter', () {
        final service = MethodChannelAiService(
          initialRetryDelay: const Duration(milliseconds: 500),
          maxRetryDelay: const Duration(seconds: 15),
          enableJitter: false,
        );

        expect(
          service.calculateBackoff(1),
          equals(const Duration(milliseconds: 500)),
        );
        expect(
          service.calculateBackoff(2),
          equals(const Duration(milliseconds: 1000)),
        );
        expect(
          service.calculateBackoff(3),
          equals(const Duration(milliseconds: 2000)),
        );
        expect(
          service.calculateBackoff(4),
          equals(const Duration(milliseconds: 4000)),
        );
      });

      test('clamps backoff at maxRetryDelay', () {
        final service = MethodChannelAiService(
          initialRetryDelay: const Duration(milliseconds: 500),
          maxRetryDelay: const Duration(milliseconds: 1500),
          enableJitter: false,
        );

        expect(
          service.calculateBackoff(1),
          equals(const Duration(milliseconds: 500)),
        );
        expect(
          service.calculateBackoff(2),
          equals(const Duration(milliseconds: 1000)),
        );
        expect(
          service.calculateBackoff(3),
          equals(const Duration(milliseconds: 1500)),
        );
        expect(
          service.calculateBackoff(4),
          equals(const Duration(milliseconds: 1500)),
        );
      });

      test('returns Duration.zero when boundedMs is 0', () {
        final serviceZeroInitial = MethodChannelAiService(
          initialRetryDelay: Duration.zero,
        );
        expect(serviceZeroInitial.calculateBackoff(1), equals(Duration.zero));

        final serviceZeroMax = MethodChannelAiService(
          maxRetryDelay: Duration.zero,
        );
        expect(serviceZeroMax.calculateBackoff(1), equals(Duration.zero));
      });

      test('prevents bit-shift overflow for large attempt counts', () {
        final service = MethodChannelAiService(
          initialRetryDelay: const Duration(milliseconds: 500),
          maxRetryDelay: const Duration(seconds: 15),
          enableJitter: false,
        );

        expect(
          service.calculateBackoff(65),
          equals(const Duration(seconds: 15)),
        );
        expect(
          service.calculateBackoff(100),
          equals(const Duration(seconds: 15)),
        );
      });

      test('produces deterministic output with seeded random and jitter', () {
        final service1 = MethodChannelAiService(
          initialRetryDelay: const Duration(milliseconds: 500),
          enableJitter: true,
          random: Random(42),
        );
        final service2 = MethodChannelAiService(
          initialRetryDelay: const Duration(milliseconds: 500),
          enableJitter: true,
          random: Random(42),
        );

        final backoff1 = service1.calculateBackoff(1);
        final backoff2 = service2.calculateBackoff(1);
        expect(backoff1, equals(backoff2));
      });

      test('applies jitter within +/-25% bounds', () {
        final service = MethodChannelAiService(
          initialRetryDelay: const Duration(milliseconds: 1000),
          maxRetryDelay: const Duration(seconds: 15),
          enableJitter: true,
        );

        for (int i = 0; i < 20; i++) {
          final backoff = service.calculateBackoff(1);
          // 1000ms with +/-25% jitter is between 750ms and 1250ms
          expect(backoff.inMilliseconds, greaterThanOrEqualTo(750));
          expect(backoff.inMilliseconds, lessThanOrEqualTo(1250));
        }
      });
    });
  });

  group('MockAiService Tests', () {
    test(
      'triggerDownload transitions status with custom delay parameter',
      () async {
        final mock = MockAiService();
        mock.setMockStatus(AiCoreStatus.downloadable);
        expect(await mock.checkStatus(), equals(AiCoreStatus.downloadable));

        final future = mock.triggerDownload(
          delay: const Duration(milliseconds: 50),
        );
        expect(await mock.checkStatus(), equals(AiCoreStatus.downloading));

        await future;
        expect(await mock.checkStatus(), equals(AiCoreStatus.available));
      },
    );

    test(
      'triggerDownload uses default delay when parameter is omitted',
      () async {
        final mock = MockAiService(
          downloadDelay: const Duration(milliseconds: 50),
        );
        mock.setMockStatus(AiCoreStatus.downloadable);
        expect(await mock.checkStatus(), equals(AiCoreStatus.downloadable));

        final future = mock.triggerDownload();
        expect(await mock.checkStatus(), equals(AiCoreStatus.downloading));
        await future;
        expect(await mock.checkStatus(), equals(AiCoreStatus.available));
      },
    );
  });

  group('Auto-Continuation Tests', () {
    test('does not continue if autoContinueLimit is 0', () async {
      final service = MockAiService();
      final response = await service.generateContentWithContinuation(
        prompt: 'simulate_truncation',
        autoContinueLimit: 0,
      );
      expect(response, equals('Response is partial and'));
    });

    test('continues to completion if autoContinueLimit allows', () async {
      final service = MockAiService();
      final response = await service.generateContentWithContinuation(
        prompt: 'simulate_truncation',
        autoContinueLimit: 1,
      );
      expect(
        response,
        equals('Response is partial and finished successfully.'),
      );
    });

    test(
      'detects truncation via JSON heuristic and cleans chunk fences',
      () async {
        final service = _HeuristicMockAiService();
        final dummyImageBytes = Uint8List.fromList([1, 2, 3]);
        final response = await service.generateContentWithContinuation(
          prompt: 'get shapes',
          imageBytes: dummyImageBytes,
          autoContinueLimit: 2,
        );
        expect(service.calls, equals(2));
        expect(
          response,
          equals('{"shapes": [\n  {"type": "circle", "radius": 5}\n]\n}'),
        );
        expect(service.capturedImages[0], equals(dummyImageBytes));
        expect(service.capturedImages[1], equals(dummyImageBytes));
      },
    );

    test(
      'countTokens calculates expected mock value with and without image',
      () async {
        final service = _HeuristicMockAiService();
        final countNoImage = await service.countTokens(prompt: 'hello world');
        expect(countNoImage, equals(3)); // 11 / 4 rounded

        final countWithImage = await service.countTokens(
          prompt: 'hello world',
          imageBytes: Uint8List.fromList([1, 2, 3]),
        );
        expect(countWithImage, equals(259)); // 3 + 256
      },
    );

    test(
      'returns error response immediately if initial completion has isError: true',
      () async {
        final result = await runWithAutoContinuation(
          initialPrompt: 'test prompt',
          autoContinueLimit: 3,
          runCompletion: (prompt) async {
            return AiResponse(
              text: '{"error": "Initial request failed"}',
              isError: true,
            );
          },
        );
        expect(result, equals('{"error": "Initial request failed"}'));
      },
    );

    test(
      'breaks and avoids stitching continuation error response when continuation returns isError: true',
      () async {
        var callCount = 0;
        final result = await runWithAutoContinuation(
          initialPrompt: 'test prompt',
          autoContinueLimit: 3,
          runCompletion: (prompt) async {
            callCount++;
            if (callCount == 1) {
              return AiResponse(
                text: 'Partial response that is truncated',
                isTruncated: true,
                isError: false,
              );
            }
            return AiResponse(
              text: '{"error": "Server returned code 503"}',
              isTruncated: false,
              isError: true,
            );
          },
        );
        expect(callCount, equals(2));
        expect(result, equals('Partial response that is truncated'));
      },
    );

    test(
      'breaks and repairs JSON without error JSON when continuation returns isError: true on truncated JSON',
      () async {
        var callCount = 0;
        final result = await runWithAutoContinuation(
          initialPrompt: 'generate json',
          autoContinueLimit: 3,
          runCompletion: (prompt) async {
            callCount++;
            if (callCount == 1) {
              return AiResponse(
                text: '{"items": ["item1"',
                isTruncated: true,
                isError: false,
              );
            }
            return AiResponse(
              text: '{"error": "Rate limit reached"}',
              isTruncated: false,
              isError: true,
            );
          },
        );
        expect(callCount, equals(2));
        expect(result, equals('{"items": ["item1"]}'));
      },
    );
  });

  group('CloudAiService Tests', () {
    test(
      'sends request and parses OpenAI-compatible response correctly',
      () async {
        final mockClient = MockHttpClient((request) async {
          expect(
            request.url.toString(),
            equals('https://api.gemini.com/v1/chat/completions'),
          );
          expect(request.headers['Authorization'], equals('Bearer test-key'));

          final bodyString = await request.finalize().bytesToString();
          final bodyData = jsonDecode(bodyString);
          expect(bodyData['model'], equals('gemini-1.5-flash'));
          expect(bodyData['messages'][0]['content'], equals('hello world'));

          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'hi there'},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        });

        final service = CloudAiService(
          baseUrl: 'https://api.gemini.com/v1',
          apiKey: 'test-key',
          modelName: 'gemini-1.5-flash',
          httpClient: mockClient,
        );

        final response = await service.generateContentRaw(
          prompt: 'hello world',
        );
        expect(response?.text, equals('hi there'));
        expect(response?.isTruncated, isFalse);
      },
    );

    test(
      'normalizes baseUrl with trailing slash and whitespace without double slashes in request URL',
      () async {
        final testCases = [
          'https://api.openai.com/v1',
          'https://api.openai.com/v1/',
          'https://api.openai.com/v1///',
          '  https://api.openai.com/v1/  ',
          'https://open.bigmodel.cn/api/paas/v4/',
        ];

        for (final baseUrl in testCases) {
          final expectedUrl =
              '${baseUrl.trim().replaceAll(RegExp(r'/+$'), '')}/chat/completions';
          final mockClient = MockHttpClient((request) async {
            expect(request.url.toString(), equals(expectedUrl));
            expect(request.url.path, isNot(contains('//')));
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': 'ok'},
                    'finish_reason': 'stop',
                  },
                ],
              }),
              200,
            );
          });

          final service = CloudAiService(
            baseUrl: baseUrl,
            apiKey: 'test-key',
            modelName: 'gemini-1.5-flash',
            httpClient: mockClient,
          );

          final response = await service.generateContentRaw(
            prompt: 'test prompt',
          );
          expect(response?.text, equals('ok'));
        }
      },
    );

    test(
      'sanitizes non-ASCII code points and whitespace from apiKey in Authorization header',
      () async {
        final mockClient = MockHttpClient((request) async {
          expect(
            request.headers['Authorization'],
            equals('Bearer test-clean-key'),
          );
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'ok'},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        });

        // Key contains zero-width spaces (\u200B), non-breaking space, curly quotes, and leading/trailing whitespace
        final service = CloudAiService(
          baseUrl: 'https://api.gemini.com/v1',
          apiKey: ' \u200B“test-clean-key”\u200B ',
          modelName: 'gemini-1.5-flash',
          httpClient: mockClient,
        );

        final response = await service.generateContentRaw(
          prompt: 'hello world',
        );
        expect(response?.text, equals('ok'));
      },
    );

    test('correctly detects truncation if finish_reason is length', () async {
      final mockClient = MockHttpClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'partial response'},
                'finish_reason': 'length',
              },
            ],
          }),
          200,
        );
      });

      final service = CloudAiService(
        baseUrl: 'https://api.gemini.com/v1',
        apiKey: 'test-key',
        modelName: 'gemini-1.5-flash',
        httpClient: mockClient,
      );

      final response = await service.generateContentRaw(prompt: 'hello world');
      expect(response?.text, equals('partial response'));
      expect(response?.isTruncated, isTrue);
    });

    test('retries on 503 and succeeds on subsequent attempt', () async {
      int attempts = 0;
      final mockClient = MockHttpClient((request) async {
        attempts++;
        if (attempts < 3) {
          return http.Response('Service Unavailable', 503);
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': 'success after retry',
                },
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      });

      final service = CloudAiService(
        baseUrl: 'https://api.gemini.com/v1',
        apiKey: 'test-key',
        modelName: 'gemini-1.5-flash',
        initialRetryDelay: Duration.zero,
        httpClient: mockClient,
      );

      final response = await service.generateContentRaw(prompt: 'hello world');
      expect(attempts, equals(3));
      expect(response?.text, equals('success after retry'));
      expect(response?.isError, isFalse);
    });

    test(
      'handles server errors gracefully by returning error JSON with isError: true after all retries',
      () async {
        int attempts = 0;
        final mockClient = MockHttpClient((request) async {
          attempts++;
          return http.Response('Internal Server Error', 500);
        });

        final service = CloudAiService(
          baseUrl: 'https://api.gemini.com/v1',
          apiKey: 'test-key',
          modelName: 'gemini-1.5-flash',
          maxRetries: 4,
          initialRetryDelay: Duration.zero,
          httpClient: mockClient,
        );

        final response = await service.generateContentRaw(
          prompt: 'hello world',
        );
        expect(attempts, equals(5));
        expect(response?.text, contains('error'));
        expect(response?.text, contains('Server returned code 500'));
        expect(response?.isTruncated, isFalse);
        expect(response?.isError, isTrue);
      },
    );

    test('does not retry non-retryable 400 Bad Request errors', () async {
      int attempts = 0;
      final mockClient = MockHttpClient((request) async {
        attempts++;
        return http.Response('Bad Request', 400);
      });

      final service = CloudAiService(
        baseUrl: 'https://api.gemini.com/v1',
        apiKey: 'test-key',
        modelName: 'gemini-1.5-flash',
        initialRetryDelay: Duration.zero,
        httpClient: mockClient,
      );

      final response = await service.generateContentRaw(prompt: 'hello world');
      expect(attempts, equals(1));
      expect(response?.text, contains('error'));
      expect(response?.text, contains('Server returned code 400'));
      expect(response?.isError, isTrue);
    });

    test(
      'handles client exception gracefully by returning exception details with isError: true after retries',
      () async {
        int attempts = 0;
        final mockClient = MockHttpClient((request) async {
          attempts++;
          throw Exception('Connection failed');
        });

        final service = CloudAiService(
          baseUrl: 'https://api.gemini.com/v1',
          apiKey: 'test-key',
          modelName: 'gemini-1.5-flash',
          maxRetries: 3,
          initialRetryDelay: Duration.zero,
          httpClient: mockClient,
        );

        final response = await service.generateContentRaw(
          prompt: 'hello world',
        );
        expect(attempts, equals(4));
        expect(response?.text, contains('error'));
        expect(response?.text, contains('Connection failed'));
        expect(response?.isTruncated, isFalse);
        expect(response?.isError, isTrue);
      },
    );

    test(
      'clears stale exception when subsequent retry receives HTTP error response',
      () async {
        int attempts = 0;
        final mockClient = MockHttpClient((request) async {
          attempts++;
          if (attempts == 1) {
            throw Exception('Network connection dropped');
          }
          return http.Response('Bad Request', 400);
        });

        final service = CloudAiService(
          baseUrl: 'https://api.gemini.com/v1',
          apiKey: 'test-key',
          modelName: 'gemini-1.5-flash',
          initialRetryDelay: Duration.zero,
          httpClient: mockClient,
        );

        final response = await service.generateContentRaw(
          prompt: 'hello world',
        );
        expect(attempts, equals(2));
        expect(response?.text, contains('Server returned code 400'));
        expect(response?.text, isNot(contains('Network connection dropped')));
        expect(response?.isError, isTrue);
      },
    );

    test('honors Retry-After header on 503 or 429 response', () async {
      int attempts = 0;
      final mockClient = MockHttpClient((request) async {
        attempts++;
        if (attempts == 1) {
          return http.Response(
            'Rate limit exceeded',
            429,
            headers: {'retry-after': '1'},
          );
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'after rate limit'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      });

      final service = CloudAiService(
        baseUrl: 'https://api.gemini.com/v1',
        apiKey: 'test-key',
        modelName: 'gemini-1.5-flash',
        initialRetryDelay: Duration.zero,
        httpClient: mockClient,
      );

      final response = await service.generateContentRaw(prompt: 'hello world');
      expect(attempts, equals(2));
      expect(response?.text, equals('after rate limit'));
      expect(response?.isError, isFalse);
    });

    test(
      'handles case-insensitive Retry-After header variations in calculateBackoff',
      () {
        final service = CloudAiService(
          baseUrl: 'https://api.gemini.com/v1',
          apiKey: 'test-key',
          modelName: 'gemini-1.5-flash',
        );

        final pascalResponse = http.Response(
          'Too Many Requests',
          429,
          headers: {'Retry-After': '5'},
        );
        expect(
          service.calculateBackoff(1, pascalResponse),
          equals(const Duration(seconds: 5)),
        );

        final upperResponse = http.Response(
          'Service Unavailable',
          503,
          headers: {'RETRY-AFTER': '12'},
        );
        expect(
          service.calculateBackoff(1, upperResponse),
          equals(const Duration(seconds: 12)),
        );

        final lowerResponse = http.Response(
          'Service Unavailable',
          503,
          headers: {'retry-after': '3'},
        );
        expect(
          service.calculateBackoff(1, lowerResponse),
          equals(const Duration(seconds: 3)),
        );
      },
    );

    test('prevents bit-shift overflow for large retry attempt counts', () {
      final service = CloudAiService(
        baseUrl: 'https://api.gemini.com/v1',
        apiKey: 'test-key',
        modelName: 'gemini-1.5-flash',
        initialRetryDelay: const Duration(milliseconds: 1000),
        maxRetryDelay: const Duration(seconds: 30),
        enableJitter: false,
      );

      expect(
        service.calculateBackoff(65, null),
        equals(const Duration(seconds: 30)),
      );
      expect(
        service.calculateBackoff(100, null),
        equals(const Duration(seconds: 30)),
      );
    });

    test('preserves sub-100ms small retry delays when jitter is enabled', () {
      final service = CloudAiService(
        baseUrl: 'https://api.gemini.com/v1',
        apiKey: 'test-key',
        modelName: 'gemini-1.5-flash',
        initialRetryDelay: const Duration(milliseconds: 50),
        maxRetryDelay: const Duration(seconds: 5),
        enableJitter: true,
      );

      for (int i = 0; i < 20; i++) {
        final backoff = service.calculateBackoff(1, null);
        expect(backoff.inMilliseconds, greaterThanOrEqualTo(1));
        // 50ms with +/-25% jitter is between 37ms and 63ms, well below 100ms
        expect(backoff.inMilliseconds, lessThan(100));
        expect(backoff.inMilliseconds, greaterThanOrEqualTo(37));
        expect(backoff.inMilliseconds, lessThanOrEqualTo(63));
      }
    });

    test(
      'returns null gracefully on empty choices array in 200 response',
      () async {
        final mockClient = MockHttpClient((request) async {
          return http.Response(jsonEncode({'choices': []}), 200);
        });
        final service = CloudAiService(
          baseUrl: 'https://api.gemini.com/v1',
          apiKey: 'test-key',
          modelName: 'gemini-1.5-flash',
          httpClient: mockClient,
        );

        final rawRes = await service.generateContentRaw(prompt: 'test');
        expect(rawRes, isNull);

        final res = await service.generateContent(prompt: 'test');
        expect(res, isNull);
      },
    );

    test(
      'returns null gracefully on missing or null choices in 200 response',
      () async {
        final mockClient = MockHttpClient((request) async {
          return http.Response(jsonEncode({'choices': null}), 200);
        });
        final service = CloudAiService(
          baseUrl: 'https://api.gemini.com/v1',
          apiKey: 'test-key',
          modelName: 'gemini-1.5-flash',
          httpClient: mockClient,
        );

        final rawRes = await service.generateContentRaw(prompt: 'test');
        expect(rawRes, isNull);

        final res = await service.generateContent(prompt: 'test');
        expect(res, isNull);
      },
    );

    test('checkStatus returns AiCoreStatus.available', () async {
      final service = CloudAiService(
        baseUrl: 'https://api.gemini.com/v1',
        apiKey: 'test-key',
        modelName: 'gemini-1.5-flash',
      );
      final status = await service.checkStatus();
      expect(status, equals(AiCoreStatus.available));
    });

    test(
      'triggerDownload handles null and non-null delay durations without error',
      () async {
        final service = CloudAiService(
          baseUrl: 'https://api.gemini.com/v1',
          apiKey: 'test-key',
          modelName: 'gemini-1.5-flash',
        );
        await expectLater(service.triggerDownload(), completes);
        await expectLater(
          service.triggerDownload(delay: const Duration(milliseconds: 10)),
          completes,
        );
      },
    );

    test(
      'setModelConfig completes without error as a no-op compatibility method',
      () async {
        final service = CloudAiService(
          baseUrl: 'https://api.gemini.com/v1',
          apiKey: 'test-key',
          modelName: 'gemini-1.5-flash',
        );
        await expectLater(
          service.setModelConfig(releaseStage: 'preview', preference: 'fast'),
          completes,
        );
      },
    );

    test(
      'formats multimodal image payload with base64 data encoding when imageBytes is provided',
      () async {
        final imageBytes = Uint8List.fromList([
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
        ]);
        final expectedBase64 = base64Encode(imageBytes);

        final mockClient = MockHttpClient((request) async {
          final bodyString = await request.finalize().bytesToString();
          final bodyData = jsonDecode(bodyString);
          expect(bodyData['messages'], hasLength(1));
          final message = bodyData['messages'][0];
          expect(message['role'], equals('user'));
          expect(message['content'], isA<List>());
          final contentList = message['content'] as List;
          expect(contentList, hasLength(2));
          expect(
            contentList[0],
            equals({'type': 'text', 'text': 'Describe this image'}),
          );
          expect(
            contentList[1],
            equals({
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,$expectedBase64'},
            }),
          );

          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': 'It is a PNG header.',
                  },
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        });

        final service = CloudAiService(
          baseUrl: 'https://api.gemini.com/v1',
          apiKey: 'test-key',
          modelName: 'gemini-1.5-flash',
          httpClient: mockClient,
        );

        final response = await service.generateContentRaw(
          prompt: 'Describe this image',
          imageBytes: imageBytes,
        );
        expect(response?.text, equals('It is a PNG header.'));
        expect(response?.isError, isFalse);
      },
    );

    test(
      'generateContent wrapper delegates to generateContentRaw and returns text string',
      () async {
        final mockClient = MockHttpClient((request) async {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': 'Response from wrapper test',
                  },
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        });

        final service = CloudAiService(
          baseUrl: 'https://api.gemini.com/v1',
          apiKey: 'test-key',
          modelName: 'gemini-1.5-flash',
          httpClient: mockClient,
        );

        final text = await service.generateContent(
          prompt: 'Wrapper prompt test',
        );
        expect(text, equals('Response from wrapper test'));
      },
    );

    test(
      'catches FormatException on malformed JSON body in HTTP 200 response and returns isError: true',
      () async {
        final mockClient = MockHttpClient((request) async {
          return http.Response('{ invalid json body', 200);
        });

        final service = CloudAiService(
          baseUrl: 'https://api.gemini.com/v1',
          apiKey: 'test-key',
          modelName: 'gemini-1.5-flash',
          httpClient: mockClient,
        );

        final response = await service.generateContentRaw(
          prompt: 'trigger parse error',
        );
        expect(response, isNotNull);
        expect(response!.isError, isTrue);
        expect(response.isTruncated, isFalse);
        expect(response.text, contains('"error":'));
        expect(response.text, contains('FormatException'));
      },
    );

    test('countTokens calculates local estimate and image overhead', () async {
      final service = CloudAiService(
        baseUrl: 'https://api.gemini.com/v1',
        apiKey: 'test-key',
        modelName: 'gemini-1.5-flash',
      );
      final count = await service.countTokens(prompt: 'hello world');
      expect(count, equals(3));

      final imageBytes = Uint8List.fromList([1, 2, 3, 4]);
      final countWithImage = await service.countTokens(
        prompt: 'hello world',
        imageBytes: imageBytes,
      );
      expect(countWithImage, equals(3 + 256));

      final emptyImageBytes = Uint8List(0);
      final countWithEmptyImage = await service.countTokens(
        prompt: 'hello world',
        imageBytes: emptyImageBytes,
      );
      expect(countWithEmptyImage, equals(3));
    });

    test(
      'CloudAiService parses usage tokens and calculates estimatedCostUsd',
      () async {
        final mockClient = MockHttpClient((request) async {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'Hello from AI'},
                  'finish_reason': 'stop',
                },
              ],
              'usage': {
                'prompt_tokens': 100,
                'completion_tokens': 20,
                'total_tokens': 120,
              },
            }),
            200,
          );
        });

        final service = CloudAiService(
          baseUrl: 'https://api.example.com',
          apiKey: 'test-key',
          modelName: 'gemini-3.6-flash',
          httpClient: mockClient,
        );

        final res = await service.generateContentRaw(prompt: 'Hello');
        expect(res, isNotNull);
        expect(res!.text, equals('Hello from AI'));
        expect(res.inputTokens, equals(100));
        expect(res.outputTokens, equals(20));
        expect(res.totalTokens, equals(120));
        // gemini-3.6-flash: 100/1M * 1.50 + 20/1M * 7.50 = 0.00015 + 0.00015 = 0.00030
        expect(res.estimatedCostUsd, closeTo(0.0003, 0.0000001));
      },
    );
  });

  group('Heuristic & Chunk Cleaning Tests', () {
    test('isTruncatedHeuristic native override', () {
      expect(isTruncatedHeuristic('{}', true), isTrue);
      expect(isTruncatedHeuristic('', false), isFalse);
      expect(isTruncatedHeuristic('   ', false), isFalse);
    });

    test('isTruncatedHeuristic JSON checks', () {
      // Incomplete JSON array/object
      expect(isTruncatedHeuristic('[1, 2', false), isTrue);
      expect(isTruncatedHeuristic('{"foo": "bar"', false), isTrue);

      // Complete JSON array/object
      expect(isTruncatedHeuristic('[1, 2]', false), isFalse);
      expect(isTruncatedHeuristic('{"foo": "bar"}', false), isFalse);
    });

    test('isTruncatedHeuristic code fence checks', () {
      expect(isTruncatedHeuristic('```json\n{"foo": "bar"', false), isTrue);
      expect(
        isTruncatedHeuristic('```json\n{"foo": "bar"}```', false),
        isFalse,
      );
    });

    test('isTruncatedHeuristic text truncation endings', () {
      // Ends in alphanumeric or comma
      expect(isTruncatedHeuristic('Continuing on next line,', false), isTrue);
      expect(isTruncatedHeuristic('Finished with word', false), isTrue);

      // Ends with sentence punctuation
      expect(isTruncatedHeuristic('Finished with period.', false), isFalse);
      expect(isTruncatedHeuristic('What is this?', false), isFalse);
      expect(isTruncatedHeuristic('Exciting!', false), isFalse);
    });

    test('cleanContinuationChunk code fences', () {
      expect(cleanContinuationChunk('```json\nhello\n```'), equals('hello'));
      expect(cleanContinuationChunk('```\nhello```'), equals('hello'));
    });

    test('cleanContinuationChunk conversational headers', () {
      expect(
        cleanContinuationChunk('Here is the continuation: hello'),
        equals('hello'),
      );
      expect(cleanContinuationChunk('continuing: hello'), equals('hello'));
      expect(cleanContinuationChunk('continuation: hello'), equals('hello'));
      expect(
        cleanContinuationChunk(
          'Continuing from where it was truncated: , "top"',
        ),
        equals(', "top"'),
      );
      expect(
        cleanContinuationChunk(
          'Here is the continued JSON response:\n\n{"left": 0.4}',
        ),
        equals('{"left": 0.4}'),
      );
      expect(
        cleanContinuationChunk('Continuing the list:\n- First component'),
        equals('- First component'),
      );
      // Verify we do NOT strip normal text continuations ending in colons that are not followed by JSON structural chars
      expect(
        cleanContinuationChunk('blade: steel hilt'),
        equals('blade: steel hilt'),
      );
    });

    test('cleanContinuationChunk preserves leading/trailing spaces', () {
      expect(cleanContinuationChunk(' hello '), equals(' hello '));
    });

    test('stitchContinuation boundary deduplication', () {
      // General case
      expect(stitchContinuation('abcde', 'cdefgh'), equals('abcdefgh'));
      expect(stitchContinuation('hello', 'world'), equals('helloworld'));
      expect(stitchContinuation('hello wor', 'world'), equals('hello world'));

      // Case 6 simulation
      final t6 =
          '[\n  {\n    "name": "stopper",\n    "description": "Cork stopper",\n    "relativeBoundingBox": { "left": 0.38';
      final n6 =
          '{\n    "name": "stopper",\n    "description": "Cork stopper",\n    "relativeBoundingBox": { "left": 0.35, "top": 0.05 }';
      expect(
        stitchContinuation(t6, n6),
        equals(
          '[\n  {\n    "name": "stopper",\n    "description": "Cork stopper",\n    "relativeBoundingBox": { "left": 0.35, "top": 0.05 }',
        ),
      );

      // Case 7 simulation
      final t7 = ',\n    "name": "';
      final n7 = '"name": "stopper",';
      expect(stitchContinuation(t7, n7), equals(',\n    "name": "stopper",'));

      // Case 8 simulation
      final t8 = '[\n  {\n    "name":';
      final n8 = '{\n    "name": "bottle_neck"';
      expect(
        stitchContinuation(t8, n8),
        equals('[\n  {\n    "name": "bottle_neck"'),
      );

      // Edge case: Short overlaps (< 3 characters) should NOT be matched to prevent word corruption
      expect(stitchContinuation('draw a', 'apple'), equals('draw aapple'));
      expect(stitchContinuation('cat', 'attack'), equals('catattack'));

      // Edge case: Large overlaps (> 500 characters) should be capped at 500
      final longStr = 'a' * 600;
      expect(
        stitchContinuation(longStr, 'a' * 600 + 'b'),
        equals('a' * 700 + 'b'),
      );

      // Edge case: Empty or short strings
      expect(stitchContinuation('', 'abc'), equals('abc'));
      expect(stitchContinuation('abc', ''), equals('abc'));
      expect(stitchContinuation('ab', 'ab'), equals('abab'));
      expect(stitchContinuation('abc', 'abc'), equals('abc'));

      // Non-zero offset overlap matching
      expect(
        stitchContinuation('prefix-overlap-12345extra', 'overlap-12345suffix'),
        equals('prefix-overlap-12345suffix'),
      );
    });

    test('repairJson structural balancing', () {
      // Empty string
      expect(repairJson(''), equals(''));

      // Normal valid JSON (should remain unchanged)
      expect(
        repairJson('{"a": 1, "b": [2, 3]}'),
        equals('{"a": 1, "b": [2, 3]}'),
      );

      // Simple unclosed array/object
      expect(repairJson('[{"a": 1'), equals('[{"a": 1}]'));

      // Case 7 simulation with missing closing brace before bracket
      expect(
        repairJson(
          '[\n  {\n    "name": "stopper",\n  "description": "cork",\n  "relativeBoundingBox": { "left": 0.38 }\n]',
        ),
        equals(
          '[\n  {\n    "name": "stopper",\n  "description": "cork",\n  "relativeBoundingBox": { "left": 0.38 }\n}]',
        ),
      );

      // Nested unclosed structures
      expect(repairJson('[ { "a": { "b": 1'), equals('[ { "a": { "b": 1}}]'));

      // Escaped quotes inside JSON string
      expect(
        repairJson('{"test": "hello \\"world\\" { nested"'),
        equals('{"test": "hello \\"world\\" { nested"}'),
      );

      // Brackets/braces characters inside JSON string
      expect(repairJson('{"test": "}"}'), equals('{"test": "}"}'));

      // Truncated string literal inside an object (Issue #33)
      final truncatedObj =
          '{"title": "Bug Report", "content": "Incomplete string';
      final repairedObj = repairJson(truncatedObj);
      expect(
        repairedObj,
        equals('{"title": "Bug Report", "content": "Incomplete string"}'),
      );
      expect(
        jsonDecode(repairedObj),
        equals({'title': 'Bug Report', 'content': 'Incomplete string'}),
      );

      // Truncated string literal containing nested structural characters
      final truncatedStructural = '{"msg": "Hello { world';
      final repairedStructural = repairJson(truncatedStructural);
      expect(repairedStructural, equals('{"msg": "Hello { world"}'));
      expect(jsonDecode(repairedStructural), equals({'msg': 'Hello { world'}));

      // Truncated string literal with trailing backslash / escaped character
      final truncatedEscape = r'{"path": "C:\\folder\';
      final repairedEscape = repairJson(truncatedEscape);
      expect(repairedEscape, equals(r'{"path": "C:\\folder\\"}'));
      expect(jsonDecode(repairedEscape), equals({'path': r'C:\folder\'}));

      // Truncated string in array
      final truncatedArr = '["item1", "item2 unclosed';
      final repairedArr = repairJson(truncatedArr);
      expect(repairedArr, equals('["item1", "item2 unclosed"]'));
      expect(jsonDecode(repairedArr), equals(['item1', 'item2 unclosed']));
    });
  });
}

class _HeuristicMockAiService extends AiService {
  int calls = 0;
  final List<Uint8List?> capturedImages = [];

  @override
  Future<AiCoreStatus> checkStatus() async => AiCoreStatus.available;
  @override
  Future<void> triggerDownload({Duration? delay}) async {}
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
    calls++;
    capturedImages.add(imageBytes);
    if (calls == 1) {
      return AiResponse(
        text: '{"shapes": [\n  {"type": "circle"',
        isTruncated: false,
      );
    } else {
      return AiResponse(
        text: '```json\n, "radius": 5}\n]\n}```',
        isTruncated: false,
      );
    }
  }

  @override
  Future<String?> generateContent({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int? maxOutputTokens,
  }) async => null;

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

class MockHttpClient extends http.BaseClient {
  final Future<http.Response> Function(http.BaseRequest request) sendHandler;
  MockHttpClient(this.sendHandler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await sendHandler(request);
    final bodyBytes = response.bodyBytes;
    return http.StreamedResponse(
      Stream.value(bodyBytes),
      response.statusCode,
      headers: response.headers,
      contentLength: bodyBytes.length,
      request: request,
    );
  }
}
