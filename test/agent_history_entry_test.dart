import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_core/flutter_agent_core.dart' as barrel;
import 'package:flutter_agent_core/src/agent_harness.dart' as harness;
import 'package:flutter_agent_core/src/agent_history_entry.dart' as direct;

void main() {
  group('AgentHistoryEntry Decoupling & Export Compatibility Tests', () {
    test(
      'AgentHistoryEntry type identity across direct, harness, and barrel imports',
      () {
        expect(direct.AgentHistoryEntry, equals(barrel.AgentHistoryEntry));
        expect(harness.AgentHistoryEntry, equals(direct.AgentHistoryEntry));
      },
    );

    test(
      'AgentHistoryEntry can be instantiated and serialized via direct import',
      () {
        final timestamp = DateTime(2026, 9, 10, 8, 0, 0);
        final entry = direct.AgentHistoryEntry(
          timestamp: timestamp,
          prompt: 'Direct prompt',
          response: 'Direct response',
          isError: false,
          imageBytes: Uint8List.fromList([10, 20, 30]),
          imageMimeType: 'image/png',
          modelName: 'gemini-3.7-flash',
          inputTokens: 100,
          outputTokens: 50,
          estimatedCostUsd: 0.0005,
        );

        expect(entry.totalTokens, equals(150));
        expect(entry.estimatedCostUsd, equals(0.0005));

        final json = entry.toJson();
        expect(json['prompt'], equals('Direct prompt'));
        expect(json['image']['mimeType'], equals('image/png'));
        expect(json['image']['base64'], equals(base64Encode([10, 20, 30])));

        final deserialized = direct.AgentHistoryEntry.fromJson(json);
        expect(deserialized.timestamp, equals(timestamp));
        expect(deserialized.prompt, equals('Direct prompt'));
        expect(deserialized.response, equals('Direct response'));
        expect(deserialized.isError, isFalse);
        expect(
          deserialized.imageBytes,
          equals(Uint8List.fromList([10, 20, 30])),
        );
        expect(deserialized.imageMimeType, equals('image/png'));
        expect(deserialized.modelName, equals('gemini-3.7-flash'));
        expect(deserialized.inputTokens, equals(100));
        expect(deserialized.outputTokens, equals(50));
        expect(deserialized.totalTokens, equals(150));
        expect(deserialized.estimatedCostUsd, equals(0.0005));
      },
    );

    test(
      'AgentHistoryEntry serializeList works via direct and harness imports',
      () {
        final timestamp = DateTime(2026, 9, 10, 8, 0, 0);
        final entries = [
          direct.AgentHistoryEntry(
            timestamp: timestamp,
            prompt: 'Step 1',
            response: 'Result 1',
            isError: false,
          ),
        ];

        final serializedFromDirect = direct.AgentHistoryEntry.serializeList(
          entries,
        );
        final serializedFromHarness = harness.AgentHistoryEntry.serializeList(
          entries,
        );
        expect(serializedFromDirect, equals(serializedFromHarness));
        expect(serializedFromDirect, contains('"prompt": "Step 1"'));
      },
    );
  });

  group('AgentHistoryEntry.fromJson totalTokens fallback and precedence', () {
    test(
      'falls back to sum of inputTokens and outputTokens when totalTokens is omitted or null',
      () {
        final timestampStr = DateTime(2026, 9, 12, 10, 0, 0).toIso8601String();

        final entryOmitted = direct.AgentHistoryEntry.fromJson({
          'timestamp': timestampStr,
          'prompt': 'Prompt text',
          'response': 'Response text',
          'inputTokens': 120,
          'outputTokens': 30,
        });
        expect(entryOmitted.inputTokens, equals(120));
        expect(entryOmitted.outputTokens, equals(30));
        expect(entryOmitted.totalTokens, equals(150));

        final entryNull = direct.AgentHistoryEntry.fromJson({
          'timestamp': timestampStr,
          'prompt': 'Prompt text',
          'response': 'Response text',
          'inputTokens': 120,
          'outputTokens': 30,
          'totalTokens': null,
        });
        expect(entryNull.inputTokens, equals(120));
        expect(entryNull.outputTokens, equals(30));
        expect(entryNull.totalTokens, equals(150));
      },
    );

    test('explicit totalTokens takes precedence over sum', () {
      final timestampStr = DateTime(2026, 9, 12, 10, 0, 0).toIso8601String();
      final entry = direct.AgentHistoryEntry.fromJson({
        'timestamp': timestampStr,
        'prompt': 'Prompt text',
        'response': 'Response text',
        'inputTokens': 120,
        'outputTokens': 30,
        'totalTokens': 160,
      });

      expect(entry.inputTokens, equals(120));
      expect(entry.outputTokens, equals(30));
      expect(entry.totalTokens, equals(160));
    });

    test('totalTokens is null when tokens are partially or fully missing', () {
      final timestampStr = DateTime(2026, 9, 12, 10, 0, 0).toIso8601String();

      final entryNullOutput = direct.AgentHistoryEntry.fromJson({
        'timestamp': timestampStr,
        'prompt': 'Prompt text',
        'response': 'Response text',
        'inputTokens': 100,
        'outputTokens': null,
      });
      expect(entryNullOutput.inputTokens, equals(100));
      expect(entryNullOutput.outputTokens, isNull);
      expect(entryNullOutput.totalTokens, isNull);

      final entryNullInput = direct.AgentHistoryEntry.fromJson({
        'timestamp': timestampStr,
        'prompt': 'Prompt text',
        'response': 'Response text',
        'inputTokens': null,
        'outputTokens': 50,
      });
      expect(entryNullInput.inputTokens, isNull);
      expect(entryNullInput.outputTokens, equals(50));
      expect(entryNullInput.totalTokens, isNull);

      final entryNeither = direct.AgentHistoryEntry.fromJson({
        'timestamp': timestampStr,
        'prompt': 'Prompt text',
        'response': 'Response text',
      });
      expect(entryNeither.inputTokens, isNull);
      expect(entryNeither.outputTokens, isNull);
      expect(entryNeither.totalTokens, isNull);
    });
  });
}
