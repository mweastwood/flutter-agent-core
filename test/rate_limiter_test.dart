import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_agent_core/flutter_agent_core.dart';

void main() {
  group('RateLimiter Tests', () {
    test('RateLimiter enforces Request-Per-Second (RPS) limits', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026, 1, 1));
        final mockInfo = CloudModelInfo(
          modelName: 'test-rps-model',
          provider: CloudProvider.gemini,
          limitRps: 10, // 10 RPS -> 100ms interval
          description: 'Test limit',
        );

        final limiter = RateLimiter(
          modelInfo: mockInfo,
          throttlePercentage: 100.0,
          nowProvider: () => clock.now(),
        );

        limiter.throttleBeforeRequest(10);
        expect(async.elapsed, equals(Duration.zero));
        expect(limiter.requestTimestamps.length, equals(1));

        limiter.throttleBeforeRequest(10);
        expect(limiter.requestTimestamps.length, equals(1));

        async.elapse(const Duration(milliseconds: 50));
        expect(limiter.requestTimestamps.length, equals(1));

        async.elapse(const Duration(milliseconds: 50));

        // The second request should be throttled/delayed to enforce the 100ms interval
        expect(async.elapsed, equals(const Duration(milliseconds: 100)));
        expect(limiter.requestTimestamps.length, equals(2));
        expect(
          limiter.requestTimestamps[1].difference(limiter.requestTimestamps[0]),
          equals(const Duration(milliseconds: 100)),
        );
      });
    });

    test('RateLimiter honors throttlePercentage setting', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026, 1, 1));
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
          nowProvider: () => clock.now(),
        );

        limiter.throttleBeforeRequest(10);
        expect(async.elapsed, equals(Duration.zero));
        expect(limiter.requestTimestamps.length, equals(1));

        limiter.throttleBeforeRequest(10);
        expect(limiter.requestTimestamps.length, equals(1));

        async.elapse(const Duration(milliseconds: 100));
        expect(limiter.requestTimestamps.length, equals(1));

        async.elapse(const Duration(milliseconds: 100));

        expect(async.elapsed, equals(const Duration(milliseconds: 200)));
        expect(limiter.requestTimestamps.length, equals(2));
        expect(
          limiter.requestTimestamps[1].difference(limiter.requestTimestamps[0]),
          equals(const Duration(milliseconds: 200)),
        );
      });
    });

    test('RateLimiter handles Requests-Per-Minute (RPM) throttling', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026, 1, 1));
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
          nowProvider: () => clock.now(),
        );

        limiter.throttleBeforeRequest(10);
        limiter.throttleBeforeRequest(10);

        // Enforces wait so requests fit within the minute rate limit
        // With 120 RPM, the rate check passes immediately unless we exceed the 1-minute bucket.
        expect(async.elapsed, equals(Duration.zero));
        expect(limiter.requestTimestamps.length, equals(2));
      });
    });

    test(
      'RateLimiter prunes request timestamps and token usage older than 1 minute',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          final mockInfo = CloudModelInfo(
            modelName: 'test-prune-model',
            provider: CloudProvider.gemini,
            description: 'Test limit',
          );

          final limiter = RateLimiter(
            modelInfo: mockInfo,
            throttlePercentage: 100.0,
            nowProvider: () => clock.now(),
          );

          final oldTimestamp = clock.now().subtract(const Duration(minutes: 2));
          final recentTimestamp = clock.now().subtract(
            const Duration(seconds: 10),
          );

          limiter.recordRequestForTesting(oldTimestamp, tokenCount: 150);
          limiter.recordRequestForTesting(recentTimestamp, tokenCount: 75);

          expect(limiter.requestTimestamps.length, equals(2));
          expect(limiter.tokenUsage.length, equals(2));

          limiter.throttleBeforeRequest(20);

          // Old timestamp should be pruned; recent timestamp and current request remain
          expect(limiter.requestTimestamps.length, equals(2));
          expect(limiter.requestTimestamps.contains(oldTimestamp), isFalse);
          expect(limiter.requestTimestamps.contains(recentTimestamp), isTrue);
          expect(limiter.requestTimestamps.contains(clock.now()), isTrue);

          expect(limiter.tokenUsage.length, equals(2));
          expect(
            limiter.tokenUsage.any((item) => item.timestamp == oldTimestamp),
            isFalse,
          );
          expect(
            limiter.tokenUsage.any((item) => item.timestamp == recentTimestamp),
            isTrue,
          );
          expect(
            limiter.tokenUsage.any(
              (item) => item.timestamp == clock.now() && item.tokenCount == 20,
            ),
            isTrue,
          );
        });
      },
    );

    test('RateLimiter handles Tokens-Per-Minute (TPM) throttling', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026, 1, 1));
        final mockInfo = CloudModelInfo(
          modelName: 'test-tpm-model',
          provider: CloudProvider.gemini,
          limitTpm: 100000,
          description: 'Test limit',
        );

        final limiter = RateLimiter(
          modelInfo: mockInfo,
          throttlePercentage: 100.0,
          nowProvider: () => clock.now(),
        );

        limiter.throttleBeforeRequest(500);
        limiter.throttleBeforeRequest(500);

        expect(async.elapsed, equals(Duration.zero));
        expect(limiter.tokenUsage.length, equals(2));
      });
    });

    test(
      'RateLimiter disables throttling on throttlePercentage = 0.0 without errors',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
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
            nowProvider: () => clock.now(),
          );

          limiter.throttleBeforeRequest(10);
          limiter.throttleBeforeRequest(50);
          limiter.throttleBeforeRequest(200);

          expect(async.elapsed, equals(Duration.zero));
          expect(limiter.requestTimestamps.length, equals(3));
        });
      },
    );

    test('RateLimiter handles negative throttlePercentage safely', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026, 1, 1));
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
          nowProvider: () => clock.now(),
        );

        limiter.throttleBeforeRequest(10);

        expect(async.elapsed, equals(Duration.zero));
      });
    });

    test(
      'RateLimiter handles estimatedTokens exceeding TPM limit without infinite loop or crash',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          final mockInfo = CloudModelInfo(
            modelName: 'test-large-tokens-model',
            provider: CloudProvider.gemini,
            limitTpm: 50,
            description: 'Test large tokens',
          );

          final limiter = RateLimiter(
            modelInfo: mockInfo,
            throttlePercentage: 100.0,
            nowProvider: () => clock.now(),
          );

          limiter.throttleBeforeRequest(100);

          expect(async.elapsed, equals(Duration.zero));
        });
      },
    );

    test(
      'RateLimiter handles expired TPM windows with large estimated tokens without StateError',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          final mockInfo = CloudModelInfo(
            modelName: 'test-expired-tpm-model',
            provider: CloudProvider.gemini,
            limitTpm: 100,
            description: 'Test expired TPM window',
          );

          final limiter = RateLimiter(
            modelInfo: mockInfo,
            throttlePercentage: 100.0,
            nowProvider: () => clock.now(),
          );

          final expiredTimestamp = clock.now().subtract(
            const Duration(minutes: 2),
          );
          limiter.recordRequestForTesting(expiredTimestamp, tokenCount: 80);

          limiter.throttleBeforeRequest(150);

          expect(async.elapsed, equals(Duration.zero));
        });
      },
    );

    test(
      'RateLimiter handles near-zero or underflow throttlePercentage in RPS without division-by-zero or infinity exceptions',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          final mockInfo = CloudModelInfo(
            modelName: 'test-underflow-rps-model',
            provider: CloudProvider.gemini,
            limitRps: 10,
            description: 'Test limit',
          );

          final limiter = RateLimiter(
            modelInfo: mockInfo,
            throttlePercentage: 1e-320,
            nowProvider: () => clock.now(),
          );

          limiter.throttleBeforeRequest(10);
          limiter.throttleBeforeRequest(10);

          expect(async.elapsed, equals(Duration.zero));
        });
      },
    );

    test(
      'RateLimiter handles expired RPM window with active RPM limit without StateError',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          final mockInfo = CloudModelInfo(
            modelName: 'test-expired-rpm-model',
            provider: CloudProvider.gemini,
            limitRpm: 1,
            description: 'Test expired RPM window',
          );

          final limiter = RateLimiter(
            modelInfo: mockInfo,
            throttlePercentage: 100.0,
            nowProvider: () => clock.now(),
          );

          final expiredTimestamp = clock.now().subtract(
            const Duration(minutes: 2),
          );
          limiter.recordRequestForTesting(expiredTimestamp);

          limiter.throttleBeforeRequest(10);

          expect(async.elapsed, equals(Duration.zero));
        });
      },
    );

    test(
      'RateLimiter handles fractional effective limits for RPS, RPM, and TPM',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          final mockInfo = CloudModelInfo(
            modelName: 'test-fractional-model',
            provider: CloudProvider.gemini,
            limitRps: 1,
            limitRpm: 5,
            limitTpm: 50,
            description: 'Test fractional limits',
          );

          final limiter = RateLimiter(
            modelInfo: mockInfo,
            throttlePercentage:
                25.0, // 0.25 RPS -> 4000ms interval, 1.25 RPM, 12.5 TPM
            nowProvider: () => clock.now(),
          );

          limiter.throttleBeforeRequest(5);

          expect(async.elapsed, equals(Duration.zero));
          expect(limiter.requestTimestamps.length, equals(1));
          expect(limiter.tokenUsage.length, equals(1));
        });
      },
    );
  });
}
