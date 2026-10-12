import 'dart:convert';
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ai_service.dart';

import 'model_database.dart';
import 'rate_limiter.dart';

final _reNonAscii = RegExp(r'[^\x00-\x7F]');
final _trailingSlashesRegex = RegExp(r'/+$');

const Map<String, int> _monthMap = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// Regular expressions for RFC 9110 / RFC 7231 / RFC 2616 HTTP-date formats:
/// 1. IMF-fixdate (preferred): "Sun, 06 Nov 1994 08:49:37 GMT"
final RegExp _imfFixdateRegex = RegExp(
  r'^(?:[A-Za-z]{3},\s+)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT$',
  caseSensitive: false,
);

/// 2. RFC 850 format: "Sunday, 06-Nov-94 08:49:37 GMT"
final RegExp _rfc850Regex = RegExp(
  r'^(?:[A-Za-z]+,\s+)?(\d{1,2})-([A-Za-z]{3})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT$',
  caseSensitive: false,
);

/// 3. ANSI C asctime() format: "Sun Nov  6 08:49:37 1994"
final RegExp _asctimeRegex = RegExp(
  r'^[A-Za-z]{3}\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})$',
  caseSensitive: false,
);

final RegExp _digitsOnlyRegex = RegExp(r'^\d+$');

/// Parses an RFC 9110 / RFC 7231 HTTP-date string into a UTC [DateTime].
///
/// Supports IMF-fixdate (e.g. `Sun, 06 Nov 1994 08:49:37 GMT`),
/// RFC 850 format (e.g. `Sunday, 06-Nov-94 08:49:37 GMT`), and
/// ANSI C asctime() format (e.g. `Sun Nov  6 08:49:37 1994`).
/// Returns `null` if the date string is malformed or invalid.
DateTime? _tryParseHttpDate(String dateString) {
  final trimmed = dateString.trim();
  if (trimmed.isEmpty) return null;

  var match = _imfFixdateRegex.firstMatch(trimmed);
  if (match != null) {
    final day = int.tryParse(match.group(1)!);
    final monthStr = match.group(2)!.toLowerCase();
    final year = int.tryParse(match.group(3)!);
    final hour = int.tryParse(match.group(4)!);
    final minute = int.tryParse(match.group(5)!);
    final second = int.tryParse(match.group(6)!);
    final month = _monthMap[monthStr];

    if (day == null ||
        month == null ||
        year == null ||
        hour == null ||
        minute == null ||
        second == null) {
      return null;
    }
    return _buildValidUtcDateTime(year, month, day, hour, minute, second);
  }

  match = _rfc850Regex.firstMatch(trimmed);
  if (match != null) {
    final day = int.tryParse(match.group(1)!);
    final monthStr = match.group(2)!.toLowerCase();
    final year2 = int.tryParse(match.group(3)!);
    final hour = int.tryParse(match.group(4)!);
    final minute = int.tryParse(match.group(5)!);
    final second = int.tryParse(match.group(6)!);
    final month = _monthMap[monthStr];

    if (day == null ||
        month == null ||
        year2 == null ||
        hour == null ||
        minute == null ||
        second == null) {
      return null;
    }
    final year = year2 >= 70 ? 1900 + year2 : 2000 + year2;
    return _buildValidUtcDateTime(year, month, day, hour, minute, second);
  }

  match = _asctimeRegex.firstMatch(trimmed);
  if (match != null) {
    final monthStr = match.group(1)!.toLowerCase();
    final day = int.tryParse(match.group(2)!);
    final hour = int.tryParse(match.group(3)!);
    final minute = int.tryParse(match.group(4)!);
    final second = int.tryParse(match.group(5)!);
    final year = int.tryParse(match.group(6)!);
    final month = _monthMap[monthStr];

    if (day == null ||
        month == null ||
        year == null ||
        hour == null ||
        minute == null ||
        second == null) {
      return null;
    }
    return _buildValidUtcDateTime(year, month, day, hour, minute, second);
  }

  return null;
}

