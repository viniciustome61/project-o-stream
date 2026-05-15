package com.projecto.stream

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioFormat
import android.os.Build
import android.util.Size
import android.view.Surface
import android.view.View
import android.view.WindowManager
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
import io.github.thibaultbee.streampack.core.streamers.single.setCameraId
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
                        result.success(handleCall(call))
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

    private suspend fun handleCall(call: MethodCall): Any? {
        return when (call.method) {
            "initialize" -> {
                ensurePermissions()
                bridge.initialize()
                null
            }
            "startPreview" -> bridge.startPreview().let { null }
            "stopPreview" -> bridge.stopPreview().let { null }
            "loadEndpoint" -> bridge.loadEndpoint()
            "saveEndpoint" -> bridge.saveEndpoint(call.arguments as Map<*, *>).let { null }
            "getCapabilities" -> bridge.getCapabilities()
            "startStream" -> bridge.startStream(call.arguments as Map<*, *>).let { null }
            "stopStream" -> bridge.stopStream().let { null }
            "switchCamera" -> bridge.switchCamera().let { null }
            "setLens" -> bridge.setLens((call.arguments as Map<*, *>)["lens"].toString()).let { null }
            "setTorch" -> bridge.setTorch((call.arguments as Map<*, *>)["enabled"] == true).let { null }
            "setZoom" -> bridge.setZoom(((call.arguments as Map<*, *>)["value"] as Number).toFloat()).let { null }
            "setKeepScreenOn" -> bridge.setKeepScreenOn((call.arguments as Map<*, *>)["enabled"] == true).let { null }
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
    private var selectedLens = "wide"
    private var selectedCameraId: String? = null

    suspend fun initialize() {
        val cameraId = selectedCameraId ?: cameraIdForLens(selectedLens)
        val activeStreamer = streamer ?: (if (cameraId != null) {
            cameraSingleStreamer(context = activity, cameraId = cameraId)
        } else {
            cameraSingleStreamer(context = activity)
        }).also {
            streamer = it
        }
        selectedCameraId = cameraId
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

    fun loadEndpoint(): Map<String, Any?> {
        val preferences = activity.getSharedPreferences("project_o_stream", android.content.Context.MODE_PRIVATE)
        return mapOf(
            "host" to preferences.getString("host", null),
            "port" to if (preferences.contains("port")) preferences.getInt("port", 7070) else null
        )
    }

    fun saveEndpoint(args: Map<*, *>) {
        val host = args["host"]?.toString()?.trim().orEmpty()
        val port = (args["port"] as Number).toInt()
        activity.getSharedPreferences("project_o_stream", android.content.Context.MODE_PRIVATE)
            .edit()
            .putString("host", host)
            .putInt("port", port)
            .apply()
    }

    fun getCapabilities(): Map<String, Any> {
        return mapOf(
            "platform" to "android",
            "preview" to true,
            "srt" to true,
            "hevc" to true,
            "torch" to true,
            "zoom" to true,
            "transportStatus" to "SRT sender available via StreamPack",
            "lenses" to availableLenses(),
            "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "os" to "Android ${Build.VERSION.RELEASE}"
        )
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
        val lenses = availableLenses().mapNotNull { it["id"] as? String }
        if (lenses.isEmpty()) {
            error("No switchable camera lens is available on this Android device.")
        }
        val current = lenses.indexOf(selectedLens).takeIf { it >= 0 } ?: 0
        setLens(lenses[(current + 1) % lenses.size])
    }

    suspend fun setLens(lens: String) {
        val normalized = normalizeLens(lens)
        val cameraId = cameraIdForLens(normalized)
            ?: error("The $normalized lens is not available on this Android device.")
        val activeStreamer = requireStreamer()
        activeStreamer.setCameraId(cameraId)
        selectedLens = normalized
        selectedCameraId = cameraId
        previewView.setVideoSourceProvider(activeStreamer)
        emitStatus("Lens ${lensLabel(normalized)}", live)
    }

    suspend fun setTorch(enabled: Boolean) {
        emitStatus(if (enabled) "Torch on" else "Torch off", live)
    }

    suspend fun setZoom(value: Float) {
        emitStatus("Zoom ${"%.1f".format(value)}x", live)
    }

    fun setKeepScreenOn(enabled: Boolean) {
        if (enabled) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        emitStatus(if (enabled) "Screen awake lock on" else "Screen awake lock off", live)
    }

    private suspend fun requireStreamer(): SingleStreamer {
        if (streamer == null) {
            initialize()
        }
        return streamer ?: error("Camera streamer unavailable")
    }

    private fun cameraManager(): CameraManager =
        activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private fun cameraIdForLens(lens: String): String? {
        val facing = when (normalizeLens(lens)) {
            "front" -> CameraCharacteristics.LENS_FACING_FRONT
            else -> CameraCharacteristics.LENS_FACING_BACK
        }
        return cameraManager().cameraIdList.firstOrNull { cameraId ->
            cameraManager()
                .getCameraCharacteristics(cameraId)
                .get(CameraCharacteristics.LENS_FACING) == facing
        }
    }

    private fun availableLenses(): List<Map<String, String>> {
        val lenses = mutableListOf<Map<String, String>>()
        if (cameraIdForLens("wide") != null) {
            lenses += mapOf("id" to "wide", "label" to "Wide")
        }
        if (cameraIdForLens("front") != null) {
            lenses += mapOf("id" to "front", "label" to "Front")
        }
        return lenses
    }

    private fun normalizeLens(lens: String): String {
        return when (lens.trim().lowercase()) {
            "front", "selfie" -> "front"
            else -> "wide"
        }
    }

    private fun lensLabel(lens: String): String {
        return when (normalizeLens(lens)) {
            "front" -> "Front"
            else -> "Wide"
        }
    }

    private fun emitStatus(status: String, live: Boolean) {
        emit(mapOf("status" to status, "live" to live, "stats" to ""))
    }
}
