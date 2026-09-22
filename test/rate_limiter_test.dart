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
            limitTpm: 1000,
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

    test(
      'RateLimiter prunes request timestamps and token usage exactly on the 1-minute boundary',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          final mockInfo = CloudModelInfo(
            modelName: 'test-boundary-prune-model',
            provider: CloudProvider.gemini,
            limitRpm: 1,
            limitTpm: 100,
            description: 'Test boundary limit',
          );

          final limiter = RateLimiter(
            modelInfo: mockInfo,
            throttlePercentage: 100.0,
            nowProvider: () => clock.now(),
          );

          // Record an entry exactly 60 seconds (1 minute) ago
          final boundaryTimestamp = clock.now().subtract(
            const Duration(minutes: 1),
          );
          limiter.recordRequestForTesting(boundaryTimestamp, tokenCount: 100);

          expect(limiter.requestTimestamps.length, equals(1));
          expect(limiter.tokenUsage.length, equals(1));

          // Next request at clock.now() should prune the boundary entry without waiting
          limiter.throttleBeforeRequest(50);

          expect(async.elapsed, equals(Duration.zero));
          expect(limiter.requestTimestamps.length, equals(1));
          expect(limiter.requestTimestamps.first, equals(clock.now()));
          expect(
            limiter.requestTimestamps.contains(boundaryTimestamp),
            isFalse,
          );

          expect(limiter.tokenUsage.length, equals(1));
          expect(limiter.tokenUsage.first.timestamp, equals(clock.now()));
          expect(limiter.tokenUsage.first.tokenCount, equals(50));
          expect(
            limiter.tokenUsage.any(
              (item) => item.timestamp == boundaryTimestamp,
            ),
            isFalse,
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
          expect(limiter.tokenUsage.length, equals(3));
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
        expect(limiter.requestTimestamps.length, equals(1));
        expect(limiter.tokenUsage.length, equals(1));
      });
    });

    test(
      'RateLimiter with throttlePercentage: 0.0 prunes expired request timestamps and token entries after 1 minute has elapsed',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          final mockInfo = CloudModelInfo(
            modelName: 'test-zero-throttle-prune-model',
            provider: CloudProvider.gemini,
            limitRps: 10,
            limitRpm: 120,
            limitTpm: 100,
            description: 'Test zero throttle pruning',
          );

          final limiter = RateLimiter(
            modelInfo: mockInfo,
            throttlePercentage: 0.0,
            nowProvider: () => clock.now(),
          );

          final oldTimestamp = clock.now();
          limiter.throttleBeforeRequest(100);
          expect(limiter.requestTimestamps.length, equals(1));
          expect(limiter.tokenUsage.length, equals(1));
          expect(limiter.runningTokenSum, equals(100));

          // Elapse 30 seconds - still within 1-minute window
          async.elapse(const Duration(seconds: 30));
          limiter.throttleBeforeRequest(50);
          expect(limiter.requestTimestamps.length, equals(2));
          expect(limiter.tokenUsage.length, equals(2));
          expect(limiter.runningTokenSum, equals(150));

          // Elapse another 35 seconds (total 65s since first request)
          async.elapse(const Duration(seconds: 35));
          limiter.throttleBeforeRequest(25);

          // First request (65s ago) should be pruned; second (35s ago) and third (0s ago) remain
          expect(limiter.requestTimestamps.length, equals(2));
          expect(limiter.tokenUsage.length, equals(2));
          expect(limiter.requestTimestamps.contains(oldTimestamp), isFalse);
          expect(limiter.runningTokenSum, equals(75)); // 50 + 25, 100 pruned
        });
      },
    );

    test(
      'RateLimiter with negative throttlePercentage prunes expired history and decrements runningTokenSum',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          final mockInfo = CloudModelInfo(
            modelName: 'test-negative-throttle-prune-model',
            provider: CloudProvider.gemini,
            limitRps: 10,
            limitRpm: 120,
            limitTpm: 100,
            description: 'Test negative throttle pruning',
          );

          final limiter = RateLimiter(
            modelInfo: mockInfo,
            throttlePercentage: -10.0,
            nowProvider: () => clock.now(),
          );

          final oldTimestamp = clock.now();
          limiter.throttleBeforeRequest(80);
          expect(limiter.requestTimestamps.length, equals(1));
          expect(limiter.tokenUsage.length, equals(1));
          expect(limiter.runningTokenSum, equals(80));

          // Advance past 1 minute window
          async.elapse(const Duration(seconds: 61));
          limiter.throttleBeforeRequest(30);

          expect(limiter.requestTimestamps.length, equals(1));
          expect(limiter.tokenUsage.length, equals(1));
          expect(limiter.requestTimestamps.contains(oldTimestamp), isFalse);
          expect(limiter.runningTokenSum, equals(30));
        });
      },
    );

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

    test(
      'FIFO pruning correctly drains multiple expired timestamps and token items in order',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          final mockInfo = CloudModelInfo(
            modelName: 'test-fifo-prune-model',
            provider: CloudProvider.gemini,
            limitRpm: 10,
            limitTpm: 1000,
            description: 'Test FIFO pruning',
          );

          final limiter = RateLimiter(
            modelInfo: mockInfo,
            throttlePercentage: 100.0,
            nowProvider: () => clock.now(),
          );

          // Add 5 entries spanning from 3 minutes ago to 30 seconds ago
          final tMinus180 = clock.now().subtract(const Duration(seconds: 180));
          final tMinus120 = clock.now().subtract(const Duration(seconds: 120));
          final tMinus90 = clock.now().subtract(const Duration(seconds: 90));
          final tMinus61 = clock.now().subtract(const Duration(seconds: 61));
          final tMinus30 = clock.now().subtract(const Duration(seconds: 30));

          limiter.recordRequestForTesting(tMinus180, tokenCount: 100);
          limiter.recordRequestForTesting(tMinus120, tokenCount: 100);
          limiter.recordRequestForTesting(tMinus90, tokenCount: 100);
          limiter.recordRequestForTesting(tMinus61, tokenCount: 100);
          limiter.recordRequestForTesting(tMinus30, tokenCount: 100);

          expect(limiter.requestTimestamps.length, equals(5));
          expect(limiter.tokenUsage.length, equals(5));

          // Next request will trigger pruning of everything older than 1 minute
          limiter.throttleBeforeRequest(50);

          // Remaining: tMinus30 and the new request at clock.now()
          expect(limiter.requestTimestamps.length, equals(2));
          expect(limiter.requestTimestamps.first, equals(tMinus30));
          expect(limiter.requestTimestamps.last, equals(clock.now()));

          expect(limiter.tokenUsage.length, equals(2));
          expect(limiter.tokenUsage.first.timestamp, equals(tMinus30));
          expect(limiter.tokenUsage.first.tokenCount, equals(100));
          expect(limiter.tokenUsage.last.timestamp, equals(clock.now()));
          expect(limiter.tokenUsage.last.tokenCount, equals(50));
        });
      },
    );

    test(
      'Running token counter accurately reflects sliding window token count and enforces TPM across sliding windows',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          final mockInfo = CloudModelInfo(
            modelName: 'test-running-token-model',
            provider: CloudProvider.gemini,
            limitTpm: 300,
            description: 'Test running token counter',
          );

          final limiter = RateLimiter(
            modelInfo: mockInfo,
            throttlePercentage: 100.0,
            nowProvider: () => clock.now(),
          );

          // Make 3 requests consuming 100 tokens each at t = 0, 10s, 20s
          limiter.throttleBeforeRequest(100);
          async.elapse(const Duration(seconds: 10));
          limiter.throttleBeforeRequest(100);
          async.elapse(const Duration(seconds: 10));
          limiter.throttleBeforeRequest(100);

          expect(limiter.tokenUsage.length, equals(3));

          // Next request of 50 tokens would exceed limitTpm (300 + 50 > 300)
          // It should wait until the first 100-token request expires (at t = 60.1s total, i.e. 40.1s from current t = 20s)
          limiter.throttleBeforeRequest(50);
          expect(async.elapsed, equals(const Duration(seconds: 20)));

          async.elapse(
            const Duration(seconds: 41),
          ); // advance past the first window
          expect(
            limiter.tokenUsage.length,
            equals(3),
          ); // first expired, 2 remaining + 1 new
          expect(limiter.tokenUsage.last.tokenCount, equals(50));
        });
      },
    );

    test(
      'High-throughput burst scenarios maintain correct RPM throttling and prune efficiently',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          final mockInfo = CloudModelInfo(
            modelName: 'test-burst-model',
            provider: CloudProvider.gemini,
            limitRpm: 5,
            description: 'Test high-throughput burst',
          );

          final limiter = RateLimiter(
            modelInfo: mockInfo,
            throttlePercentage: 100.0,
            nowProvider: () => clock.now(),
          );

          // Fire 5 requests immediately
          for (int i = 0; i < 5; i++) {
            limiter.throttleBeforeRequest(10);
          }
          expect(limiter.requestTimestamps.length, equals(5));

          // The 6th request must wait for the 1st request to expire (60.1s)
          limiter.throttleBeforeRequest(10);
          async.elapse(const Duration(seconds: 61));

          expect(limiter.requestTimestamps.length, equals(1));
          expect(
            limiter.requestTimestamps.first,
            equals(DateTime(2026, 1, 1, 0, 1, 0, 100)),
          );
        });
      },
    );

    test(
      'RateLimiter skips token tracking and queue allocation when limitTpm is null or non-positive',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          // Case 1: limitTpm is null (unconfigured)
          final unconfiguredInfo = CloudModelInfo(
            modelName: 'test-unconfigured-tpm-model',
            provider: CloudProvider.gemini,
            description: 'Test unconfigured TPM limit',
          );

          final limiter = RateLimiter(
            modelInfo: unconfiguredInfo,
            throttlePercentage: 100.0,
            nowProvider: () => clock.now(),
          );

          limiter.throttleBeforeRequest(500);
          limiter.throttleBeforeRequest(300);

          expect(limiter.requestTimestamps.length, equals(2));
          expect(limiter.tokenUsage.isEmpty, isTrue);
          expect(limiter.runningTokenSum, equals(0));

          // Case 2: throttlePercentage <= 0.0 with limitTpm null
          final zeroThrottleLimiter = RateLimiter(
            modelInfo: unconfiguredInfo,
            throttlePercentage: 0.0,
            nowProvider: () => clock.now(),
          );

          zeroThrottleLimiter.throttleBeforeRequest(1000);
          expect(zeroThrottleLimiter.requestTimestamps.length, equals(1));
          expect(zeroThrottleLimiter.tokenUsage.isEmpty, isTrue);
          expect(zeroThrottleLimiter.runningTokenSum, equals(0));

          // Case 3: limitTpm is 0 or negative
          for (final nonPositiveTpm in [0, -50]) {
            final nonPositiveInfo = CloudModelInfo(
              modelName: 'test-non-positive-tpm-model',
              provider: CloudProvider.gemini,
              limitTpm: nonPositiveTpm,
              description: 'Test non-positive TPM limit',
            );

            final nonPosLimiter = RateLimiter(
              modelInfo: nonPositiveInfo,
              throttlePercentage: 100.0,
              nowProvider: () => clock.now(),
            );

            nonPosLimiter.throttleBeforeRequest(250);
            expect(nonPosLimiter.requestTimestamps.length, equals(1));
            expect(nonPosLimiter.tokenUsage.isEmpty, isTrue);
            expect(nonPosLimiter.runningTokenSum, equals(0));
          }

          // Case 4: pruneExpiredTokens is skipped when limitTpm is null
          final pruningSkipLimiter = RateLimiter(
            modelInfo: unconfiguredInfo,
            throttlePercentage: 100.0,
            nowProvider: () => clock.now(),
          );
          final oldTimestamp = clock.now().subtract(const Duration(minutes: 2));
          pruningSkipLimiter.recordRequestForTesting(
            oldTimestamp,
            tokenCount: 999,
          );
          expect(pruningSkipLimiter.tokenUsage.length, equals(1));
          expect(pruningSkipLimiter.runningTokenSum, equals(999));

          pruningSkipLimiter.throttleBeforeRequest(100);
          // Timestamp was pruned from requestTimestamps, but tokenUsage wasn't traversed/pruned
          expect(
            pruningSkipLimiter.requestTimestamps.contains(oldTimestamp),
            isFalse,
          );
          expect(pruningSkipLimiter.tokenUsage.length, equals(1));
          expect(pruningSkipLimiter.runningTokenSum, equals(999));
        });
      },
    );

    test(
      'RateLimiter maintains normal RPS and RPM rate limiting without TPM tracking',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          final mockInfo = CloudModelInfo(
            modelName: 'test-rpm-rps-no-tpm-model',
            provider: CloudProvider.gemini,
            limitRps: 5, // 200ms interval
            limitRpm: 2, // max 2 requests per minute
            limitTpm: null, // no TPM limit
            description: 'Test RPM & RPS without TPM',
          );

          final limiter = RateLimiter(
            modelInfo: mockInfo,
            throttlePercentage: 100.0,
            nowProvider: () => clock.now(),
          );

          // First request executes immediately
          limiter.throttleBeforeRequest(1000);
          expect(async.elapsed, equals(Duration.zero));
          expect(limiter.requestTimestamps.length, equals(1));
          expect(limiter.tokenUsage.isEmpty, isTrue);
          expect(limiter.runningTokenSum, equals(0));

          // Second request throttled by RPS (must wait 200ms)
          limiter.throttleBeforeRequest(1000);
          async.elapse(const Duration(milliseconds: 200));
          expect(async.elapsed, equals(const Duration(milliseconds: 200)));
          expect(limiter.requestTimestamps.length, equals(2));
          expect(limiter.tokenUsage.isEmpty, isTrue);
          expect(limiter.runningTokenSum, equals(0));

          // Third request throttled by RPM limit (limit is 2 RPM, must wait for 1st to expire + 100ms buffer)
          limiter.throttleBeforeRequest(1000);
          async.elapse(const Duration(seconds: 60));
          expect(limiter.requestTimestamps.length, equals(2));
          expect(limiter.tokenUsage.isEmpty, isTrue);
          expect(limiter.runningTokenSum, equals(0));
        });
      },
    );

    test(
      'RateLimiter prevents concurrency race condition in throttleBeforeRequest by serializing RPS limits for concurrent requests',
      () {
        fakeAsync((async) {
          final clock = async.getClock(DateTime(2026, 1, 1));
          final mockInfo = CloudModelInfo(
            modelName: 'test-concurrent-rps-model',
            provider: CloudProvider.gemini,
            limitRps: 10, // 10 RPS -> 100ms interval
            description: 'Test concurrent limit',
          );

          final limiter = RateLimiter(
            modelInfo: mockInfo,
            throttlePercentage: 100.0,
            nowProvider: () => clock.now(),
          );

          // Fire initial request at t = 0ms
          limiter.throttleBeforeRequest(10);
          expect(limiter.requestTimestamps.length, equals(1));

          // Elapse 50ms (within the 100ms interval)
          async.elapse(const Duration(milliseconds: 50));

          // Now launch 3 concurrent requests at t = 50ms
          final req1 = limiter.throttleBeforeRequest(10);
          final req2 = limiter.throttleBeforeRequest(10);
          final req3 = limiter.throttleBeforeRequest(10);

          // Advance 50ms -> req1 should execute at t = 100ms
          async.elapse(const Duration(milliseconds: 50));
          expect(limiter.requestTimestamps.length, equals(2));
          expect(
            limiter.requestTimestamps[1].difference(
              limiter.requestTimestamps[0],
            ),
            equals(const Duration(milliseconds: 100)),
          );

          // Advance another 100ms -> req2 should execute at t = 200ms
          async.elapse(const Duration(milliseconds: 100));
          expect(limiter.requestTimestamps.length, equals(3));
          expect(
            limiter.requestTimestamps[2].difference(
              limiter.requestTimestamps[1],
            ),
            equals(const Duration(milliseconds: 100)),
          );

          // Advance another 100ms -> req3 should execute at t = 300ms
          async.elapse(const Duration(milliseconds: 100));
          expect(limiter.requestTimestamps.length, equals(4));
          expect(
            limiter.requestTimestamps[3].difference(
              limiter.requestTimestamps[2],
            ),
            equals(const Duration(milliseconds: 100)),
          );
        });
      },
    );
  });
}
