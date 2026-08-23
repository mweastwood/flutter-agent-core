import 'package:flutter_agent_core/flutter_agent_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('stripMarkdownCodeFences Tests', () {
    test('strips standard multi-line markdown fences with json tag', () {
      const input = '```json\n{"name": "test", "count": 42}\n```';
      expect(
        stripMarkdownCodeFences(input),
        equals('{"name": "test", "count": 42}'),
      );
    });

    test('strips multi-line markdown fences with uppercase JSON tag', () {
      const input = '```JSON\n[1, 2, 3]\n```';
      expect(stripMarkdownCodeFences(input), equals('[1, 2, 3]'));
    });

    test('strips multi-line markdown fences with other language tags', () {
      const input = '```dart\n{"status": "ok"}\n```';
      expect(stripMarkdownCodeFences(input), equals('{"status": "ok"}'));
    });

    test('strips multi-line markdown fences with no language tag', () {
      const input = '```\n{"result": true}\n```';
      expect(stripMarkdownCodeFences(input), equals('{"result": true}'));
    });

    test('strips single-line markdown fences with language tag', () {
      const input = '```json {"action": "click", "id": 1}```';
      expect(
        stripMarkdownCodeFences(input),
        equals('{"action": "click", "id": 1}'),
      );
    });

    test('strips single-line markdown fences without language tag', () {
      const input = '```{"action": "done"}```';
      expect(stripMarkdownCodeFences(input), equals('{"action": "done"}'));
    });

    test('strips single-line markdown fences with list payload', () {
      const input = '```json ["a", "b", "c"]```';
      expect(stripMarkdownCodeFences(input), equals('["a", "b", "c"]'));
    });

    test(
      'handles leading and trailing whitespace and newlines around fences',
      () {
        const input = '  \n\n```json\n{"nested": {"val": 123}}\n```\n\n  ';
        expect(
          stripMarkdownCodeFences(input),
          equals('{"nested": {"val": 123}}'),
        );
      },
    );

    test('preserves unfenced raw JSON unchanged', () {
      const mapJson = '{"key": "value"}';
      expect(stripMarkdownCodeFences(mapJson), equals('{"key": "value"}'));

      const listJson = '[1, 2, 3]';
      expect(stripMarkdownCodeFences(listJson), equals('[1, 2, 3]'));
    });

    test('handles unclosed opening code fences gracefully', () {
      const multiLineUnclosed = '```json\n{"partial": true}';
      expect(
        stripMarkdownCodeFences(multiLineUnclosed),
        equals('{"partial": true}'),
      );

      const singleLineUnclosed = '```json {"partial": true}';
      expect(
        stripMarkdownCodeFences(singleLineUnclosed),
        equals('{"partial": true}'),
      );
    });

    test(
      'handles trailing closing code fences without opening fence gracefully',
      () {
        const multiLineTrailing = '{"partial": true}\n```';
        expect(
          stripMarkdownCodeFences(multiLineTrailing),
          equals('{"partial": true}'),
        );

        const singleLineTrailing = '{"partial": true}```';
        expect(
          stripMarkdownCodeFences(singleLineTrailing),
          equals('{"partial": true}'),
        );
      },
    );

    test('handles empty and whitespace-only strings', () {
      expect(stripMarkdownCodeFences(''), equals(''));
      expect(stripMarkdownCodeFences('   \n  \t '), equals(''));
    });
  });

  group('parseJsonWithFenceFallback Tests', () {
    test('parses fenced JSON map', () {
      const input = '```json\n{"hello": "world", "num": 10}\n```';
      final result = parseJsonWithFenceFallback(input);
      expect(result, isA<Map<String, dynamic>>());
      expect(result['hello'], equals('world'));
      expect(result['num'], equals(10));
    });

    test('parses fenced JSON list', () {
      const input = '```json\n["apple", "banana", "cherry"]\n```';
      final result = parseJsonWithFenceFallback(input);
      expect(result, isA<List<dynamic>>());
      expect(result, equals(['apple', 'banana', 'cherry']));
    });

    test('parses single-line fenced JSON', () {
      const input = '```json {"success": true}```';
      final result = parseJsonWithFenceFallback(input);
      expect(result, equals({'success': true}));
    });

    test('parses unfenced raw JSON', () {
      const input = '{"status": 200}';
      final result = parseJsonWithFenceFallback(input);
      expect(result, equals({'status': 200}));
    });

    test('returns null for invalid JSON syntax', () {
      expect(parseJsonWithFenceFallback('```json\n{invalid json\n```'), isNull);
      expect(parseJsonWithFenceFallback('not a json'), isNull);
    });

    test('returns null for empty string', () {
      expect(parseJsonWithFenceFallback(''), isNull);
      expect(parseJsonWithFenceFallback('   '), isNull);
    });
  });

  group('tryParseJsonMap Tests', () {
    test('returns Map<String, dynamic> for valid fenced JSON map', () {
      const input = '```json\n{"key": "value"}\n```';
      final map = tryParseJsonMap(input);
      expect(map, isNotNull);
      expect(map, isA<Map<String, dynamic>>());
      expect(map!['key'], equals('value'));
    });

    test('returns null for valid JSON list (not a Map)', () {
      const input = '```json\n[1, 2, 3]\n```';
      expect(tryParseJsonMap(input), isNull);
    });

    test('returns Map<String, dynamic> for raw JSON map', () {
      const input = '{"action": "test"}';
      final map = tryParseJsonMap(input);
      expect(map, equals({'action': 'test'}));
    });

    test('returns null for invalid JSON or empty input', () {
      expect(tryParseJsonMap('{bad: json}'), isNull);
      expect(tryParseJsonMap(''), isNull);
    });
  });
}
