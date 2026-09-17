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
      expect(
        jsonDecode(repairedSingleKeyDangling),
        equals(<String, dynamic>{}),
      );

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
      expect(
        jsonDecode(repairedSingleKeyUnclosed),
        equals(<String, dynamic>{}),
      );

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
          'items': [<String, dynamic>{}],
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

    test('repairs large JSON payloads efficiently and correctly', () {
      final largeArrayItems = List.generate(
        1000,
        (i) => '{"index": $i, "name": "item_$i"}',
      ).join(', ');
      final truncatedLargeJson =
          '{"total": 1000, "items": [$largeArrayItems, {"index": 1000, "name": ';
      final repairedLargeJson = repairJson(truncatedLargeJson);
      final decoded = jsonDecode(repairedLargeJson) as Map<String, dynamic>;
      expect(decoded['total'], equals(1000));
      expect((decoded['items'] as List).length, equals(1001));
      expect((decoded['items'] as List).last, equals({'index': 1000}));
    });

    test('handles rollback across multiple nested structures', () {
      const nestedTruncated =
          '{"outer": {"list": [{"a": 1, "b": 2}, {"a": 3, "unfin';
      final repaired = repairJson(nestedTruncated);
      expect(
        repaired,
        equals('{"outer": {"list": [{"a": 1, "b": 2}, {"a": 3}]}}'),
      );
      expect(
        jsonDecode(repaired),
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

    test('handles unmatched closing brace in array context', () {
      // Enclosed array context: inner array auto-closes and outer object consumes '}'
      final enclosed1 = repairJson('{"items": [1, 2, }');
      expect(enclosed1, equals('{"items": [1, 2]}'));
      expect(
        jsonDecode(enclosed1),
        equals({
          'items': [1, 2],
        }),
      );

      final enclosed2 = repairJson('{"list": [{"key": "value"}, 10, }');
      expect(enclosed2, equals('{"list": [{"key": "value"}, 10]}'));
      expect(
        jsonDecode(enclosed2),
        equals({
          'list': [
            {'key': 'value'},
            10,
          ],
        }),
      );

      // Standalone array context: inner array auto-closes and stray '}' is emitted
      final standalone1 = repairJson('[1, 2, }');
      expect(standalone1, equals('[1, 2]}'));

      final standalone2 = repairJson('[{"key": "value"}, 10, }');
      expect(standalone2, equals('[{"key": "value"}, 10]}'));
    });

    test('handles unmatched closing bracket in object context', () {
      // Enclosed object context: incomplete key rolled back, inner object auto-closes, and outer array consumes ']'
      final enclosed1 = repairJson('[{"a": 1, "b": ]');
      expect(enclosed1, equals('[{"a": 1}]'));
      expect(
        jsonDecode(enclosed1),
        equals([
          {'a': 1},
        ]),
      );

      final enclosed2 = repairJson('[{"a": 1, "b": 2, ]');
      expect(enclosed2, equals('[{"a": 1, "b": 2}]'));
      expect(
        jsonDecode(enclosed2),
        equals([
          {'a': 1, 'b': 2},
        ]),
      );

      // Standalone object context: incomplete key rolled back, object auto-closes, and stray ']' is emitted
      final standalone = repairJson('{"a": 1, "b": ]');
      expect(standalone, equals('{"a": 1}]'));
    });

    test(
      'handles explicit array closing directly following trailing comma',
      () {
        final array1 = repairJson('[1, 2, ]');
        expect(array1, equals('[1, 2]'));
        expect(jsonDecode(array1), equals([1, 2]));

        final array2 = repairJson('["alpha", "beta",  ]');
        expect(array2, equals('["alpha", "beta"]'));
        expect(jsonDecode(array2), equals(['alpha', 'beta']));

        final array3 = repairJson('[{"id": 1}, ]');
        expect(array3, equals('[{"id": 1}]'));
        expect(
          jsonDecode(array3),
          equals([
            {'id': 1},
          ]),
        );
      },
    );

    test(
      'handles explicit object closing directly following trailing comma or incomplete entries',
      () {
        final obj1 = repairJson('{"a": 1, }');
        expect(obj1, equals('{"a": 1}'));
        expect(jsonDecode(obj1), equals({'a': 1}));

        final obj2 = repairJson('{"a": 1, "b": 2, }');
        expect(obj2, equals('{"a": 1, "b": 2}'));
        expect(jsonDecode(obj2), equals({'a': 1, 'b': 2}));

        final obj3 = repairJson('{"a": 1, "b": }');
        expect(obj3, equals('{"a": 1}'));
        expect(jsonDecode(obj3), equals({'a': 1}));

        final obj4 = repairJson('{"a": 1, "b"}');
        expect(obj4, equals('{"a": 1}'));
        expect(jsonDecode(obj4), equals({'a': 1}));

        final obj5 = repairJson('{"a": }');
        expect(obj5, equals('{}'));
        expect(jsonDecode(obj5), equals(<String, dynamic>{}));

        final obj6 = repairJson('{"a"}');
        expect(obj6, equals('{}'));
        expect(jsonDecode(obj6), equals(<String, dynamic>{}));

        final obj7 = repairJson('{, }');
        expect(obj7, equals('{}'));
        expect(jsonDecode(obj7), equals(<String, dynamic>{}));

        final nested1 = repairJson('{"outer": {"a": 1, }}');
        expect(nested1, equals('{"outer": {"a": 1}}'));
        expect(
          jsonDecode(nested1),
          equals({
            'outer': {'a': 1},
          }),
        );

        final nested2 = repairJson('{"outer": {"a": 1, }, "b": 2}');
        expect(nested2, equals('{"outer": {"a": 1}, "b": 2}'));
        expect(
          jsonDecode(nested2),
          equals({
            'outer': {'a': 1},
            'b': 2,
          }),
        );

        final nested3 = repairJson('[{"a": 1, }]');
        expect(nested3, equals('[{"a": 1}]'));
        expect(
          jsonDecode(nested3),
          equals([
            {'a': 1},
          ]),
        );

        final nested4 = repairJson('{"data": {"nested": {"a": 1, "b": }}}');
        expect(nested4, equals('{"data": {"nested": {"a": 1}}}'));
        expect(
          jsonDecode(nested4),
          equals({
            'data': {
              'nested': {'a': 1},
            },
          }),
        );
      },
    );

    test('handles stray closing delimiters with empty container stack', () {
      expect(repairJson('}'), equals('}'));
      expect(repairJson(']'), equals(']'));
      expect(repairJson('}  '), equals('}  '));
      expect(repairJson(']  '), equals(']  '));
    });

    test('handles truncated incomplete literals (booleans, null, numbers)', () {
      // Object context
      final objTru = repairJson('{"a": 1, "b": tru');
      expect(objTru, equals('{"a": 1}'));
      expect(jsonDecode(objTru), equals({'a': 1}));

      final objFal = repairJson('{"a": 1, "b": fal');
      expect(objFal, equals('{"a": 1}'));
      expect(jsonDecode(objFal), equals({'a': 1}));

      final objNul = repairJson('{"a": 1, "b": nul');
      expect(objNul, equals('{"a": 1}'));
      expect(jsonDecode(objNul), equals({'a': 1}));

      final objDot = repairJson('{"a": 1, "b": 12.');
      expect(objDot, equals('{"a": 1}'));
      expect(jsonDecode(objDot), equals({'a': 1}));

      final objMinus = repairJson('{"a": 1, "b": -');
      expect(objMinus, equals('{"a": 1}'));
      expect(jsonDecode(objMinus), equals({'a': 1}));

      final objExp = repairJson('{"a": 1, "b": 1e');
      expect(objExp, equals('{"a": 1}'));
      expect(jsonDecode(objExp), equals({'a': 1}));

      final objSingleKey = repairJson('{"key": tru');
      expect(objSingleKey, equals('{}'));
      expect(jsonDecode(objSingleKey), equals(<String, dynamic>{}));

      // Array context
      final arrTru = repairJson('[1, 2, tru');
      expect(arrTru, equals('[1, 2]'));
      expect(jsonDecode(arrTru), equals([1, 2]));

      final arrFal = repairJson('[1, 2, fal');
      expect(arrFal, equals('[1, 2]'));
      expect(jsonDecode(arrFal), equals([1, 2]));

      final arrNul = repairJson('[1, 2, nul');
      expect(arrNul, equals('[1, 2]'));
      expect(jsonDecode(arrNul), equals([1, 2]));

      final arrDot = repairJson('[1, 2, 12.');
      expect(arrDot, equals('[1, 2]'));
      expect(jsonDecode(arrDot), equals([1, 2]));

      final arrMinus = repairJson('[1, 2, -');
      expect(arrMinus, equals('[1, 2]'));
      expect(jsonDecode(arrMinus), equals([1, 2]));

      final arrExp = repairJson('[1, 2, 1e');
      expect(arrExp, equals('[1, 2]'));
      expect(jsonDecode(arrExp), equals([1, 2]));

      final arrSingleTru = repairJson('[tru');
      expect(arrSingleTru, equals('[]'));
      expect(jsonDecode(arrSingleTru), equals([]));

      // Valid literals remain intact
      final validTrue = repairJson('{"a": 1, "b": true');
      expect(validTrue, equals('{"a": 1, "b": true}'));
      expect(jsonDecode(validTrue), equals({'a': 1, 'b': true}));

      final validFalse = repairJson('{"a": 1, "b": false');
      expect(validFalse, equals('{"a": 1, "b": false}'));
      expect(jsonDecode(validFalse), equals({'a': 1, 'b': false}));

      final validNull = repairJson('{"a": 1, "b": null');
      expect(validNull, equals('{"a": 1, "b": null}'));
      expect(jsonDecode(validNull), equals({'a': 1, 'b': null}));

      final validFloat = repairJson('{"a": 1, "b": 12.34');
      expect(validFloat, equals('{"a": 1, "b": 12.34}'));
      expect(jsonDecode(validFloat), equals({'a': 1, 'b': 12.34}));

      final validNegative = repairJson('{"a": 1, "b": -42');
      expect(validNegative, equals('{"a": 1, "b": -42}'));
      expect(jsonDecode(validNegative), equals({'a': 1, 'b': -42}));

      // Incomplete literals followed by closing delimiter
      final closedObjTru = repairJson('{"a": 1, "b": tru}');
      expect(closedObjTru, equals('{"a": 1}'));
      expect(jsonDecode(closedObjTru), equals({'a': 1}));

      final closedArrTru = repairJson('[1, 2, tru]');
      expect(closedArrTru, equals('[1, 2]'));
      expect(jsonDecode(closedArrTru), equals([1, 2]));

      final closedArrSingleTru = repairJson('[tru]');
      expect(closedArrSingleTru, equals('[]'));
      expect(jsonDecode(closedArrSingleTru), equals([]));
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
      expect(
        isTruncatedHeuristic(r'{"code": "print(```x```)"}', false),
        isFalse,
      );
      expect(isTruncatedHeuristic('```dart\nvoid main() {', false), isTrue);
      expect(
        isTruncatedHeuristic('```dart\nvoid main() {}\n```', false),
        isFalse,
      );
    });

    test(
      'isTruncatedHeuristic detects mismatched root JSON structural delimiters',
      () {
        // Mismatched delimiters (truncated)
        expect(isTruncatedHeuristic('[{"a": 1}', false), isTrue);
        expect(isTruncatedHeuristic('{"items": [1, 2]', false), isTrue);
        expect(isTruncatedHeuristic('[{"a": 1}, {"b": 2}', false), isTrue);
        expect(
          isTruncatedHeuristic('{"data": {"nested": [1, 2]', false),
          isTrue,
        );
        expect(isTruncatedHeuristic('  [{"a": 1}  ', false), isTrue);
        expect(isTruncatedHeuristic('  {"items": [1, 2]  ', false), isTrue);

        // Matching delimiters (non-truncated / closed root)
        expect(isTruncatedHeuristic('[{"a": 1}]', false), isFalse);
        expect(isTruncatedHeuristic('{"items": [1, 2]}', false), isFalse);
        expect(isTruncatedHeuristic('[]', false), isFalse);
        expect(isTruncatedHeuristic('{}', false), isFalse);

        // Single unmatched characters
        expect(isTruncatedHeuristic('[', false), isTrue);
        expect(isTruncatedHeuristic('{', false), isTrue);
      },
    );

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

    test('stitchContinuation handles short strings and empty inputs', () {
      expect(stitchContinuation('', ''), equals(''));
      expect(stitchContinuation('a', 'b'), equals('ab'));
      expect(stitchContinuation('ab', 'cd'), equals('abcd'));
      expect(stitchContinuation('', 'hello'), equals('hello'));
      expect(stitchContinuation('hello', ''), equals('hello'));
      expect(stitchContinuation('ab', 'abc'), equals('ababc'));
    });

    test('stitchContinuation requires minimum overlap of 3 characters', () {
      expect(
        stitchContinuation('hello ab', 'ab world'),
        equals('hello abab world'),
      );
      expect(
        stitchContinuation('hello abc', 'abc world'),
        equals('hello abc world'),
      );
    });

    test('stitchContinuation handles long strings and large overlaps', () {
      final longPrefix = 'A' * 600;
      final overlap = 'B' * 500;
      final longSuffix = 'C' * 600;
      final text = longPrefix + overlap;
      final nextText = overlap + longSuffix;

      final stitched = stitchContinuation(text, nextText);
      expect(stitched, equals(longPrefix + overlap + longSuffix));
    });

    test(
      'stitchContinuation handles repetitive patterns and KMP fallbacks',
      () {
        expect(
          stitchContinuation('abcabcabc', 'abcabcf'),
          equals('abcabcabcf'),
        );
        expect(
          stitchContinuation('aaaaaaa', 'aaaa-end'),
          equals('aaaaaaa-end'),
        );
      },
    );
  });
}
