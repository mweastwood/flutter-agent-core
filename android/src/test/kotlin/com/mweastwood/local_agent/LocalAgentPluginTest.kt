package com.mweastwood.local_agent

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test
import kotlin.test.assertIs
import kotlin.test.assertNotNull

/*
 * This demonstrates a simple unit test of the Kotlin portion of this plugin's implementation.
 *
 * Once you have built the plugin's example app, you can run these tests from the command
 * line by running `./gradlew testDebugUnitTest` in the `example/android/` directory, or
 * you can run them directly from IDEs that support JUnit such as Android Studio.
 */

internal class LocalAgentPluginTest {
    @Test
    fun testPluginInstantiation() {
        val plugin = LocalAgentPlugin()
        assertNotNull(plugin)
        assertIs<FlutterPlugin>(plugin)
        assertIs<MethodChannel.MethodCallHandler>(plugin)
    }

    @Test
    fun onMethodCall_setModelConfig_updatesPreferencesAndSucceeds() {
        val plugin = LocalAgentPlugin()
        val args = mapOf("releaseStage" to "preview", "preference" to "fast")
        val call = MethodCall("setModelConfig", args)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)

        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).success(null)
    }

    @Test
    fun onMethodCall_unknownMethod_invokesNotImplemented() {
        val plugin = LocalAgentPlugin()
        val call = MethodCall("nonExistentMethod", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)

        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).notImplemented()
    }

    @Test
    fun onMethodCall_countTokens_missingPrompt_returnsInvalidArgumentError() {
        val plugin = LocalAgentPlugin()
        val call = MethodCall("countTokens", emptyMap<String, Any>())
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)

        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).error("invalid_argument", "prompt is missing", null)
    }

    @Test
    fun onMethodCall_generateContent_missingPrompt_returnsInvalidArgumentError() {
        val plugin = LocalAgentPlugin()
        val call = MethodCall("generateContent", mapOf("temperature" to 0.7))
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)

        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).error("invalid_argument", "prompt is missing", null)
    }

    @Test
    fun onAttachedToEngine_and_onDetachedFromEngine_managesMethodCallHandler() {
        val plugin = LocalAgentPlugin()
        val mockBinding = Mockito.mock(FlutterPlugin.FlutterPluginBinding::class.java)
        val mockMessenger = Mockito.mock(BinaryMessenger::class.java)
        Mockito.`when`(mockBinding.binaryMessenger).thenReturn(mockMessenger)

        plugin.onAttachedToEngine(mockBinding)
        Mockito.verify(mockMessenger).setMessageHandler(Mockito.eq("com.mweastwood.local_agent"), Mockito.any())

        plugin.onDetachedFromEngine(mockBinding)
        Mockito.verify(mockMessenger).setMessageHandler("com.mweastwood.local_agent", null)
    }
}

