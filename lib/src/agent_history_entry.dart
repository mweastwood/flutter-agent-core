import 'dart:convert';
import 'dart:typed_data';

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
