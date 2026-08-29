import 'dart:convert';

import 'package:flutter_agent_core/src/continuation_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('repairJson Tests', () {
    test('handles truncated maps with trailing commas', () {
      const truncatedMap = '{"a": 1, "b": 2, ';
      final repairedMap = repairJson(truncatedMap);
      expect(repairedMap, equals('{"a": 1, "b": 2}'));
      expect(jsonDecode(repairedMap), equals({'a': 1, 'b': 2}));

      const truncatedWithNewline = '{"a": 1, "b": 2,\n  ';
      final repairedWithNewline = repairJson(truncatedWithNewline);
      expect(repairedWithNewline, equals('{"a": 1, "b": 2}'));
      expect(jsonDecode(repairedWithNewline), equals({'a': 1, 'b': 2}));
    });

    test('handles truncated lists with trailing commas', () {
      const truncatedList = '["apple", "banana", ';
      final repairedList = repairJson(truncatedList);
      expect(repairedList, equals('["apple", "banana"]'));
      expect(jsonDecode(repairedList), equals(['apple', 'banana']));

      const truncatedInts = '[1, 2, 3,   ';
      final repairedInts = repairJson(truncatedInts);
      expect(repairedInts, equals('[1, 2, 3]'));
      expect(jsonDecode(repairedInts), equals([1, 2, 3]));
    });

    test('handles nested truncated structures with trailing commas', () {
      const nestedList = '{"items": ["apple", "banana", ';
      final repairedNestedList = repairJson(nestedList);
      expect(repairedNestedList, equals('{"items": ["apple", "banana"]}'));
      expect(
        jsonDecode(repairedNestedList),
        equals({
          'items': ['apple', 'banana'],
        }),
      );

      const nestedObj = '{"data": {"a": 1, "b": 2, ';
      final repairedNestedObj = repairJson(nestedObj);
      expect(repairedNestedObj, equals('{"data": {"a": 1, "b": 2}}'));
      expect(
        jsonDecode(repairedNestedObj),
        equals({
          'data': {'a': 1, 'b': 2},
        }),
      );
    });

    test('handles truncated dangling colons and key truncations in maps', () {
      const danglingColonWithSpace = '{"a": 1, "b": ';
      final repairedColonWithSpace = repairJson(danglingColonWithSpace);
      expect(repairedColonWithSpace, equals('{"a": 1}'));
      expect(jsonDecode(repairedColonWithSpace), equals({'a': 1}));

      const danglingColonNoSpace = '{"a": 1, "b":';
      final repairedColonNoSpace = repairJson(danglingColonNoSpace);
      expect(repairedColonNoSpace, equals('{"a": 1}'));
      expect(jsonDecode(repairedColonNoSpace), equals({'a': 1}));

      const singleKeyDanglingColon = '{"key": ';
      final repairedSingleKeyDangling = repairJson(singleKeyDanglingColon);
      expect(repairedSingleKeyDangling, equals('{}'));
      expect(jsonDecode(repairedSingleKeyDangling), equals(<String, dynamic>{}));

      const singleKeyDanglingNoSpace = '{"key":';
      final repairedSingleKeyNoSpace = repairJson(singleKeyDanglingNoSpace);
      expect(repairedSingleKeyNoSpace, equals('{}'));
      expect(jsonDecode(repairedSingleKeyNoSpace), equals(<String, dynamic>{}));

      const truncatedKeyWithQuotes = '{"a": 1, "b"';
      final repairedKeyWithQuotes = repairJson(truncatedKeyWithQuotes);
      expect(repairedKeyWithQuotes, equals('{"a": 1}'));
      expect(jsonDecode(repairedKeyWithQuotes), equals({'a': 1}));

      const truncatedKeyUnclosed = '{"a": 1, "b';
      final repairedKeyUnclosed = repairJson(truncatedKeyUnclosed);
      expect(repairedKeyUnclosed, equals('{"a": 1}'));
      expect(jsonDecode(repairedKeyUnclosed), equals({'a': 1}));

      const singleKeyUnclosed = '{"key';
      final repairedSingleKeyUnclosed = repairJson(singleKeyUnclosed);
      expect(repairedSingleKeyUnclosed, equals('{}'));
      expect(jsonDecode(repairedSingleKeyUnclosed), equals(<String, dynamic>{}));

      const trailingCommaOnly = '{"a": 1, ';
      final repairedTrailingComma = repairJson(trailingCommaOnly);
      expect(repairedTrailingComma, equals('{"a": 1}'));
      expect(jsonDecode(repairedTrailingComma), equals({'a': 1}));

      const nestedDanglingColon = '{"data": {"a": 1, "b": ';
      final repairedNestedDangling = repairJson(nestedDanglingColon);
      expect(repairedNestedDangling, equals('{"data": {"a": 1}}'));
      expect(
        jsonDecode(repairedNestedDangling),
        equals({
          'data': {'a': 1},
        }),
      );

      const nestedListDanglingColon = '{"items": [{"name": ';
      final repairedNestedListDangling = repairJson(nestedListDanglingColon);
      expect(repairedNestedListDangling, equals('{"items": [{}]}'));
      expect(
        jsonDecode(repairedNestedListDangling),
        equals({
          'items': [
            <String, dynamic>{},
          ],
        }),
      );
    });

    test('preserves valid JSON strings and structures', () {
      expect(repairJson(''), equals(''));
      expect(
        repairJson('{"a": 1, "b": [2, 3]}'),
        equals('{"a": 1, "b": [2, 3]}'),
      );
      expect(repairJson('{"test": "}"}'), equals('{"test": "}"}'));
      expect(
        repairJson('{"test": "hello, world, "}'),
        equals('{"test": "hello, world, "}'),
      );
    });

    test('repairs unclosed strings and nested braces/brackets', () {
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

      final truncatedStructural = '{"msg": "Hello { world';
      final repairedStructural = repairJson(truncatedStructural);
      expect(repairedStructural, equals('{"msg": "Hello { world"}'));
      expect(jsonDecode(repairedStructural), equals({'msg': 'Hello { world'}));

      final truncatedEscape = r'{"path": "C:\\folder\';
      final repairedEscape = repairJson(truncatedEscape);
      expect(repairedEscape, equals(r'{"path": "C:\\folder\\"}'));
      expect(jsonDecode(repairedEscape), equals({'path': r'C:\folder\'}));
    });
  });

  group('Heuristic and Chunk Cleaning Tests', () {
    test('isTruncatedHeuristic detects unclosed JSON and text', () {
      expect(isTruncatedHeuristic('{"open": true', false), isTrue);
      expect(isTruncatedHeuristic('{"closed": true}', false), isFalse);
      expect(isTruncatedHeuristic('[1, 2', false), isTrue);
      expect(isTruncatedHeuristic('[1, 2]', false), isFalse);
      expect(isTruncatedHeuristic('test', true), isTrue);
      expect(isTruncatedHeuristic('', false), isFalse);
    });

    test('cleanContinuationChunk strips fences and headers', () {
      expect(
        cleanContinuationChunk('```json\n{"val": 1}\n```'),
        equals('{"val": 1}'),
      );
      expect(
        cleanContinuationChunk('Here is the continuation:\n{"val": 1}'),
        equals('{"val": 1}'),
      );
    });

    test('stitchContinuation deduplicates overlapping chunks', () {
      expect(
        stitchContinuation('prefix-overlap-12345extra', 'overlap-12345suffix'),
        equals('prefix-overlap-12345suffix'),
      );
      expect(stitchContinuation('abc', 'def'), equals('abcdef'));
    });
  });
}
