import 'dart:async';

import 'package:flutter_agent_core/flutter_agent_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('CloudAiService request timeout', () {
    test('stalled POST times out, retries, and returns an error', () async {
      var calls = 0;
      final client = MockClient((request) {
        calls++;
        return Completer<http.Response>().future; // never completes
      });
      final service = CloudAiService(
        baseUrl: 'https://example.com/v1',
        apiKey: 'key',
        modelName: 'model',
        maxRetries: 1,
        initialRetryDelay: Duration.zero,
        maxRetryDelay: Duration.zero,
        enableJitter: false,
        requestTimeout: const Duration(milliseconds: 50),
        httpClient: client,
      );

      final response = await service
          .generateContentRaw(prompt: 'hi')
          .timeout(const Duration(seconds: 5));

      expect(calls, 2);
      expect(response.error, isA<TimeoutException>());
    });
  });
}
