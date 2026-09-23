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

class CloudAiService extends AiService {
  final String baseUrl;
  final String apiKey;
  final String modelName;
  final double throttlePercentage;
  final int maxRetries;
  final Duration initialRetryDelay;
  final Duration maxRetryDelay;
  final bool enableJitter;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Uri _endpointUri;
  final Map<String, String> _headers;
  final RateLimiter? _rateLimiter;
  final Random? _random;

  CloudAiService({
    required this.baseUrl,
    required this.apiKey,
    required this.modelName,
    this.throttlePercentage = 100.0,
    this.maxRetries = 4,
    this.initialRetryDelay = const Duration(milliseconds: 1500),
    this.maxRetryDelay = const Duration(seconds: 15),
    this.enableJitter = true,
    http.Client? httpClient,
    Random? random,
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _random = random,
       _endpointUri = Uri.parse(
         '${baseUrl.trim().replaceAll(_trailingSlashesRegex, '')}/chat/completions',
       ),
       _headers = Map.unmodifiable({
         'Content-Type': 'application/json',
         'Authorization': 'Bearer ${apiKey.replaceAll(_reNonAscii, '').trim()}',
       }),
       _rateLimiter = (() {
         final info = CloudModelDatabase.getModelInfo(modelName);
         return info != null
             ? RateLimiter(
                 modelInfo: info,
                 throttlePercentage: throttlePercentage,
               )
             : null;
       })();

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
  }) async => AiService.estimateTokenCount(prompt, imageBytes: imageBytes);

  @visibleForTesting
  Duration calculateBackoff(int attempt, http.Response? response) =>
      _calculateBackoff(attempt, response);

  Duration _calculateBackoff(int attempt, http.Response? response) {
    if (response != null) {
      String? retryAfterStr;
      for (final entry in response.headers.entries) {
        if (entry.key.toLowerCase() == 'retry-after') {
          retryAfterStr = entry.value;
          break;
        }
      }
      if (retryAfterStr != null) {
        final seconds = int.tryParse(retryAfterStr.trim());
        if (seconds != null && seconds > 0) {
          return Duration(seconds: seconds);
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

    final body = jsonEncode({
      'model': modelName,
      'messages': messages,
      'temperature': temperature,
      if (maxOutputTokens != null) 'max_tokens': maxOutputTokens,
    });

    dynamic lastError;
    StackTrace? lastStackTrace;
    http.Response? lastResponse;

    final totalAttempts = maxRetries > 0 ? maxRetries + 1 : 1;

    for (int attempt = 1; attempt <= totalAttempts; attempt++) {
      try {
        final response = await _httpClient.post(
          _endpointUri,
          headers: _headers,
          body: body,
        );

        lastResponse = response;
        lastError = null;
        lastStackTrace = null;

        if (response.statusCode == 200) {
          break;
        }

        debugPrint(
          'CloudAiService response status ${response.statusCode} (attempt $attempt/$totalAttempts): ${response.body}',
        );

        // Check if retryable status code: 429 (Rate Limit), 500, 502, 503, 504 (Server Errors)
        final isRetryable =
            response.statusCode == 429 ||
            response.statusCode == 500 ||
            response.statusCode == 502 ||
            response.statusCode == 503 ||
            response.statusCode == 504;

        if (!isRetryable || attempt == totalAttempts) {
          break;
        }

        final backoff = _calculateBackoff(attempt, response);
        await Future.delayed(backoff);
      } catch (e, stack) {
        lastError = e;
        lastStackTrace = stack;
        debugPrint(
          'Error in CloudAiService post request (attempt $attempt/$totalAttempts): $e',
        );

        if (attempt == totalAttempts) {
          break;
        }

        final backoff = _calculateBackoff(attempt, null);
        await Future.delayed(backoff);
      }
    }

    if (lastError != null) {
      debugPrint(
        'Error in CloudAiService post request: $lastError\n$lastStackTrace',
      );
      return AiResponse(
        text: '{"error": "${lastError.toString().replaceAll('"', '\\"')}"}',
        isTruncated: false,
        isError: true,
      );
    }

    if (lastResponse == null || lastResponse.statusCode != 200) {
      final statusCode = lastResponse?.statusCode ?? 500;
      debugPrint(
        'CloudAiService error response: $statusCode - ${lastResponse?.body}',
      );
      return AiResponse(
        text: '{"error": "Server returned code $statusCode"}',
        isTruncated: false,
        isError: true,
      );
    }

    try {
      final data = jsonDecode(lastResponse.body);
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
            await countTokens(
              prompt: prompt,
              imageBytes: imageBytes,
            );
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
      return AiResponse(
        text: '{"error": "${e.toString().replaceAll('"', '\\"')}"}',
        isTruncated: false,
        isError: true,
      );
    }
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
