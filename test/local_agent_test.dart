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

    test('handles server errors gracefully by returning error JSON', () async {
      final mockClient = MockHttpClient((request) async {
        return http.Response('Internal Server Error', 500);
      });

      final service = CloudAiService(
        baseUrl: 'https://api.gemini.com/v1',
        apiKey: 'test-key',
        modelName: 'gemini-1.5-flash',
        httpClient: mockClient,
      );

      final response = await service.generateContentRaw(prompt: 'hello world');
      expect(response?.text, contains('error'));
      expect(response?.text, contains('Server returned code 500'));
      expect(response?.isTruncated, isFalse);
    });

    test(
      'handles client exception gracefully by returning exception details',
      () async {
        final mockClient = MockHttpClient((request) async {
          throw Exception('Connection failed');
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
        expect(response?.text, contains('error'));
        expect(response?.text, contains('Connection failed'));
        expect(response?.isTruncated, isFalse);
      },
    );

    test('countTokens calculates local estimate', () async {
      final service = CloudAiService(
        baseUrl: 'https://api.gemini.com/v1',
        apiKey: 'test-key',
        modelName: 'gemini-1.5-flash',
      );
      final count = await service.countTokens(prompt: 'hello world');
      expect(count, equals(3));
    });
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
    });

    test('repairJson structural balancing', () {
      // Case 7 simulation with missing closing brace before bracket
      expect(
        repairJson(
          '[\n  {\n    "name": "stopper",\n  "description": "cork",\n  "relativeBoundingBox": { "left": 0.38 }\n]',
        ),
        equals(
          '[\n  {\n    "name": "stopper",\n  "description": "cork",\n  "relativeBoundingBox": { "left": 0.38 }\n}]',
        ),
      );

      // Unclosed quotes inside string shouldn't break balancing outside string
      expect(
        repairJson('{"test": "hello { world"'),
        equals('{"test": "hello { world"}'),
      );

      // Simple unclosed array/object
      expect(repairJson('[{"a": 1'), equals('[{"a": 1}]'));
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

    test('repairJson structural balancing', () {
      // Empty string
      expect(repairJson(''), equals(''));

      // Normal valid JSON (should remain unchanged)
      expect(
        repairJson('{"a": 1, "b": [2, 3]}'),
        equals('{"a": 1, "b": [2, 3]}'),
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
    });
  });
}

class _HeuristicMockAiService extends AiService {
  int calls = 0;
  final List<Uint8List?> capturedImages = [];

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
