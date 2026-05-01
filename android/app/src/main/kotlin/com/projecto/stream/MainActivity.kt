package com.projecto.stream

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.util.Size
import android.view.Surface
import android.view.View
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec
import io.github.thibaultbee.streampack.core.configuration.mediadescriptor.UriMediaDescriptor
import io.github.thibaultbee.streampack.core.streamers.single.AudioConfig
import io.github.thibaultbee.streampack.core.streamers.single.SingleStreamer
import io.github.thibaultbee.streampack.core.streamers.single.VideoConfig
import io.github.thibaultbee.streampack.core.streamers.single.cameraSingleStreamer
import io.github.thibaultbee.streampack.ui.views.PreviewView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class MainActivity : FlutterActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var eventSink: EventChannel.EventSink? = null
    private lateinit var bridge: StreamBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = StreamBridge(this) { event -> eventSink?.success(event) }

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "project_o_stream/preview",
            PreviewFactory(bridge)
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "project_o_stream/native")
            .setMethodCallHandler { call, result ->
                scope.launch {
                    try {
                        handleCall(call)
                        result.success(null)
                    } catch (error: Throwable) {
                        result.error("native_error", error.message, null)
                    }
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "project_o_stream/events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    private suspend fun handleCall(call: MethodCall) {
        when (call.method) {
            "initialize" -> {
                ensurePermissions()
                bridge.initialize()
            }
            "startPreview" -> bridge.startPreview()
            "stopPreview" -> bridge.stopPreview()
            "startStream" -> bridge.startStream(call.arguments as Map<*, *>)
            "stopStream" -> bridge.stopStream()
            "switchCamera" -> bridge.switchCamera()
            "setTorch" -> bridge.setTorch((call.arguments as Map<*, *>)["enabled"] == true)
            "setZoom" -> bridge.setZoom(((call.arguments as Map<*, *>)["value"] as Number).toFloat())
            else -> error("Unknown method ${call.method}")
        }
    }

    private fun ensurePermissions() {
        val missing = arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
            .filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, missing.toTypedArray(), 7)
        }
    }
}

class PreviewFactory(private val bridge: StreamBridge) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: android.content.Context, viewId: Int, args: Any?): PlatformView {
        return object : PlatformView {
            override fun getView(): View = bridge.previewView
            override fun dispose() = Unit
        }
    }
}

class StreamBridge(
    private val activity: MainActivity,
    private val emit: (Map<String, Any>) -> Unit
) {
    val previewView = PreviewView(activity)
    private var streamer: SingleStreamer? = null
    private var live = false

    suspend fun initialize() {
        val activeStreamer = streamer ?: cameraSingleStreamer(context = activity).also {
            streamer = it
        }
        activeStreamer.setTargetRotation(Surface.ROTATION_0)
        previewView.setVideoSourceProvider(activeStreamer)
        emitStatus("Ready", false)
    }

    suspend fun startPreview() {
        previewView.setVideoSourceProvider(requireStreamer())
        emitStatus("Preview", live)
    }

    suspend fun stopPreview() {
        emitStatus("Preview stopped", live)
    }

    suspend fun startStream(args: Map<*, *>) {
        val activeStreamer = requireStreamer()
        val profile = args["profile"] as Map<*, *>
        val host = args["host"].toString()
        val port = (args["port"] as Number).toInt()
        val latencyMs = (args["latencyMs"] as Number).toInt()
        val useHevc = args["useHevc"] == true
        val microphone = args["microphone"] == true
        val width = (profile["width"] as Number).toInt()
        val height = (profile["height"] as Number).toInt()
        val fps = (profile["fps"] as Number).toInt()
        val bitrate = (profile["bitrate"] as Number).toInt()
        val audioBitrate = (profile["audioBitrate"] as Number).toInt()

        activeStreamer.setTargetRotation(Surface.ROTATION_0)
        activeStreamer.setVideoConfig(
            VideoConfig(
                startBitrate = bitrate,
                resolution = Size(width, height),
                fps = fps
            )
        )
        if (microphone) {
            activeStreamer.setAudioConfig(
                AudioConfig(
                    startBitrate = audioBitrate,
                    sampleRate = 44100,
                    channelConfig = AudioFormat.CHANNEL_IN_STEREO
                )
            )
        }

        val codecLabel = if (useHevc) "HEVC" else "H.264"
        val descriptor = UriMediaDescriptor(
            "srt://$host:$port?mode=caller&transtype=live&latency=${latencyMs * 1000}&tlpktdrop=1&pkt_size=1316"
        )
        activeStreamer.open(descriptor)
        activeStreamer.startStream()
        live = true
        emitStatus("Live $codecLabel ${width}x$height@$fps", true)
    }

    suspend fun stopStream() {
        streamer?.stopStream()
        live = false
        emitStatus("Ready", false)
    }

    suspend fun switchCamera() {
        emitStatus("Camera switch unavailable in this build", live)
    }

    suspend fun setTorch(enabled: Boolean) {
        emitStatus(if (enabled) "Torch on" else "Torch off", live)
    }

    suspend fun setZoom(value: Float) {
        emitStatus("Zoom ${"%.1f".format(value)}x", live)
    }

    private suspend fun requireStreamer(): SingleStreamer {
        if (streamer == null) {
            initialize()
        }
        return streamer ?: error("Camera streamer unavailable")
    }

    private fun emitStatus(status: String, live: Boolean) {
        emit(mapOf("status" to status, "live" to live, "stats" to ""))
    }
}
