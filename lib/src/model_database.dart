export 'model_info.dart';

import 'model_info.dart';
import 'models/gemini_models.dart';
import 'models/zhipu_models.dart';

class CloudModelDatabase {
  static const List<CloudModelInfo> geminiModels = kGeminiModels;
  static const List<CloudModelInfo> zhipuModels = kZhipuModels;

  static final Map<String, CloudModelInfo> _modelsMap = {
    for (final model in [...geminiModels, ...zhipuModels])
      model.modelName: model,
  };

  /// Query which models are available, optionally filtering by provider and vision support.
  static List<CloudModelInfo> getAvailableModels({
    CloudProvider? provider,
    bool? isVision,
  }) {
    Iterable<CloudModelInfo> list;
    if (provider == CloudProvider.gemini) {
      list = geminiModels;
    } else if (provider == CloudProvider.zhipu) {
      list = zhipuModels;
    } else {
      list = [...geminiModels, ...zhipuModels];
    }
    if (isVision != null) {
      list = list.where((m) => m.isVision == isVision);
    }
    return list.toList();
  }

  /// Query model names, optionally filtering by provider and vision support.
  static List<String> getAvailableModelNames({
    CloudProvider? provider,
    bool? isVision,
  }) {
    return getAvailableModels(
      provider: provider,
      isVision: isVision,
    ).map((m) => m.modelName).toList();
  }

  /// Retrieve model details/limits by name in O(1) time.
  static CloudModelInfo? getModelInfo(String modelName) {
    return _modelsMap[modelName];
  }

  /// Calculates estimated cost in USD for given input and output token counts.
  static double calculateEstimatedCost(
    String? modelName, {
    required int inputTokens,
    required int outputTokens,
  }) {
    if (modelName == null) return 0.0;
    final info = getModelInfo(modelName);
    if (info == null) return 0.0;
    final inputCost = (inputTokens / 1000000.0) * info.inputPricePerMillion;
    final outputCost = (outputTokens / 1000000.0) * info.outputPricePerMillion;
    return inputCost + outputCost;
  }
}
