package com.example.virtualstylus

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

class HardwareVideoPlayer(
    private val textureRegistry: TextureRegistry,
    private val onDimensionsChanged: (Int, Int) -> Unit
) {
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var workerThread: Thread? = null
    private var drainThread: Thread? = null
    private val running = AtomicBoolean(false)
    @Volatile private var activeSocket: Socket? = null
    @Volatile private var activeCodec: MediaCodec? = null

    private val currentWidth = AtomicInteger(0)
    private val currentHeight = AtomicInteger(0)
    private val currentFps = AtomicInteger(0)
    @Volatile private var currentCodecName: String = ""
    @Volatile private var currentDecoderName: String = ""
    private val mainHandler = Handler(Looper.getMainLooper())

    fun start(hostIp: String, port: Int = 4002): Long {
        stop()
        val entry = textureRegistry.createSurfaceTexture()
        textureEntry = entry
        surface = Surface(entry.surfaceTexture())
        running.set(true)

        workerThread = Thread({
            runReceiveLoop(hostIp, port)
        }, "HwVideoRecv").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
        return entry.id()
    }

    fun stop() {
        running.set(false)
        try { activeSocket?.close() } catch (_: Exception) {}
        activeSocket = null
        workerThread?.interrupt()
        drainThread?.interrupt()
        releaseCodec()
        try { surface?.release() } catch (_: Exception) {}
        surface = null
        try { textureEntry?.release() } catch (_: Exception) {}
        textureEntry = null
        currentFps.set(0)
    }

    fun getStats(): Map<String, Any> = mapOf(
        "fps" to currentFps.get(),
        "width" to currentWidth.get(),
        "height" to currentHeight.get(),
        "codec" to currentCodecName,
        "decoder" to currentDecoderName
    )

    private fun releaseCodec() {
        val c = activeCodec
        activeCodec = null
        if (c != null) {
            try { c.stop() } catch (_: Exception) {}
            try { c.release() } catch (_: Exception) {}
        }
    }

    private fun configureCodec(isHevc: Boolean, width: Int, height: Int, fps: Int): MediaCodec? {
        releaseCodec()
        val outSurface = surface ?: return null
        textureEntry?.surfaceTexture()?.setDefaultBufferSize(width, height)
        currentWidth.set(width)
        currentHeight.set(height)
        currentCodecName = if (isHevc) "H265" else "H264"
        mainHandler.post { onDimensionsChanged(width, height) }

        val mime = if (isHevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        val codec = MediaCodec.createDecoderByType(mime)
        currentDecoderName = codec.name
        val format = MediaFormat.createVideoFormat(mime, width, height)
        format.setInteger(MediaFormat.KEY_PRIORITY, 0)
        format.setInteger(MediaFormat.KEY_OPERATING_RATE, fps.coerceIn(30, 120))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        codec.configure(format, outSurface, null, 0)
        codec.start()
        activeCodec = codec

        drainThread?.interrupt()
        drainThread = Thread({
            drainOutputLoop(codec)
        }, "HwVideoDrain").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
        return codec
    }

    private fun drainOutputLoop(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var frameCount = 0
        var windowStart = System.nanoTime()
        while (running.get() && activeCodec === codec) {
            try {
                val outIndex = codec.dequeueOutputBuffer(info, 10_000)
                if (outIndex >= 0) {
                    // Render immediately to SurfaceTexture with zero playout delay.
                    codec.releaseOutputBuffer(outIndex, true)
                    frameCount++
                    val now = System.nanoTime()
                    val elapsedSec = (now - windowStart) / 1_000_000_000.0
                    if (elapsedSec >= 1.0) {
                        currentFps.set((frameCount / elapsedSec).toInt())
                        frameCount = 0
                        windowStart = now
                    }
                }
            } catch (_: Exception) {
                break
            }
        }
    }

    private fun readU16Le(input: DataInputStream): Int {
        val b0 = input.readUnsignedByte()
        val b1 = input.readUnsignedByte()
        return b0 or (b1 shl 8)
    }

    private fun readU32Le(input: DataInputStream): Int {
        val b0 = input.readUnsignedByte()
        val b1 = input.readUnsignedByte()
        val b2 = input.readUnsignedByte()
        val b3 = input.readUnsignedByte()
        return b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)
    }

    private fun runReceiveLoop(hostIp: String, port: Int) {
        val ptsCounter = AtomicLong(0L)
        while (running.get()) {
            var socket: Socket? = null
            try {
                socket = Socket()
                socket.tcpNoDelay = true
                socket.receiveBufferSize = 256 * 1024
                socket.connect(InetSocketAddress(hostIp, port), 3000)
                activeSocket = socket

                val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 65536))
                var payloadBuf = ByteArray(256 * 1024)

                while (running.get()) {
                    val pktType = input.readUnsignedByte()
                    if (pktType == 0x01) {
                        val codecId = input.readUnsignedByte()
                        val width = readU16Le(input)
                        val height = readU16Le(input)
                        val fps = readU16Le(input)
                        if (width > 0 && height > 0) {
                            configureCodec(codecId == 1, width, height, fps)
                        }
                    } else if (pktType == 0x02) {
                        val flags = input.readUnsignedByte()
                        val size = readU32Le(input)
                        if (size <= 0 || size > 16 * 1024 * 1024) break
                        if (payloadBuf.size < size) {
                            payloadBuf = ByteArray(size)
                        }
                        input.readFully(payloadBuf, 0, size)

                        val codec = activeCodec ?: continue
                        val inIndex = codec.dequeueInputBuffer(10_000)
                        if (inIndex >= 0) {
                            val inBuf = codec.getInputBuffer(inIndex)
                            if (inBuf != null) {
                                inBuf.clear()
                                inBuf.put(payloadBuf, 0, size)
                                val ptsUs = ptsCounter.incrementAndGet() * 16_666L
                                val codecFlags = if ((flags and 1) != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                                codec.queueInputBuffer(inIndex, 0, size, ptsUs, codecFlags)
                            }
                        }
                    } else {
                        break
                    }
                }
            } catch (_: Exception) {
                // Retry briefly if Windows is restarting the encoder on live reconfig.
                try { Thread.sleep(250) } catch (_: InterruptedException) { break }
            } finally {
                try { socket?.close() } catch (_: Exception) {}
                if (activeSocket === socket) activeSocket = null
            }
        }
        releaseCodec()
    }
}
