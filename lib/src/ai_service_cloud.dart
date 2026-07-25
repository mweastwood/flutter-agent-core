import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'ai_service.dart';

import 'model_database.dart';
import 'rate_limiter.dart';

class CloudAiService extends AiService {
  final String baseUrl;
  final String apiKey;
  final String modelName;
  final double throttlePercentage;
  final http.Client _httpClient;
  final RateLimiter? _rateLimiter;

  CloudAiService({
    required this.baseUrl,
    required this.apiKey,
    required this.modelName,
    this.throttlePercentage = 100.0,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client(),
       _rateLimiter = (() {
         final info = CloudModelDatabase.getModelInfo(modelName);
         return info != null
             ? RateLimiter(
                 modelInfo: info,
                 throttlePercentage: throttlePercentage,
               )
             : null;
       })();

  @override
  Future<AiCoreStatus> checkStatus() async {
    return AiCoreStatus.available;
  }

  @override
  Future<void> triggerDownload() async {}

  @override
  Future<void> setModelConfig({
    required String releaseStage,
    required String preference,
  }) async {}

  @override
  Future<int> countTokens({
    required String prompt,
    Uint8List? imageBytes,
  }) async {
    // Estimator: 1 token is roughly 4 characters
    int count = (prompt.length / 4).round();
    if (imageBytes != null && imageBytes.isNotEmpty) {
      count += 256;
    }
    return count;
  }

  @override
  Future<AiResponse?> generateContentRaw({
    required String prompt,
    Uint8List? imageBytes,
    double temperature = 1.0,
    int? maxOutputTokens,
  }) async {
    if (_rateLimiter != null) {
      final estimatedTokens = await countTokens(
        prompt: prompt,
        imageBytes: imageBytes,
      );
      await _rateLimiter.throttleBeforeRequest(estimatedTokens);
    }

    final url = Uri.parse('$baseUrl/chat/completions');

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

    final cleanApiKey = apiKey.replaceAll(RegExp(r'[^\x00-\x7F]'), '').trim();
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $cleanApiKey',
    };

    final body = jsonEncode({
      'model': modelName,
      'messages': messages,
      'temperature': temperature,
      'max_tokens': ?maxOutputTokens,
    });

    try {
      final response = await _httpClient.post(
        url,
        headers: headers,
        body: body,
      );
      if (response.statusCode != 200) {
        debugPrint(
          'CloudAiService error response: ${response.statusCode} - ${response.body}',
        );
        return AiResponse(
          text: '{"error": "Server returned code ${response.statusCode}"}',
          isTruncated: false,
        );
      }

      final data = jsonDecode(response.body);
      final choice = data['choices']?[0];
      final text = choice?['message']?['content'] as String?;
      final finishReason = choice?['finish_reason'] as String?;
      final isTruncated = finishReason == 'length';

      final usage = data['usage'] as Map<String, dynamic>?;
      int? inputTokens = usage?['prompt_tokens'] as int?;
      int? outputTokens = usage?['completion_tokens'] as int?;
      int? totalTokens = usage?['total_tokens'] as int?;

      if (text != null) {
        inputTokens ??= await countTokens(
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
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        totalTokens: totalTokens,
        estimatedCostUsd: estimatedCost,
      );
    } catch (e, stack) {
      debugPrint('Error in CloudAiService post request: $e\n$stack');
      return AiResponse(
        text: '{"error": "${e.toString().replaceAll('"', '\\"')}"}',
        isTruncated: false,
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
