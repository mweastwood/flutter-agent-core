import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_agent_core/flutter_agent_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelAiService request timeout', () {
    const channel = MethodChannel('com.mweastwood.local_agent');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('stalled platform call times out, retries, and returns an error', () async {
      int attempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) {
        attempts++;
        return Completer<dynamic>().future; // never completes
      });

      final service = MethodChannelAiService(
        maxRetries: 1,
        initialRetryDelay: Duration.zero,
        maxRetryDelay: Duration.zero,
        enableJitter: false,
        requestTimeout: const Duration(milliseconds: 50),
      );

      final response = await service
          .generateContentRaw(prompt: 'test prompt')
          .timeout(const Duration(seconds: 5));

      expect(attempts, equals(2));
      expect(response, isNotNull);
      expect(response!.isError, isTrue);
      expect(response.text, contains('TimeoutException'));
    });

    test('fast platform call completes successfully within requestTimeout', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return 'Hello from model';
      });

      final service = MethodChannelAiService(
        requestTimeout: const Duration(seconds: 5),
      );

      final response = await service.generateContentRaw(prompt: 'test prompt');

      expect(response, isNotNull);
      expect(response!.isError, isFalse);
      expect(response.text, equals('Hello from model'));
    });
  });
}
