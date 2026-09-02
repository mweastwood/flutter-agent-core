import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'model_database.dart';

class RateLimiter {
  final double throttlePercentage;
  final CloudModelInfo modelInfo;
  final DateTime Function() _now;

  final Queue<DateTime> _requestTimestamps = Queue<DateTime>();
  final Queue<({DateTime timestamp, int tokenCount})> _tokenUsage =
      Queue<({DateTime timestamp, int tokenCount})>();
  int _runningTokenSum = 0;

  /// Creates a new [RateLimiter] instance.
  ///
  /// The [nowProvider] parameter is an optional callback returning a [DateTime],
  /// providing a dependency injection point for clock control during testing.
  RateLimiter({
    required this.modelInfo,
    this.throttlePercentage = 100.0,
    DateTime Function()? nowProvider,
  }) : _now = nowProvider ?? DateTime.now;

  @visibleForTesting
  List<DateTime> get requestTimestamps => List.unmodifiable(_requestTimestamps);

  @visibleForTesting
  List<({DateTime timestamp, int tokenCount})> get tokenUsage =>
      List.unmodifiable(_tokenUsage);

  @visibleForTesting
  void recordRequestForTesting(DateTime timestamp, {int tokenCount = 0}) {
    _requestTimestamps.add(timestamp);
    _tokenUsage.add((timestamp: timestamp, tokenCount: tokenCount));
    _runningTokenSum += tokenCount;
  }

  void _pruneExpiredRequests(DateTime now, Duration window) {
    while (_requestTimestamps.isNotEmpty &&
        now.difference(_requestTimestamps.first) >= window) {
      _requestTimestamps.removeFirst();
    }
  }

  void _pruneExpiredTokens(DateTime now, Duration window) {
    while (_tokenUsage.isNotEmpty &&
        now.difference(_tokenUsage.first.timestamp) >= window) {
      final removed = _tokenUsage.removeFirst();
      _runningTokenSum = (_runningTokenSum - removed.tokenCount).clamp(
        0,
        1 << 62,
      );
    }
  }

  Future<void> throttleBeforeRequest(int estimatedTokens) async {
    if (throttlePercentage <= 0.0) {
      final actualRequestTime = _now();
      _requestTimestamps.add(actualRequestTime);
      _tokenUsage.add((
        timestamp: actualRequestTime,
        tokenCount: estimatedTokens,
      ));
      _runningTokenSum += estimatedTokens;
      return;
    }

    final now = _now();
    final double pctFactor = throttlePercentage / 100.0;

    _pruneExpiredRequests(now, const Duration(minutes: 1));
    _pruneExpiredTokens(now, const Duration(minutes: 1));

    if (modelInfo.limitRps != null && modelInfo.limitRps! > 0) {
      final double effectiveRps = modelInfo.limitRps! * pctFactor;
      if (effectiveRps > 0) {
        final double intervalMs = 1000 / effectiveRps;
        if (intervalMs.isFinite && intervalMs <= 86400000) {
          final requiredInterval = Duration(milliseconds: intervalMs.round());
          if (_requestTimestamps.isNotEmpty) {
            final lastRequestTime = _requestTimestamps.last;
            final elapsed = now.difference(lastRequestTime);
            if (elapsed < requiredInterval) {
              final waitDuration = requiredInterval - elapsed;
              if (waitDuration > Duration.zero) {
                await Future.delayed(waitDuration);
              }
            }
          }
        }
      }
    }

    if (modelInfo.limitRpm != null && modelInfo.limitRpm! > 0) {
      final double effectiveRpm = modelInfo.limitRpm! * pctFactor;
      while (true) {
        final checkTime = _now();
        _pruneExpiredRequests(checkTime, const Duration(minutes: 1));
        if (_requestTimestamps.length < effectiveRpm) {
          break;
        }
        if (_requestTimestamps.isEmpty) break;
        final oldestInWindow = _requestTimestamps.first;
        final waitDuration =
            const Duration(minutes: 1) -
            checkTime.difference(oldestInWindow) +
            const Duration(milliseconds: 100);
        if (waitDuration > Duration.zero) {
          await Future.delayed(waitDuration);
        }
      }
    }

    if (modelInfo.limitTpm != null && modelInfo.limitTpm! > 0) {
      final double effectiveTpm = modelInfo.limitTpm! * pctFactor;
      while (true) {
        final checkTime = _now();
        _pruneExpiredTokens(checkTime, const Duration(minutes: 1));

        if (_runningTokenSum + estimatedTokens <= effectiveTpm) {
          break;
        }
        if (_tokenUsage.isEmpty) break;
        final oldestInWindow = _tokenUsage.first;
        final waitDuration =
            const Duration(minutes: 1) -
            checkTime.difference(oldestInWindow.timestamp) +
            const Duration(milliseconds: 100);
        if (waitDuration > Duration.zero) {
          await Future.delayed(waitDuration);
        }
      }
    }

    final actualRequestTime = _now();
    _requestTimestamps.add(actualRequestTime);
    _tokenUsage.add((
      timestamp: actualRequestTime,
      tokenCount: estimatedTokens,
    ));
    _runningTokenSum += estimatedTokens;
  }
}
