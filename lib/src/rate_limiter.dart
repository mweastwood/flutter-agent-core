import 'dart:async';

import 'package:flutter/foundation.dart';

import 'model_database.dart';

class RateLimiter {
  final double throttlePercentage;
  final CloudModelInfo modelInfo;
  final DateTime Function() _now;

  final List<DateTime> _requestTimestamps = [];
  final List<({DateTime timestamp, int tokenCount})> _tokenUsage = [];

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
  }

  Future<void> throttleBeforeRequest(int estimatedTokens) async {
    if (throttlePercentage <= 0.0) {
      final actualRequestTime = _now();
      _requestTimestamps.add(actualRequestTime);
      _tokenUsage.add((
        timestamp: actualRequestTime,
        tokenCount: estimatedTokens,
      ));
      return;
    }

    final now = _now();
    final double pctFactor = throttlePercentage / 100.0;

    _requestTimestamps.removeWhere(
      (dt) => now.difference(dt) > const Duration(minutes: 1),
    );
    _tokenUsage.removeWhere(
      (item) => now.difference(item.timestamp) > const Duration(minutes: 1),
    );

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
        _requestTimestamps.removeWhere(
          (dt) => checkTime.difference(dt) > const Duration(minutes: 1),
        );
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
        _tokenUsage.removeWhere(
          (item) =>
              checkTime.difference(item.timestamp) > const Duration(minutes: 1),
        );
        final recentTokens = _tokenUsage.fold<int>(
          0,
          (sum, item) => sum + item.tokenCount,
        );

        if (recentTokens + estimatedTokens <= effectiveTpm) {
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
  }
}
