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
    });

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
    });
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

    test('handles truncated incomplete literals (booleans, null, numbers)', () {
      // Object context
      final objTru = direct.repairJson('{"a": 1, "b": tru');
      expect(objTru, equals('{"a": 1}'));
      expect(jsonDecode(objTru), equals({'a': 1}));

      final objFal = direct.repairJson('{"a": 1, "b": fal');
      expect(objFal, equals('{"a": 1}'));
      expect(jsonDecode(objFal), equals({'a': 1}));

      final objNul = direct.repairJson('{"a": 1, "b": nul');
      expect(objNul, equals('{"a": 1}'));
      expect(jsonDecode(objNul), equals({'a': 1}));

      final objDot = direct.repairJson('{"a": 1, "b": 12.');
      expect(objDot, equals('{"a": 1}'));
      expect(jsonDecode(objDot), equals({'a': 1}));

      final objMinus = direct.repairJson('{"a": 1, "b": -');
      expect(objMinus, equals('{"a": 1}'));
      expect(jsonDecode(objMinus), equals({'a': 1}));

      final objExp = direct.repairJson('{"a": 1, "b": 1e');
      expect(objExp, equals('{"a": 1}'));
      expect(jsonDecode(objExp), equals({'a': 1}));

      final objSingleKey = direct.repairJson('{"key": tru');
      expect(objSingleKey, equals('{}'));
      expect(jsonDecode(objSingleKey), equals(<String, dynamic>{}));

      // Array context
      final arrTru = direct.repairJson('[1, 2, tru');
      expect(arrTru, equals('[1, 2]'));
      expect(jsonDecode(arrTru), equals([1, 2]));

      final arrFal = direct.repairJson('[1, 2, fal');
      expect(arrFal, equals('[1, 2]'));
      expect(jsonDecode(arrFal), equals([1, 2]));

      final arrNul = direct.repairJson('[1, 2, nul');
      expect(arrNul, equals('[1, 2]'));
      expect(jsonDecode(arrNul), equals([1, 2]));

      final arrDot = direct.repairJson('[1, 2, 12.');
      expect(arrDot, equals('[1, 2]'));
      expect(jsonDecode(arrDot), equals([1, 2]));

      final arrMinus = direct.repairJson('[1, 2, -');
      expect(arrMinus, equals('[1, 2]'));
      expect(jsonDecode(arrMinus), equals([1, 2]));

      final arrExp = direct.repairJson('[1, 2, 1e');
      expect(arrExp, equals('[1, 2]'));
      expect(jsonDecode(arrExp), equals([1, 2]));

      final arrSingleTru = direct.repairJson('[tru');
      expect(arrSingleTru, equals('[]'));
      expect(jsonDecode(arrSingleTru), equals([]));

      // Valid literals remain intact
      final validTrue = direct.repairJson('{"a": 1, "b": true');
      expect(validTrue, equals('{"a": 1, "b": true}'));
      expect(jsonDecode(validTrue), equals({'a': 1, 'b': true}));

      final validFalse = direct.repairJson('{"a": 1, "b": false');
      expect(validFalse, equals('{"a": 1, "b": false}'));
      expect(jsonDecode(validFalse), equals({'a': 1, 'b': false}));

      final validNull = direct.repairJson('{"a": 1, "b": null');
      expect(validNull, equals('{"a": 1, "b": null}'));
      expect(jsonDecode(validNull), equals({'a': 1, 'b': null}));

      final validFloat = direct.repairJson('{"a": 1, "b": 12.34');
      expect(validFloat, equals('{"a": 1, "b": 12.34}'));
      expect(jsonDecode(validFloat), equals({'a': 1, 'b': 12.34}));

      final validNegative = direct.repairJson('{"a": 1, "b": -42');
      expect(validNegative, equals('{"a": 1, "b": -42}'));
      expect(jsonDecode(validNegative), equals({'a': 1, 'b': -42}));

      // Incomplete literals followed by closing delimiter
      final closedObjTru = direct.repairJson('{"a": 1, "b": tru}');
      expect(closedObjTru, equals('{"a": 1}'));
      expect(jsonDecode(closedObjTru), equals({'a': 1}));

      final closedArrTru = direct.repairJson('[1, 2, tru]');
      expect(closedArrTru, equals('[1, 2]'));
      expect(jsonDecode(closedArrTru), equals([1, 2]));

      final closedArrSingleTru = direct.repairJson('[tru]');
      expect(closedArrSingleTru, equals('[]'));
      expect(jsonDecode(closedArrSingleTru), equals([]));
    });
  });

  group('json_repair Batch Slicing & Code Unit Optimization Tests', () {
    test('handles multi-kilobyte string literals with complex escapes', () {
      final largeContent = 'a' * 10000 +
          r'\"escaped_quote\"' +
          r'\\escaped_backslash\\' +
          r'\nmultiline\r\nline\tindented' +
          'b' * 10000;
      final rawJson = '{"content": "$largeContent"}';
      final repaired = direct.repairJson(rawJson);
      expect(repaired, equals(rawJson));
      final decoded = jsonDecode(repaired) as Map<String, dynamic>;
      expect(decoded['content'], contains('escaped_quote'));
      expect(decoded['content'], contains(r'\escaped_backslash\'));
      expect(decoded['content'], contains('multiline\r\nline\tindented'));
    });

    test('preserves raw unescaped newlines and tabs in large string literals',
        () {
      final xChunk = 'x' * 5000;
      final yChunk = 'y' * 5000;
      final rawContent = 'start\n$xChunk\n\tline2\n$yChunk';
      final rawJson = '{"text": "$rawContent"}';
      final repaired = direct.repairJson(rawJson);
      expect(repaired, equals(rawJson));
      expect(repaired.startsWith('{"text": "start\n'), isTrue);
      expect(repaired.endsWith('"}'), isTrue);
    });

    test(
        'repairs unclosed strings with and without dangling escape backslashes',
        () {
      // Unclosed string without trailing escape
      final unclosed = direct.repairJson('{"message": "Hello world');
      expect(unclosed, equals('{"message": "Hello world"}'));
      expect(jsonDecode(unclosed), equals({'message': 'Hello world'}));

      // Unclosed string with dangling single backslash
      final danglingSlash = direct.repairJson(r'{"message": "Hello world\');
      expect(danglingSlash, equals(r'{"message": "Hello world\\"}'));
      expect(jsonDecode(danglingSlash), equals({'message': r'Hello world\'}));

      // Unclosed string with escaped backslash then another dangling backslash
      final tripleSlash = direct.repairJson(r'{"message": "Hello world\\\');
      expect(tripleSlash, equals(r'{"message": "Hello world\\\\"}'));
      expect(jsonDecode(tripleSlash), equals({'message': r'Hello world\\'}));

      // Unclosed string with even backslashes (closed escape)
      final evenSlash = direct.repairJson(r'{"message": "Hello world\\');
      expect(evenSlash, equals(r'{"message": "Hello world\\"}'));
      expect(jsonDecode(evenSlash), equals({'message': r'Hello world\'}));

      // Unclosed string with escaped quote
      final escapedQuote = direct.repairJson(r'{"message": "He said \"hello');
      expect(escapedQuote, equals(r'{"message": "He said \"hello"}'));
      expect(jsonDecode(escapedQuote), equals({'message': 'He said "hello'}));
    });

    test(
        'repairs unclosed strings with truncated unicode escape sequences',
        () {
      // Truncation with \u (0 hex digits)
      final u0 = direct.repairJson(r'{"a": "caf\u');
      expect(u0, equals(r'{"a": "caf"}'));
      expect(jsonDecode(u0), equals({'a': 'caf'}));

      // Truncation with \u0 (1 hex digit)
      final u1 = direct.repairJson(r'{"a": "caf\u0');
      expect(u1, equals(r'{"a": "caf"}'));
      expect(jsonDecode(u1), equals({'a': 'caf'}));

      // Truncation with \u00 (2 hex digits)
      final u2 = direct.repairJson(r'{"a": "caf\u00');
      expect(u2, equals(r'{"a": "caf"}'));
      expect(jsonDecode(u2), equals({'a': 'caf'}));

      // Truncation with \u00a (3 hex digits)
      final u3 = direct.repairJson(r'{"a": "caf\u00a');
      expect(u3, equals(r'{"a": "caf"}'));
      expect(jsonDecode(u3), equals({'a': 'caf'}));

      // Truncation with uppercase hex digits
      final uUpper = direct.repairJson(r'{"a": "caf\u00A');
      expect(uUpper, equals(r'{"a": "caf"}'));
      expect(jsonDecode(uUpper), equals({'a': 'caf'}));

      // Complete 4-hex escape preserved
      final completeEscape = direct.repairJson(r'{"a": "caf\u0061');
      expect(completeEscape, equals(r'{"a": "caf\u0061"}'));
      expect(jsonDecode(completeEscape), equals({'a': 'cafa'}));

      // Escaped backslash before u00 (even backslashes) is not stripped
      final escapedBackslash = direct.repairJson(r'{"a": "caf\\u00');
      expect(escapedBackslash, equals(r'{"a": "caf\\u00"}'));
      expect(jsonDecode(escapedBackslash), equals({'a': r'caf\u00'}));

      // Odd backslash sequence precedes incomplete unicode escape
      final oddBackslash = direct.repairJson(r'{"a": "caf\\\u00');
      expect(oddBackslash, equals(r'{"a": "caf\\"}'));
      expect(jsonDecode(oddBackslash), equals({'a': r'caf\'}));

      // String boundary: entire value is incomplete unicode escape
      final emptyRemainder = direct.repairJson(r'{"a": "\u00');
      expect(emptyRemainder, equals('{"a": ""}'));
      expect(jsonDecode(emptyRemainder), equals({'a': ''}));

      // Array elements with truncated unicode escape
      final arrayElement = direct.repairJson(r'["caf\u00');
      expect(arrayElement, equals('["caf"]'));
      expect(jsonDecode(arrayElement), equals(['caf']));

      // Root string with truncated unicode escape
      final rootString = direct.repairJson(r'"caf\u00');
      expect(rootString, equals('"caf"'));
      expect(jsonDecode(rootString), equals('caf'));

      // Incomplete object key with truncated unicode escape is rolled back
      final incompleteKey = direct.repairJson(r'{"incomp\u00');
      expect(incompleteKey, equals('{}'));
      expect(jsonDecode(incompleteKey), equals(<String, dynamic>{}));
    });

    test('batches contiguous whitespace runs across objects and arrays', () {
      const whitespaceHeavy =
          '  \t \r\n  {\r\n\t  "key"  \t :  \r\n  [  \n\t  1  ,  \t\r\n  2  \t  ]  \r\n  }  \t\r\n  ';
      final repaired = direct.repairJson(whitespaceHeavy);
      expect(repaired, equals(whitespaceHeavy));
      expect(
        jsonDecode(repaired),
        equals({
          'key': [1, 2],
        }),
      );

      // Truncated with trailing whitespace
      const truncatedWithWs = '  \t  {"items":   [  1,   2,   \t\r\n  ';
      final repairedTruncated = direct.repairJson(truncatedWithWs);
      expect(repairedTruncated, equals('  \t  {"items":   [  1,   2]}'));
      expect(
        jsonDecode(repairedTruncated),
        equals({
          'items': [1, 2],
        }),
      );
    });

    test(
        'correctly parses primitive tokens flanked by delimiters and whitespace',
        () {
      const complexPrimitives =
          '{"int": 42, "neg": -100, "float": 3.14159, "exp1": 1e-5, "exp2": 2.5E+3, "bool_t": true, "bool_f": false, "empty": null}';
      final repaired = direct.repairJson(complexPrimitives);
      expect(repaired, equals(complexPrimitives));
      expect(
        jsonDecode(repaired),
        equals({
          'int': 42,
          'neg': -100,
          'float': 3.14159,
          'exp1': 1e-5,
          'exp2': 2500.0,
          'bool_t': true,
          'bool_f': false,
          'empty': null,
        }),
      );

      // Primitive tokens in array without spaces
      const arrayPrimitives = '[42,-100,3.14,1e5,true,false,null]';
      final repairedArray = direct.repairJson(arrayPrimitives);
      expect(repairedArray, equals(arrayPrimitives));
      expect(
        jsonDecode(repairedArray),
        equals([42, -100, 3.14, 100000.0, true, false, null]),
      );
    });

    test(
        'truncates invalid or incomplete primitive literals rolling back to last complete entry',
        () {
      // Incomplete scientific notation
      final incompExp = direct.repairJson('{"val": 1.2e+');
      expect(incompExp, equals('{}'));

      // Incomplete negative sign
      final incompNeg = direct.repairJson('{"list": [10, -');
      expect(incompNeg, equals('{"list": [10]}'));
      expect(
          jsonDecode(incompNeg),
          equals({
            'list': [10]
          }));

      // Malformed boolean with closing delimiter
      final incompBoolClosed = direct.repairJson('{"a": 1, "flag": fal}');
      expect(incompBoolClosed, equals('{"a": 1}'));
      expect(jsonDecode(incompBoolClosed), equals({'a': 1}));

      // Malformed boolean at EOF
      final incompBoolEof = direct.repairJson('{"a": 1, "flag": fal');
      expect(incompBoolEof, equals('{"a": 1}'));
      expect(jsonDecode(incompBoolEof), equals({'a': 1}));

      // Root level truncated literal
      final rootTrunc = direct.repairJson('tru');
      expect(rootTrunc, equals(''));
    });

    test('handles many rollbacks after a large valid prefix', () {
      // A large valid prefix is built first so each rollback has to discard
      // output while a large amount of valid output remains in the buffer.
      final big = 'x' * 100000;
      final sb = StringBuffer('{"big": "$big"');
      for (var i = 0; i < 1000; i++) {
        sb.write(', "e$i": $i');
      }
      final prefix = sb.toString();
      for (var i = 0; i < 20000; i++) {
        sb.write(', "k$i": bad');
      }
      final repaired = direct.repairJson(sb.toString());
      expect(jsonDecode(repaired), isA<Map<String, dynamic>>());
      final decoded = jsonDecode(repaired) as Map<String, dynamic>;
      expect(decoded['big'], equals(big));
      expect(decoded.length, equals(1001));
      expect(repaired.length, lessThanOrEqualTo(prefix.length + 1));
    });
  });

  group('ChunkedBuffer', () {
    direct.ChunkedBuffer build() => direct.ChunkedBuffer()
      ..write('a' * 100)
      ..write('b' * 100)
      ..write('c' * 100);

    test('truncates at an exact chunk boundary', () {
      final b = build()..truncateTo(200);
      expect(b.length, equals(200));
      expect(b.toString(), equals('${'a' * 100}${'b' * 100}'));
    });

    test('truncates mid-chunk', () {
      final b = build()..truncateTo(150);
      expect(b.length, equals(150));
      expect(b.toString(), equals('${'a' * 100}${'b' * 50}'));
    });

    test('truncates to zero', () {
      final b = build()..truncateTo(0);
      expect(b.length, equals(0));
      expect(b.toString(), equals(''));
    });

    test('throws RangeError when targetLen is negative', () {
      final b = build();
      expect(() => b.truncateTo(-1), throwsA(isA<RangeError>()));
      final empty = direct.ChunkedBuffer();
      expect(() => empty.truncateTo(-1), throwsA(isA<RangeError>()));
    });

    test('reports isEmpty, isNotEmpty, and clear() works correctly', () {
      final b = direct.ChunkedBuffer();
      expect(b.isEmpty, isTrue);
      expect(b.isNotEmpty, isFalse);

      b.write('hello');
      expect(b.isEmpty, isFalse);
      expect(b.isNotEmpty, isTrue);

      b.clear();
      expect(b.length, equals(0));
      expect(b.isEmpty, isTrue);
      expect(b.isNotEmpty, isFalse);
      expect(b.toString(), equals(''));
    });

    test('is a no-op when length is at or below the target', () {
      final b = build();
      b.truncateTo(300);
      expect(b.length, equals(300));
      b.truncateTo(1000);
      expect(b.length, equals(300));
      expect(b.toString(), equals('${'a' * 100}${'b' * 100}${'c' * 100}'));
    });

    test('supports writes after truncation and coalesces small writes', () {
      final b = direct.ChunkedBuffer()
        ..write('{')
        ..write('"k"')
        ..write(':')
        ..write('1');
      expect(b.toString(), equals('{"k":1'));
      b.truncateTo(4);
      b.write('2');
      expect(b.length, equals(5));
      expect(b.toString(), equals('{"k"2'));
    });
  });
}
