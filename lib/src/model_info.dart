enum CloudProvider { gemini, zhipu }

class CloudModelInfo {
  final String modelName;
  final CloudProvider provider;
  final bool isVision;
  final int? limitRpm;
  final int? limitTpm;
  final int? limitRpd;
  final int? limitRps;
  final double inputPricePerMillion;
  final double outputPricePerMillion;
  final String description;

  const CloudModelInfo({
    required this.modelName,
    required this.provider,
    this.isVision = false,
    this.limitRpm,
    this.limitTpm,
    this.limitRpd,
    this.limitRps,
    this.inputPricePerMillion = 0.0,
    this.outputPricePerMillion = 0.0,
    required this.description,
  });
}
