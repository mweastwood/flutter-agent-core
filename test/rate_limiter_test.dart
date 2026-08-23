import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_core/flutter_agent_core.dart';

void main() {
  group('RateLimiter Tests', () {
    test('RateLimiter enforces Request-Per-Second (RPS) limits', () async {
      final mockInfo = CloudModelInfo(
        modelName: 'test-rps-model',
        provider: CloudProvider.gemini,
        limitRps: 10, // 10 RPS -> 100ms interval
        description: 'Test limit',
      );

      final limiter = RateLimiter(
        modelInfo: mockInfo,
        throttlePercentage: 100.0,
      );

      final stopwatch = Stopwatch()..start();
      await limiter.throttleBeforeRequest(10);
      await limiter.throttleBeforeRequest(10);
      stopwatch.stop();

      // The second request should be throttled/delayed to enforce the 100ms interval
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(90));
    });

    test('RateLimiter honors throttlePercentage setting', () async {
      final mockInfo = CloudModelInfo(
        modelName: 'test-rps-model-pct',
        provider: CloudProvider.gemini,
        limitRps: 10, // 10 RPS -> normally 100ms interval
        description: 'Test limit',
      );

      // Throttle to 50% -> effective limit is 5 RPS -> 200ms interval
      final limiter = RateLimiter(
        modelInfo: mockInfo,
        throttlePercentage: 50.0,
      );

      final stopwatch = Stopwatch()..start();
      await limiter.throttleBeforeRequest(10);
      await limiter.throttleBeforeRequest(10);
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(190));
    });

    test('RateLimiter handles Requests-Per-Minute (RPM) throttling', () async {
      final mockInfo = CloudModelInfo(
        modelName: 'test-rpm-model',
        provider: CloudProvider.gemini,
        limitRpm:
            120, // 120 RPM -> 2 requests per second (500ms interval equivalent)
        description: 'Test limit',
      );

      final limiter = RateLimiter(
        modelInfo: mockInfo,
        throttlePercentage: 100.0,
      );

      final stopwatch = Stopwatch()..start();
      await limiter.throttleBeforeRequest(10);
      await limiter.throttleBeforeRequest(10);
      stopwatch.stop();

      // Enforces wait so requests fit within the minute rate limit
      // With 120 RPM, the rate check passes immediately unless we exceed the 1-minute bucket.
      // But we can verify it doesn't crash and returns promptly
      expect(stopwatch.elapsedMilliseconds, lessThan(100));
    });

    test(
      'RateLimiter prunes request timestamps and token usage older than 1 minute',
      () async {
        final mockInfo = CloudModelInfo(
          modelName: 'test-prune-model',
          provider: CloudProvider.gemini,
          description: 'Test limit',
        );

        final limiter = RateLimiter(
          modelInfo: mockInfo,
          throttlePercentage: 100.0,
        );

        final oldTimestamp = DateTime.now().subtract(
          const Duration(minutes: 2),
        );
        final recentTimestamp = DateTime.now().subtract(
          const Duration(seconds: 10),
        );

        limiter.recordRequestForTesting(oldTimestamp, tokenCount: 150);
        limiter.recordRequestForTesting(recentTimestamp, tokenCount: 75);

        expect(limiter.requestTimestamps.length, equals(2));
        expect(limiter.tokenUsage.length, equals(2));

        await limiter.throttleBeforeRequest(20);

        // Old timestamp should be pruned; recent timestamp and current request remain
        expect(limiter.requestTimestamps.length, equals(2));
        expect(limiter.requestTimestamps.contains(oldTimestamp), isFalse);
        expect(limiter.requestTimestamps.contains(recentTimestamp), isTrue);

        expect(limiter.tokenUsage.length, equals(2));
        expect(
          limiter.tokenUsage.any((item) => item.timestamp == oldTimestamp),
          isFalse,
        );
        expect(
          limiter.tokenUsage.any((item) => item.timestamp == recentTimestamp),
          isTrue,
        );
      },
    );

    test('RateLimiter handles Tokens-Per-Minute (TPM) throttling', () async {
      final mockInfo = CloudModelInfo(
        modelName: 'test-tpm-model',
        provider: CloudProvider.gemini,
        limitTpm: 100000,
        description: 'Test limit',
      );

      final limiter = RateLimiter(
        modelInfo: mockInfo,
        throttlePercentage: 100.0,
      );

      final stopwatch = Stopwatch()..start();
      await limiter.throttleBeforeRequest(500);
      await limiter.throttleBeforeRequest(500);
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(100));
      expect(limiter.tokenUsage.length, equals(2));
    });

    test(
      'RateLimiter disables throttling on throttlePercentage = 0.0 without errors',
      () async {
        final mockInfo = CloudModelInfo(
          modelName: 'test-zero-throttle-model',
          provider: CloudProvider.gemini,
          limitRps: 10,
          limitRpm: 120,
          limitTpm: 100,
          description: 'Test zero throttle',
        );

        final limiter = RateLimiter(
          modelInfo: mockInfo,
          throttlePercentage: 0.0,
        );

        final stopwatch = Stopwatch()..start();
        await limiter.throttleBeforeRequest(10);
        await limiter.throttleBeforeRequest(50);
        await limiter.throttleBeforeRequest(200);
        stopwatch.stop();

        expect(stopwatch.elapsedMilliseconds, lessThan(50));
      },
    );

    test('RateLimiter handles negative throttlePercentage safely', () async {
      final mockInfo = CloudModelInfo(
        modelName: 'test-negative-throttle-model',
        provider: CloudProvider.gemini,
        limitRps: 10,
        limitRpm: 120,
        limitTpm: 100,
        description: 'Test negative throttle',
      );

      final limiter = RateLimiter(
        modelInfo: mockInfo,
        throttlePercentage: -10.0,
      );

      final stopwatch = Stopwatch()..start();
      await limiter.throttleBeforeRequest(10);
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(50));
    });

    test(
      'RateLimiter handles estimatedTokens exceeding TPM limit without infinite loop or crash',
      () async {
        final mockInfo = CloudModelInfo(
          modelName: 'test-large-tokens-model',
          provider: CloudProvider.gemini,
          limitTpm: 50,
          description: 'Test large tokens',
        );

        final limiter = RateLimiter(
          modelInfo: mockInfo,
          throttlePercentage: 100.0,
        );

        // Request estimated tokens (100) > effectiveTpm (50) on empty limiter
        final stopwatch = Stopwatch()..start();
        await limiter.throttleBeforeRequest(100);
        stopwatch.stop();

        expect(stopwatch.elapsedMilliseconds, lessThan(50));
      },
    );

    test(
      'RateLimiter handles expired TPM windows with large estimated tokens without StateError',
      () async {
        final mockInfo = CloudModelInfo(
          modelName: 'test-expired-tpm-model',
          provider: CloudProvider.gemini,
          limitTpm: 100,
          description: 'Test expired TPM window',
        );

        final limiter = RateLimiter(
          modelInfo: mockInfo,
          throttlePercentage: 100.0,
        );

        // Add expired token entries older than 1 minute
        final expiredTimestamp = DateTime.now().subtract(
          const Duration(minutes: 2),
        );
        limiter.recordRequestForTesting(expiredTimestamp, tokenCount: 80);

        // Estimated tokens exceeds effectiveTpm (150 > 100)
        // Should prune expired entry and not throw StateError: Bad state: No element
        final stopwatch = Stopwatch()..start();
        await limiter.throttleBeforeRequest(150);
        stopwatch.stop();

        expect(stopwatch.elapsedMilliseconds, lessThan(50));
      },
    );
  });
}
