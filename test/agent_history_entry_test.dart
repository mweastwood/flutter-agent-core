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
}