DateTime? _buildValidUtcDateTime(
  int year,
  int month,
  int day,
  int hour,
  int minute,
  int second,
) {
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > 31) return null;
  if (hour < 0 || hour > 23) return null;
  if (minute < 0 || minute > 59) return null;
  if (second < 0 || second > 60) return null;

  try {
    final dt = DateTime.utc(
      year,
      month,
      day,
      hour,
      minute,
      second == 60 ? 59 : second,
    );
    if (dt.year != year ||
        dt.month != month ||
        dt.day != day ||
        dt.hour != hour ||
        dt.minute != minute) {
      return null;
    }
    return dt;
  } catch (_) {
    return null;
  }
}

class CloudAiService extends AiService {
  /// HTTP status codes representing transient server or rate limiting errors
  /// that are eligible for retry attempts (429, 500, 502, 503, 504).
  @visibleForTesting
  static const Set<int> retryableStatusCodes = {429, 500, 502, 503, 504};

  final String baseUrl;
  final String apiKey;
  final String modelName;
  final double throttlePercentage;
  final int maxRetries;
  final Duration initialRetryDelay;
  final Duration maxRetryDelay;

  /// Maximum time to wait for a single HTTP POST before it is aborted with a
  /// [TimeoutException] and handled by the retry loop.
  final Duration requestTimeout;
  final bool enableJitter;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Uri _endpointUri;
  final Map<String, String> _headers;
  final RateLimiter? _rateLimiter;
  final Random? _random;
  final DateTime Function() _nowProvider;

  /// Creates a [CloudAiService] instance.
  ///
  /// [nowProvider] is an optional injectable clock callback used for
  /// deterministic testing of time-dependent headers.
  CloudAiService({
    required this.baseUrl,
    required this.apiKey,
    required this.modelName,
    this.throttlePercentage = 100.0,
    this.maxRetries = 4,
    this.initialRetryDelay = const Duration(milliseconds: 1500),
    this.maxRetryDelay = const Duration(seconds: 15),
    this.requestTimeout = const Duration(seconds: 60),
    this.enableJitter = true,
    http.Client? httpClient,
    Random? random,
    @visibleForTesting RateLimiter? rateLimiter,
    @visibleForTesting DateTime Function()? nowProvider,
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _random = random,
        _nowProvider = nowProvider ?? DateTime.now,
        _endpointUri = Uri.parse(
          '${baseUrl.trim().replaceAll(_trailingSlashesRegex, '')}/chat/completions',
        ),
        _headers = Map.unmodifiable({
          'Content-Type': 'application/json',
          'Authorization':
              'Bearer ${apiKey.replaceAll(_reNonAscii, '').trim()}',
        }),
        _rateLimiter = rateLimiter ??
            (() {
              final info = CloudModelDatabase.getModelInfo(modelName);
              return info != null
                  ? RateLimiter(
                      modelInfo: info,
                      throttlePercentage: throttlePercentage,
                      nowProvider: nowProvider,
                    )
                  : null;
            })();

  @visibleForTesting
  RateLimiter? get rateLimiter => _rateLimiter;

  /// Closes the internal [http.Client] if it was created and owned by this instance.
  @override
  void dispose() {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }

  @override
  Future<AiCoreStatus> checkStatus() async {
    return AiCoreStatus.available;
  }

  @override
  Future<void> triggerDownload({Duration? delay}) async {
    if (delay != null) {
      await Future.delayed(delay);
    }
  }

  @override
  Future<void> setModelConfig({
    required String releaseStage,
    required String preference,
  }) async {}

  @override
  Future<int> countTokens({
    required String prompt,
    Uint8List? imageBytes,
  }) async =>
      AiService.estimateTokenCount(prompt, imageBytes: imageBytes);

  @visibleForTesting
  static DateTime? parseHttpDate(String dateString) =>
      _tryParseHttpDate(dateString);

  Duration? _parseRetryAfter(String retryAfterStr, {DateTime? now}) {
    final trimmed = retryAfterStr.trim();
    final seconds = int.tryParse(trimmed);
    if (seconds != null) {
      if (seconds < 0) return null;
      if (seconds > maxRetryDelay.inSeconds) return maxRetryDelay;
      final candidate = Duration(seconds: seconds);
      return candidate > maxRetryDelay ? maxRetryDelay : candidate;
    }

    // Handle positive integer seconds that exceed 64-bit int max
    if (_digitsOnlyRegex.hasMatch(trimmed)) {
      return maxRetryDelay;
    }

    final targetDate = _tryParseHttpDate(trimmed);
    if (targetDate != null) {
      final currentTime = now ?? _nowProvider();
      final diff = targetDate.difference(currentTime);
      if (diff.isNegative) return Duration.zero;
      return diff > maxRetryDelay ? maxRetryDelay : diff;
    }

    return null;
  }

  @visibleForTesting
  Duration calculateBackoff(
    int attempt,
    http.Response? response, {
    DateTime? now,
  }) =>
      _calculateBackoff(attempt, response, now: now);

  Duration _calculateBackoff(
    int attempt,
    http.Response? response, {
    DateTime? now,
  }) {
    if (response != null) {
      String? retryAfterStr;
      for (final entry in response.headers.entries) {
        if (entry.key.toLowerCase() == 'retry-after') {
          retryAfterStr = entry.value;
          break;
        }
      }
      if (retryAfterStr != null) {
        final delay = _parseRetryAfter(retryAfterStr, now: now);
        if (delay != null) {
          return delay;
        }
      }
    }

    return AiService.calculateExponentialBackoff(
      attempt: attempt,
      initialRetryDelay: initialRetryDelay,
      maxRetryDelay: maxRetryDelay,
      enableJitter: enableJitter,
      random: _random,
    );
  }

  /// Constructs the JSON request body string for OpenAI-compatible chat completion endpoints.
  ///
  /// Formats the [prompt] and optional [imageBytes] into the messages payload,
  /// and applies the specified [temperature] and optional [maxOutputTokens].
  @visibleForTesting
  String buildRequestBody({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int? maxOutputTokens,
  }) {
    final List<Map<String, dynamic>> messages = [];
    if (imageBytes != null && imageBytes.isNotEmpty) {
      final base64Image = base64Encode(imageBytes);
      messages.add({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': prompt},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,$base64Image'},
          },
        ],
      });
    } else {
      messages.add({'role': 'user', 'content': prompt});
    }

