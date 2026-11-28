package com.example.virtualstylus

import android.media.MediaCodecList
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val DEVICE_CHANNEL = "com.virtualstylus/device"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getHardwareDecoders") {
                    result.success(getHardwareDecoders())
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun getHardwareDecoders(): Map<String, Boolean> {
        val mimeMap = mapOf(
            "h264" to "video/avc",
            "h265" to "video/hevc",
            "vp8" to "video/x-vnd.on2.vp8",
            "vp9" to "video/x-vnd.on2.vp9",
            "av1" to "video/av01"
        )
        val result = mutableMapOf(
            "h264" to false,
            "h265" to false,
            "vp8" to false,
            "vp9" to false,
            "av1" to false
        )

        try {
            val codecList = MediaCodecList(MediaCodecList.ALL_CODECS)
            for (info in codecList.codecInfos) {
                if (info.isEncoder) continue
                val isHardware = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    info.isHardwareAccelerated
                } else {
                    val lowerName = info.name.lowercase()
                    !lowerName.startsWith("omx.google.") &&
                        !lowerName.startsWith("c2.android.") &&
                        !lowerName.contains(".sw.")
                }
                if (!isHardware) continue

                for (type in info.supportedTypes) {
                    val lowerType = type.lowercase()
                    for ((key, mime) in mimeMap) {
                        if (lowerType == mime) {
                            result[key] = true
                        }
                    }
                }
            }
        } catch (_: Exception) {
            // Fall back to false map if MediaCodecList is unavailable.
        }

        return result
    }
}
