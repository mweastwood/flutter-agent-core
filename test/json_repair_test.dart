import 'dart:convert';

import 'package:flutter_agent_core/flutter_agent_core.dart' as barrel;
import 'package:flutter_agent_core/src/continuation_helper.dart'
    as continuation;
import 'package:flutter_agent_core/src/json_repair.dart' as direct;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('json_repair Decoupling & Export Compatibility Tests', () {
    test(
      'repairJson function identity across direct, continuation_helper, and barrel imports',
      () {
        expect(direct.repairJson, equals(continuation.repairJson));
        expect(direct.repairJson, equals(barrel.repairJson));
      },
    );

    test('repairJson can be invoked via direct import', () {
      const truncated = '{"key": "value", "items": [1, 2, ';
      final result = direct.repairJson(truncated);
      expect(result, equals('{"key": "value", "items": [1, 2]}'));
      expect(
        jsonDecode(result),
        equals({
          'key': 'value',
          'items': [1, 2],
        }),
      );
    });

    test(
      'repairJson produces identical output across direct, continuation, and barrel calls',
      () {
        const testCases = [
          '{"name": "test", "active": true, ',
          '[{"id": 1}, {"id": 2, "pending": ',
          '{"message": "incomplete quote',
          '{"data": [1, 2, 3, ]}',
        ];

        for (final input in testCases) {
          final directResult = direct.repairJson(input);
          final continuationResult = continuation.repairJson(input);
          final barrelResult = barrel.repairJson(input);

          expect(directResult, equals(continuationResult));
          expect(directResult, equals(barrelResult));
        }
      },
    );
  });

  group('json_repair Structural Recovery Tests', () {
    test('repairs truncated maps and lists with trailing commas', () {
      const truncatedMap = '{"a": 1, "b": 2, ';
      final repairedMap = direct.repairJson(truncatedMap);
      expect(repairedMap, equals('{"a": 1, "b": 2}'));
      expect(jsonDecode(repairedMap), equals({'a': 1, 'b': 2}));

      const truncatedList = '["apple", "banana", ';
      final repairedList = direct.repairJson(truncatedList);
      expect(repairedList, equals('["apple", "banana"]'));
      expect(jsonDecode(repairedList), equals(['apple', 'banana']));
    });

    test('repairs dangling colons and incomplete keys', () {
      const danglingColon = '{"a": 1, "b": ';
      final repairedColon = direct.repairJson(danglingColon);
      expect(repairedColon, equals('{"a": 1}'));
      expect(jsonDecode(repairedColon), equals({'a': 1}));

      const unclosedKey = '{"first": 1, "sec';
      final repairedKey = direct.repairJson(unclosedKey);
      expect(repairedKey, equals('{"first": 1}'));
      expect(jsonDecode(repairedKey), equals({'first': 1}));

      const singleDanglingColon = '{"only": ';
      expect(direct.repairJson(singleDanglingColon), equals('{}'));

      const singleUnclosedKey = '{"only';
      expect(direct.repairJson(singleUnclosedKey), equals('{}'));
    });

    test('repairs unclosed strings and nested braces/brackets', () {
      const unclosedString = '{"title": "Bug Report", "desc": "Still typing';
      final repairedString = direct.repairJson(unclosedString);
      expect(
        repairedString,
        equals('{"title": "Bug Report", "desc": "Still typing"}'),
      );
      expect(
        jsonDecode(repairedString),
        equals({'title': 'Bug Report', 'desc': 'Still typing'}),
      );

      const nestedTruncated =
          '{"outer": {"list": [{"a": 1, "b": 2}, {"a": 3, "unfin';
      final repairedNested = direct.repairJson(nestedTruncated);
      expect(
        repairedNested,
        equals('{"outer": {"list": [{"a": 1, "b": 2}, {"a": 3}]}}'),
      );
      expect(
        jsonDecode(repairedNested),
        equals({
          'outer': {
            'list': [
              {'a': 1, 'b': 2},
              {'a': 3},
            ],
          },
        }),
      );
    });

    test('handles unmatched closing delimiters gracefully', () {
      final enclosed1 = direct.repairJson('{"items": [1, 2, }');
      expect(enclosed1, equals('{"items": [1, 2]}'));
      expect(
        jsonDecode(enclosed1),
        equals({
          'items': [1, 2],
        }),
      );

      final enclosed2 = direct.repairJson('[{"a": 1, "b": ]');
      expect(enclosed2, equals('[{"a": 1}]'));
      expect(
        jsonDecode(enclosed2),
        equals([
          {'a': 1},
        ]),
      );
    });

    test('preserves empty string and already valid JSON structures', () {
      expect(direct.repairJson(''), equals(''));
      const valid = '{"key": "value", "list": [1, 2, 3]}';
      expect(direct.repairJson(valid), equals(valid));
    });
  });
}
