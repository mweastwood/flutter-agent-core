package com.mweastwood.local_agent

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.ImagePart
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** LocalAgentPlugin */
class LocalAgentPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val ioScope = CoroutineScope(Dispatchers.IO)

    private var releaseStage = "stable"
    private var preference = "full"

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "com.mweastwood.local_agent")
        channel.setMethodCallHandler(this)
    }

    private fun getModel(call: MethodCall): com.google.mlkit.genai.prompt.GenerativeModel {
        val reqStage = call.argument<String>("releaseStage") ?: releaseStage
        val reqPref = call.argument<String>("preference") ?: preference

        val modelConfigBuilder = com.google.mlkit.genai.prompt.ModelConfig.Builder()
        if (reqStage == "preview") {
            modelConfigBuilder.releaseStage = 1 // ModelReleaseStage.PREVIEW
        } else {
            modelConfigBuilder.releaseStage = 0 // ModelReleaseStage.STABLE
        }

        if (reqPref == "fast") {
            modelConfigBuilder.preference = 1 // ModelPreference.FAST
        } else {
            modelConfigBuilder.preference = 2 // ModelPreference.FULL
        }
        val modelConfig = modelConfigBuilder.build()

        val generationConfigBuilder = com.google.mlkit.genai.prompt.GenerationConfig.Builder()
        generationConfigBuilder.modelConfig = modelConfig
        val config = generationConfigBuilder.build()

        return Generation.getClient(config)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "setModelConfig" -> {
                val newStage = call.argument<String>("releaseStage")
                val newPreference = call.argument<String>("preference")
                if (newStage != null) {
                    releaseStage = newStage
                }
                if (newPreference != null) {
                    preference = newPreference
                }
                result.success(null)
            }
            "checkStatus" -> {
                val model = getModel(call)
                ioScope.launch {
                    try {
                        val status = model.checkStatus()
                        val statusStr = when (status) {
                            FeatureStatus.AVAILABLE -> "available"
                            FeatureStatus.DOWNLOADABLE -> "downloadable"
                            FeatureStatus.DOWNLOADING -> "downloading"
                            else -> "unavailable"
                        }
                        withContext(Dispatchers.Main) {
                            result.success(statusStr)
                        }
                    } catch (e: Exception) {
                        Log.e("LocalAgentPlugin", "Error checking status: ${e.message}", e)
                        withContext(Dispatchers.Main) {
                            result.success("unavailable")
                        }
                    }
                }
            }
            "triggerDownload" -> {
                val delayMs = call.argument<Number>("delayMs")?.toLong()
                val model = getModel(call)
                ioScope.launch {
                    try {
                        if (delayMs != null && delayMs > 0) {
                            kotlinx.coroutines.delay(delayMs)
                        }
                        model.download().collect { downloadStatus ->
                            Log.d("LocalAgentPlugin", "Download status: $downloadStatus")
                        }
                    } catch (e: Exception) {
                        Log.e("LocalAgentPlugin", "Error triggering download: ${e.message}", e)
                    }
                }
                result.success(null)
            }
            "countTokens" -> {
                val model = getModel(call)
                val promptText = call.argument<String>("prompt")
                val imageBytes = call.argument<ByteArray>("image")

                if (promptText == null) {
                    result.error("invalid_argument", "prompt is missing", null)
                    return
                }

                ioScope.launch {
                    var bitmap: Bitmap? = null
                    try {
                        bitmap = if (imageBytes != null && imageBytes.isNotEmpty()) {
                            BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
                        } else {
                            null
                        }

                        val countResponse = if (bitmap != null) {
                            model.countTokens(
                                generateContentRequest(ImagePart(bitmap), TextPart(promptText)) {}
                            )
                        } else {
                            model.countTokens(
                                generateContentRequest(TextPart(promptText)) {}
                            )
                        }

                        withContext(Dispatchers.Main) {
                            result.success(countResponse.totalTokens)
                        }
                    } catch (e: Throwable) {
                        Log.e("LocalAgentPlugin", "Error counting tokens: ${e.message}", e)
                        withContext(Dispatchers.Main) {
                            result.error("token_counting_failed", e.message, null)
                        }
                    } finally {
                        bitmap?.recycle()
                    }
                }
            }
            "generateContent" -> {
                val model = getModel(call)
                val promptText = call.argument<String>("prompt")
                val imageBytes = call.argument<ByteArray>("image")
                val temperature = call.argument<Double>("temperature")?.toFloat() ?: 0.7f
                // The ML Kit GenAI Prompt API for on-device Gemini Nano enforces that maxOutputTokens
                // must be between 1 and 256. Values outside this range will trigger an exception on device.
                // We default to 256 if unspecified, and coerce any provided value to this range.
                val maxOutputTokens = call.argument<Int>("maxOutputTokens")?.coerceIn(1, 256) ?: 256

                if (promptText == null) {
                    result.error("invalid_argument", "prompt is missing", null)
                    return
                }

                ioScope.launch {
                    var bitmap: Bitmap? = null
                    try {
                        bitmap = if (imageBytes != null && imageBytes.isNotEmpty()) {
                            BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
                        } else {
                            null
                        }

                        val response = if (bitmap != null) {
                            model.generateContent(
                                generateContentRequest(ImagePart(bitmap), TextPart(promptText)) {
                                    this.temperature = temperature
                                    this.maxOutputTokens = maxOutputTokens
                                }
                            )
                        } else {
                            model.generateContent(
                                generateContentRequest(TextPart(promptText)) {
                                    this.temperature = temperature
                                    this.maxOutputTokens = maxOutputTokens
                                }
                            )
                        }

                        val candidate = response.candidates.firstOrNull()
                        val responseText = candidate?.text ?: ""
                        val isTruncated = candidate?.finishReason == com.google.mlkit.genai.prompt.Candidate.FinishReason.MAX_TOKENS

                        withContext(Dispatchers.Main) {
                            result.success(mapOf(
                                "text" to responseText,
                                "isTruncated" to isTruncated
                            ))
                        }
                    } catch (e: Throwable) {
                        Log.e("LocalAgentPlugin", "Error generating content: ${e.message}", e)
                        withContext(Dispatchers.Main) {
                            result.error("generation_failed", e.message, null)
                        }
                    } finally {
                        bitmap?.recycle()
                    }
                }
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}
