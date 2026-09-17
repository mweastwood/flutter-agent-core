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
}