    return jsonEncode({
      'model': modelName,
      'messages': messages,
      'temperature': temperature,
      if (maxOutputTokens != null) 'max_tokens': maxOutputTokens,
    });
  }

  /// Sends the HTTP POST request to the chat completion endpoint with retry and backoff.
  ///
  /// Retries up to [maxRetries] times when encountering transient network errors
  /// or retryable HTTP status codes ([retryableStatusCodes]). Returns the last
  /// [http.Response] (which may have a non-200 status code if retries were exhausted
  /// or if the status code was non-retryable), or rethrows the underlying exception
  /// on terminal network failure.
  @visibleForTesting
  Future<http.Response> postWithRetry(String body) => _postWithRetry(body);

  Future<http.Response> _postWithRetry(String body) async {
    final totalAttempts = maxRetries > 0 ? maxRetries + 1 : 1;

    for (int attempt = 1; attempt <= totalAttempts; attempt++) {
      try {
        final response = await _httpClient
            .post(
              _endpointUri,
              headers: _headers,
              body: body,
            )
            .timeout(requestTimeout);

        if (response.statusCode == 200) {
          return response;
        }

        debugPrint(
          'CloudAiService response status ${response.statusCode} (attempt $attempt/$totalAttempts): ${response.body}',
        );

        final isRetryable = retryableStatusCodes.contains(response.statusCode);
        if (!isRetryable || attempt == totalAttempts) {
          return response;
        }

        final backoff = _calculateBackoff(attempt, response);
        await Future.delayed(backoff);
      } catch (e, stack) {
        if (attempt == totalAttempts) {
          debugPrint(
            'Error in CloudAiService post request: $e\n$stack',
          );
          Error.throwWithStackTrace(e, stack);
        }

        debugPrint(
          'Error in CloudAiService post request (attempt $attempt/$totalAttempts): $e',
        );

        final backoff = _calculateBackoff(attempt, null);
        await Future.delayed(backoff);
      }
    }

    throw StateError('Unreachable');
  }

  /// Parses the raw [response] from the chat completion endpoint into an [AiResponse].
  ///
  /// Extracts the assistant's message content and finish reason from the JSON payload.
  /// Computes token usage using provided usage metrics or falls back to estimating tokens
  /// from [prompt], [imageBytes], and response text (or using [estimatedPromptTokens] if supplied).
  /// Calculates estimated cost based on the configured [modelName].
  /// Returns `null` if the response contains no message content, or an [AiResponse.error]
  /// if JSON decoding or parsing fails.
  @visibleForTesting
  Future<AiResponse?> parseResponse({
    required http.Response response,
    required String prompt,
    Uint8List? imageBytes,
    int? estimatedPromptTokens,
  }) =>
      _parseResponse(
        response: response,
        prompt: prompt,
        imageBytes: imageBytes,
        estimatedPromptTokens: estimatedPromptTokens,
      );

  Future<AiResponse?> _parseResponse({
    required http.Response response,
    required String prompt,
    Uint8List? imageBytes,
    int? estimatedPromptTokens,
  }) async {
    try {
      final data = jsonDecode(response.body);
      final choices = data['choices'] as List?;
      final choice = (choices != null && choices.isNotEmpty)
          ? choices.first as Map<String, dynamic>?
          : null;
      final text = choice?['message']?['content'] as String?;
      final finishReason = choice?['finish_reason'] as String?;
      final isTruncated = finishReason == 'length';

      final usage = data['usage'] as Map<String, dynamic>?;
      int? inputTokens = usage?['prompt_tokens'] as int?;
      int? outputTokens = usage?['completion_tokens'] as int?;
      int? totalTokens = usage?['total_tokens'] as int?;

      if (text != null) {
        inputTokens ??= estimatedPromptTokens ??
            await countTokens(prompt: prompt, imageBytes: imageBytes);
        outputTokens ??= await countTokens(prompt: text);
        totalTokens ??= inputTokens + outputTokens;
      }

      final estimatedCost = (inputTokens != null && outputTokens != null)
          ? CloudModelDatabase.calculateEstimatedCost(
              modelName,
              inputTokens: inputTokens,
              outputTokens: outputTokens,
            )
          : null;

      if (text == null) return null;
      return AiResponse(
        text: text,
        isTruncated: isTruncated,
        isError: false,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        totalTokens: totalTokens,
        estimatedCostUsd: estimatedCost,
      );
    } catch (e, stack) {
      debugPrint('Error decoding CloudAiService response body: $e\n$stack');
      return AiResponse.error(e);
    }
  }

  @override
  Future<AiResponse?> generateContentRaw({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int? maxOutputTokens,
  }) async {
    int? estimatedPromptTokens;
    if (_rateLimiter != null) {
      estimatedPromptTokens = await countTokens(
        prompt: prompt,
        imageBytes: imageBytes,
      );
      await _rateLimiter.throttleBeforeRequest(estimatedPromptTokens);
    }

    final body = buildRequestBody(
      prompt: prompt,
      imageBytes: imageBytes,
      temperature: temperature,
      maxOutputTokens: maxOutputTokens,
    );

    http.Response response;
    try {
      response = await _postWithRetry(body);
    } catch (e) {
      return AiResponse.error(e);
    }

    if (response.statusCode != 200) {
      debugPrint(
        'CloudAiService error response: ${response.statusCode} - ${response.body}',
      );
      return AiResponse.error('Server returned code ${response.statusCode}');
    }

    return _parseResponse(
      response: response,
      prompt: prompt,
      imageBytes: imageBytes,
      estimatedPromptTokens: estimatedPromptTokens,
    );
  }

  @override
  Future<String?> generateContent({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int? maxOutputTokens,
  }) async {
    final res = await generateContentRaw(
      prompt: prompt,
      imageBytes: imageBytes,
      temperature: temperature,
      maxOutputTokens: maxOutputTokens,
    );
    return res?.text;
  }
}
