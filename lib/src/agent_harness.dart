import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'ai_service.dart';
import 'json_utils.dart';

abstract class AgentDelegate<T> {
  /// Formats the prompt for the next step, incorporating loop history.
  String formatPrompt(String userPrompt, List<T> history);

  /// Provides the visual/image input for the next step, if any.
  Uint8List? getVisualInput();

  /// Applies the action represented by the parsed map and returns feedback.
  Future<String> applyAction(Map<String, dynamic> actionMap);

  /// Checks if the action represents a termination/finish action.
  bool isFinishAction(Map<String, dynamic> actionMap);

  /// Maps the raw parsed JSON and execution feedback into the custom step type T.
  T parseStepResult(Map<String, dynamic> actionMap, String feedback);
}

class AgentHarness<T> {
  final AiService aiService;
  final AgentDelegate<T> delegate;

  AgentHarness({required this.aiService, required this.delegate});

  /// Runs the agent reasoning-action loop.
  Future<List<T>> runLoop({
    required String userPrompt,
    int maxSteps = 5,
    double temperature = 1.0,
    Function(T stepResult, int currentStep)? onStep,
  }) async {
    final List<T> results = [];

    for (int step = 1; step <= maxSteps; step++) {
      // 1. Get the combined image input from the delegate
      final visualInput = delegate.getVisualInput();

      // 2. Format the prompt with history
      final prompt = delegate.formatPrompt(userPrompt, results);

      // 3. Query LLM model
      final responseText = await aiService.generateContent(
        prompt: prompt,
        imageBytes: visualInput,
        temperature: temperature,
      );

      if (responseText == null) {
        throw Exception('AI service returned empty response');
      }

      // Parse JSON from response (clean markdown if present)
      final cleanedString = stripMarkdownCodeFences(responseText);

      Map<String, dynamic> parsed;
      try {
        parsed = jsonDecode(cleanedString) as Map<String, dynamic>;
      } catch (e) {
        parsed = {'error': e.toString(), 'rawResponse': responseText};
      }

      final errorVal = parsed['error'];
      final hasError =
          errorVal != null &&
          errorVal != false &&
          (errorVal is! String || errorVal.trim().isNotEmpty);
      if (hasError) {
        final errorMsg = errorVal.toString();
        final errorResult = delegate.parseStepResult(
          parsed,
          'Error: $errorMsg',
        );
        results.add(errorResult);
        if (onStep != null) {
          onStep(errorResult, step);
        }
        break;
      }

      final isFinish = delegate.isFinishAction(parsed);
      if (isFinish) {
        final finishResult = delegate.parseStepResult(parsed, 'Finished.');
        results.add(finishResult);
        if (onStep != null) {
          onStep(finishResult, step);
        }
        break;
      }

      // Apply command to environment
      final stepFeedback = await delegate.applyAction(parsed);

      final stepResult = delegate.parseStepResult(parsed, stepFeedback);

      results.add(stepResult);
      if (onStep != null) {
        onStep(stepResult, step);
      }
    }

    return results;
  }
}

class AgentHistoryEntry {
  final DateTime timestamp;
  final String prompt;
  final String response;
  final bool isError;
  final Uint8List? imageBytes;
  final String imageMimeType;
  final String? modelName;
  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
  final double? estimatedCostUsd;

  AgentHistoryEntry({
    required this.timestamp,
    required this.prompt,
    required this.response,
    required this.isError,
    this.imageBytes,
    this.imageMimeType = 'image/bmp',
    this.modelName,
    this.inputTokens,
    this.outputTokens,
    int? totalTokens,
    this.estimatedCostUsd,
  }) : totalTokens =
           totalTokens ??
           (inputTokens != null && outputTokens != null
               ? inputTokens + outputTokens
               : null);

  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.toIso8601String(),
      'prompt': prompt,
      'response': response,
      'isError': isError,
      if (modelName != null) 'modelName': modelName,
      if (inputTokens != null) 'inputTokens': inputTokens,
      if (outputTokens != null) 'outputTokens': outputTokens,
      if (totalTokens != null) 'totalTokens': totalTokens,
      if (estimatedCostUsd != null) 'estimatedCostUsd': estimatedCostUsd,
      if (imageBytes != null)
        'image': {
          'mimeType': imageMimeType,
          'base64': base64Encode(imageBytes!),
        },
    };
  }

  factory AgentHistoryEntry.fromJson(Map<String, dynamic> json) {
    final imageMap = json['image'] as Map<String, dynamic>?;
    final inTokens = json['inputTokens'] as int?;
    final outTokens = json['outputTokens'] as int?;
    final totTokens =
        json['totalTokens'] as int? ??
        (inTokens != null && outTokens != null ? inTokens + outTokens : null);
    return AgentHistoryEntry(
      timestamp: DateTime.parse(json['timestamp'] as String),
      prompt: json['prompt'] as String,
      response: json['response'] as String,
      isError: json['isError'] as bool? ?? false,
      modelName: json['modelName'] as String?,
      inputTokens: inTokens,
      outputTokens: outTokens,
      totalTokens: totTokens,
      estimatedCostUsd: (json['estimatedCostUsd'] as num?)?.toDouble(),
      imageBytes: (imageMap != null && imageMap['base64'] is String)
          ? base64Decode(imageMap['base64'] as String)
          : null,
      imageMimeType: (imageMap != null && imageMap['mimeType'] is String)
          ? (imageMap['mimeType'] as String)
          : 'image/bmp',
    );
  }

  static String serializeList(List<AgentHistoryEntry> entries) {
    final list = entries.map((e) => e.toJson()).toList();
    return const JsonEncoder.withIndent('  ').convert(list);
  }
}
