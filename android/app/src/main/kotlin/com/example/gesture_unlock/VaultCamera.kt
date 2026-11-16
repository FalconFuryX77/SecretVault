package com.example.gesture_unlock

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Range
import android.util.Size
import android.view.OrientationEventListener
import android.view.Surface
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/**
 * The in-vault camera (channel `app.vault/camera`). Photos are captured into
 * memory, stripped of metadata ([JpegClean]) and handed to the vault; they
 * never touch storage. Videos are encrypted as they're recorded, exactly
 * like hidden audio recordings ([VideoRecorder] writes [RecordingFormat] v2
 * to the vault's public key), and move into the vault through [Mp4Exporter].
 *
 * The preview is a Flutter texture inside the app's own window, which is
 * screenshot-protected while the vault is open.
 */
class VaultCamera(private val activity: Activity, private val textures: TextureRegistry) {
    companion object {
        /** The staged video being written; never offered for import. */
        @Volatile var activeFile: File? = null
    }

    private val main = Handler(Looper.getMainLooper())
    private val ops = Executors.newSingleThreadExecutor()
    private val cbThread = HandlerThread("camera-cb").apply { start() }
    private val cb = Handler(cbThread.looper)
    private val cbExecutor = Executor { cb.post(it) }
    private val manager = activity.getSystemService(CameraManager::class.java)

    private var producer: TextureRegistry.SurfaceProducer? = null
    private var previewSurface: Surface? = null
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var chars: CameraCharacteristics? = null
    private var front = false
    private var videoMode = false
    private var videoSize = Size(1280, 720)
    private var jpeg: ImageReader? = null
    private var torch = false
    private var recorder: VideoRecorder? = null

    @Volatile private var deviceOrientation = 0
    private val orientationListener = object : OrientationEventListener(activity) {
        override fun onOrientationChanged(o: Int) {
            if (o != ORIENTATION_UNKNOWN) deviceOrientation = o
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> op(result) { open(call.argument<Boolean>("front") == true, call.argument<Boolean>("video") == true) }
            "photo" -> op(result) { photo() }
            "startVideo" -> op(result) { startVideo(call.argument<ByteArray>("key")!!, call.argument<Boolean>("audio") == true) }
            "stopVideo" -> op(result) { stopVideo() }
            "torch" -> op(result) { setTorch(call.argument<Boolean>("on") == true) }
            "close" -> op(result) {
                closeAll()
                true
            }
            else -> result.notImplemented()
        }
    }

    /** Runs [block] on the camera's own thread, one operation at a time. */
    private fun op(result: MethodChannel.Result, block: () -> Any?) {
        ops.execute {
            try {
                val v = block()
                main.post { result.success(v) }
            } catch (e: Throwable) {
                main.post { result.error("camera", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun <T> onMain(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val latch = CountDownLatch(1)
        var value: T? = null
        var err: Throwable? = null
        main.post {
            try {
                value = block()
            } catch (e: Throwable) {
                err = e
            } finally {
                latch.countDown()
            }
        }
        check(latch.await(5, TimeUnit.SECONDS)) { "the app is busy" }
        err?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return value as T
    }

    // ─── Opening ───────────────────────────────────────────────────

    private fun open(wantFront: Boolean, video: Boolean): Map<String, Any> {
        if (activity.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            throw IllegalStateException("camera permission missing")
        }
        stopRecordingIfAny()
        closeCamera()
        val ids = manager.cameraIdList
        val facing = if (wantFront) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        val id = ids.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == facing }
            ?: ids.firstOrNull() ?: throw IllegalStateException("no camera")
        val c = manager.getCameraCharacteristics(id)
        chars = c
        front = c.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT
        videoMode = video
        val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: throw IllegalStateException("camera has no stream configuration")
        val previews = map.getOutputSizes(SurfaceTexture::class.java)
        val preview: Size
        if (video) {
            videoSize = pickVideoSize(map.getOutputSizes(MediaCodec::class.java) ?: previews)
            preview = pick(previews, videoSize.width.toDouble() / videoSize.height, 1920 * 1080)
        } else {
            val still = pick(map.getOutputSizes(ImageFormat.JPEG), 4.0 / 3, 12_600_000)
            preview = pick(previews, still.width.toDouble() / still.height, 1440 * 1080)
            jpeg = ImageReader.newInstance(still.width, still.height, ImageFormat.JPEG, 2)
        }
        val p = onMain { producer ?: textures.createSurfaceProducer().also { producer = it } }
        val surface = onMain {
            p.setSize(preview.width, preview.height)
            p.surface
        }
        previewSurface = surface
        device = openDevice(id)
        startSession(listOfNotNull(surface, jpeg?.surface))
        repeatPreview(record = false)
        onMain { orientationListener.enable() }
        val facings = ids.mapNotNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) }.toSet()
        return mapOf(
            "textureId" to p.id(),
            "width" to preview.width,
            "height" to preview.height,
            "sensorOrientation" to (c.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90),
            "handlesRotation" to onMain { p.handlesCropAndRotation() },
            "front" to front,
            "canSwitch" to (CameraCharacteristics.LENS_FACING_FRONT in facings && CameraCharacteristics.LENS_FACING_BACK in facings),
            "hasFlash" to (c.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true),
            "video" to video,
        )
    }

    /** The largest size near [aspect] with at most [maxPixels] pixels. */
    private fun pick(sizes: Array<Size>?, aspect: Double, maxPixels: Int): Size {
        val all = sizes?.toList().orEmpty()
        require(all.isNotEmpty()) { "camera offers no sizes" }
        val fits = all.filter { it.width.toLong() * it.height <= maxPixels }
        val near = fits.filter { abs(it.width.toDouble() / it.height - aspect) < 0.02 }
        return (near.ifEmpty { fits }.ifEmpty { listOf(all.minBy { it.width.toLong() * it.height }) })
            .maxBy { it.width.toLong() * it.height }
    }

    private fun pickVideoSize(sizes: Array<Size>): Size {
        val caps = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { it.isEncoder && it.supportedTypes.any { t -> t.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) } }
            .map { it.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).videoCapabilities }
        fun encodable(s: Size) = caps.any { it.isSizeSupported(s.width, s.height) }
        val ok = sizes.filter { encodable(it) && it.width.toLong() * it.height <= 1920L * 1080 }
        for (want in listOf(Size(1920, 1080), Size(1280, 720))) if (want in ok) return want
        val wide = ok.filter { abs(it.width.toDouble() / it.height - 16.0 / 9) < 0.02 }
        return wide.ifEmpty { ok }.maxByOrNull { it.width.toLong() * it.height }
            ?: throw IllegalStateException("no video size this phone can encode")
    }

    @SuppressLint("MissingPermission")
    private fun openDevice(id: String): CameraDevice {
        val latch = CountDownLatch(1)
        var dev: CameraDevice? = null
        var err: String? = null
        manager.openCamera(id, object : CameraDevice.StateCallback() {
            override fun onOpened(d: CameraDevice) {
                dev = d
                latch.countDown()
            }

            override fun onDisconnected(d: CameraDevice) {
                d.close()
                if (dev == null) {
                    err = "the camera is in use by another app"
                    latch.countDown()
                }
            }

            override fun onError(d: CameraDevice, error: Int) {
                d.close()
                if (dev == null) {
                    err = "the camera failed to open ($error)"
                    latch.countDown()
                }
            }
        }, cb)
        check(latch.await(10, TimeUnit.SECONDS)) { "the camera didn't open" }
        return dev ?: throw IllegalStateException(err ?: "the camera didn't open")
    }

    private fun startSession(outputs: List<Surface>) {
        val d = device ?: throw IllegalStateException("camera closed")
        session?.close()
        session = null
        val latch = CountDownLatch(1)
        var s: CameraCaptureSession? = null
        val callback = object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(cs: CameraCaptureSession) {
                s = cs
                latch.countDown()
            }

            override fun onConfigureFailed(cs: CameraCaptureSession) {
                latch.countDown()
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            d.createCaptureSession(
                SessionConfiguration(SessionConfiguration.SESSION_REGULAR, outputs.map { OutputConfiguration(it) }, cbExecutor, callback),
            )
        } else {
            @Suppress("DEPRECATION")
            d.createCaptureSession(outputs, callback, cb)
        }
        check(latch.await(10, TimeUnit.SECONDS)) { "the camera session didn't start" }
        session = s ?: throw IllegalStateException("the camera session failed")
    }

    private fun afMode(video: Boolean): Int? {
        val modes = chars?.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES) ?: return null
        val want = if (video) CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO else CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
        return want.takeIf { it in modes }
    }

    private fun fpsRange(): Range<Int>? =
        chars?.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?.filter { it.upper == 30 }
            ?.maxByOrNull { it.lower }

    private fun repeatPreview(record: Boolean, extra: Surface? = null) {
        val d = device ?: return
        val s = session ?: return
        val b = d.createCaptureRequest(if (record) CameraDevice.TEMPLATE_RECORD else CameraDevice.TEMPLATE_PREVIEW)
        previewSurface?.let { b.addTarget(it) }
        extra?.let { b.addTarget(it) }
        b.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
        afMode(videoMode)?.let { b.set(CaptureRequest.CONTROL_AF_MODE, it) }
        if (videoMode) fpsRange()?.let { b.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
        if (torch) b.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_TORCH)
        s.setRepeatingRequest(b.build(), null, cb)
    }

    private fun setTorch(on: Boolean): Boolean {
        torch = on && chars?.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        repeatPreview(record = recorder != null, extra = recorder?.inputSurface)
        return torch
    }

    /** How far to turn a capture so it's upright for the phone as it's held. */
    private fun captureRotation(): Int {
        val sensor = chars?.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        var device = (deviceOrientation + 45) / 90 * 90 % 360
        if (front) device = -device
        return (sensor + device + 360) % 360
    }

    // ─── Photos ────────────────────────────────────────────────────

    private fun photo(): Map<String, Any> {
        val r = jpeg ?: throw IllegalStateException("not in photo mode")
        val d = device ?: throw IllegalStateException("camera closed")
        val s = session ?: throw IllegalStateException("camera closed")
        val latch = CountDownLatch(1)
        var bytes: ByteArray? = null
        r.setOnImageAvailableListener({ reader ->
            val img = reader.acquireNextImage()
            if (img != null) {
                try {
                    val buf = img.planes[0].buffer
                    bytes = ByteArray(buf.remaining()).also { buf.get(it) }
                } finally {
                    img.close()
                    latch.countDown()
                }
            }
        }, cb)
        val b = d.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
        b.addTarget(r.surface)
        previewSurface?.let { b.addTarget(it) }
        b.set(CaptureRequest.JPEG_ORIENTATION, captureRotation())
        b.set(CaptureRequest.JPEG_QUALITY, 92.toByte())
        afMode(false)?.let { b.set(CaptureRequest.CONTROL_AF_MODE, it) }
        if (torch) b.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_TORCH)
        s.capture(b.build(), null, cb)
        check(latch.await(10, TimeUnit.SECONDS)) { "the photo didn't arrive" }
        r.setOnImageAvailableListener(null, null)
        val raw = bytes ?: throw IllegalStateException("the photo was empty")
        val clean = JpegClean.clean(raw)
        raw.fill(0)
        return mapOf("data" to clean, "width" to r.width, "height" to r.height)
    }

    // ─── Video ─────────────────────────────────────────────────────

    private fun startVideo(key: ByteArray, audio: Boolean): Map<String, Any> {
        check(videoMode) { "not in video mode" }
        check(recorder == null) { "already recording" }
        val surface = previewSurface ?: throw IllegalStateException("camera closed")
        val bootClock = chars?.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE) ==
            CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME
        // Never take the microphone from a hidden recording in progress.
        val mic = audio && !RecorderService.recording &&
            activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val rec = VideoRecorder(RecorderService.stagingDir(activity), key, videoSize, captureRotation(), mic, bootClock)
        activeFile = rec.file
        try {
            rec.prepare()
            startSession(listOf(surface, rec.inputSurface))
            repeatPreview(record = true, extra = rec.inputSurface)
            rec.start()
        } catch (e: Throwable) {
            rec.abort()
            activeFile = null
            try {
                startSession(listOf(surface))
                repeatPreview(record = false)
            } catch (_: Throwable) {
            }
            throw e
        }
        recorder = rec
        return mapOf("id" to rec.file.name, "audio" to rec.hasAudio, "width" to videoSize.width, "height" to videoSize.height)
    }

    private fun stopVideo(): Map<String, Any?>? {
        val rec = recorder ?: return null
        recorder = null
        try {
            session?.stopRepeating()
            session?.abortCaptures()
        } catch (_: Exception) {
        }
        session?.close()
        session = null
        val error = rec.stop()
        activeFile = null
        try {
            previewSurface?.let { startSession(listOf(it)) }
            repeatPreview(record = false)
        } catch (_: Exception) {
            // The camera went away meanwhile; the video is saved regardless.
        }
        return mapOf("id" to rec.file.name, "durationMs" to rec.durationMs, "error" to error)
    }

    private fun stopRecordingIfAny() {
        val rec = recorder ?: return
        recorder = null
        try {
            session?.stopRepeating()
        } catch (_: Exception) {
        }
        session?.close()
        session = null
        rec.stop()
        activeFile = null
    }

    // ─── Closing ───────────────────────────────────────────────────

    private fun closeCamera() {
        try {
            session?.close()
        } catch (_: Exception) {
        }
        session = null
        try {
            device?.close()
        } catch (_: Exception) {
        }
        device = null
        jpeg?.close()
        jpeg = null
        torch = false
    }

    /** Stops any video (it's kept, encrypted), closes the camera and the texture. */
    fun closeAll() {
        stopRecordingIfAny()
        closeCamera()
        previewSurface = null
        onMain {
            orientationListener.disable()
            producer?.release()
            producer = null
        }
    }

    /** From MainActivity.onDestroy: off the main thread, don't wait for it. */
    fun shutdown() {
        ops.execute {
            try {
                closeAll()
            } catch (_: Throwable) {
            }
        }
    }
}

/**
 * Camera frames (through an encoder input surface) and the microphone →
 * H.264 + AAC → encrypted records (see [RecordingFormat] and [MediaScan]),
 * about a second at a time.
 */
class VideoRecorder(
    private val dir: File,
    private val vaultKey: ByteArray,
    private val size: Size,
    private val rotation: Int,
    private val wantAudio: Boolean,
    /** Whether camera timestamps run on the boot clock (else monotonic). */
    private val bootClock: Boolean,
) {
    companion object {
        const val VIDEO_TRACK = 1
        const val AUDIO_TRACK = 2
        const val SAMPLE_RATE = 44100

        /** Stop while there's still room to move the video into the vault. */
        const val SPARE_BYTES = 300L * 1024 * 1024
    }

    val file = File(dir, ByteArray(12).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) } + ".bin")
    lateinit var inputSurface: Surface
        private set
    var hasAudio = false
        private set

    private lateinit var writer: SegmentWriter
    private lateinit var video: MediaCodec
    private var audio: MediaCodec? = null
    private var mic: AudioRecord? = null
    private var drain: Thread? = null
    private var audioThread: Thread? = null
    @Volatile private var stopping = false
    @Volatile private var error: String? = null
    private var firstPts = -1L
    private var lastPts = -1L

    val durationMs: Long get() = if (firstPts < 0) 0 else (lastPts - firstPts) / 1000

    fun prepare() {
        writer = SegmentWriter(file, vaultKey)
        writer.pending.write(ByteBuffer.allocate(9).put(RecordingFormat.REC_START.toByte()).putLong(System.currentTimeMillis()).array())
        val f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, size.width, size.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, (size.width * size.height * 4).coerceIn(2_000_000, 12_000_000))
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            // A key frame every second: quick seeking, and little lost if cut.
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
        }
        video = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        video.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = video.createInputSurface()
        if (wantAudio) prepareAudio()
    }

    @SuppressLint("MissingPermission")
    private fun prepareAudio() {
        try {
            val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            val rec = AudioRecord(
                MediaRecorder.AudioSource.CAMCORDER,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf * 4, 16384),
            )
            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                rec.release()
                return
            }
            val f = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, 96000)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
            }
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            enc.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            mic = rec
            audio = enc
            hasAudio = true
        } catch (_: Exception) {
            hasAudio = false
        }
    }

    fun start() {
        video.start()
        audio?.start()
        mic?.startRecording()
        drain = Thread({ drainLoop() }, "video-writer").apply { start() }
        if (hasAudio) audioThread = Thread({ audioLoop() }, "video-audio").apply { start() }
    }

    private fun clockNanos(): Long = if (bootClock) SystemClock.elapsedRealtimeNanos() else System.nanoTime()

    private fun audioLoop() {
        val rec = mic ?: return
        val enc = audio ?: return
        val pcm = ByteArray(4096)
        val ts = AudioTimestamp()
        val base = if (bootClock) AudioTimestamp.TIMEBASE_BOOTTIME else AudioTimestamp.TIMEBASE_MONOTONIC
        var frames = 0L
        var lastUs = 0L
        try {
            while (true) {
                if (stopping) {
                    val idx = enc.dequeueInputBuffer(100_000)
                    if (idx >= 0) {
                        enc.queueInputBuffer(idx, 0, 0, lastUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        break
                    }
                    continue
                }
                val n = rec.read(pcm, 0, pcm.size)
                if (n < 0) throw IllegalStateException("microphone read failed ($n)")
                if (n == 0) continue
                var startNs = clockNanos() - n / 2 * 1_000_000_000L / SAMPLE_RATE
                if (rec.getTimestamp(ts, base) == AudioRecord.SUCCESS) {
                    startNs = ts.nanoTime + (frames - ts.framePosition) * 1_000_000_000L / SAMPLE_RATE
                }
                frames += n / 2
                lastUs = startNs / 1000
                val idx = enc.dequeueInputBuffer(100_000)
                if (idx >= 0) {
                    val buf = enc.getInputBuffer(idx)!!
                    buf.clear()
                    val take = minOf(n, buf.remaining())
                    buf.put(pcm, 0, take)
                    enc.queueInputBuffer(idx, 0, take, lastUs, 0)
                }
            }
        } catch (e: Throwable) {
            if (error == null) error = "audio: ${e.message}"
            stopping = true
        }
    }

    private fun drainLoop() {
        val info = MediaCodec.BufferInfo()
        var videoDone = false
        var audioDone = !hasAudio
        var lastSpace = 0L
        var deadline = Long.MAX_VALUE
        try {
            while (!(videoDone && audioDone)) {
                if (!videoDone) videoDone = drainOne(video, VIDEO_TRACK, info)
                val a = audio
                if (!audioDone && a != null) audioDone = drainOne(a, AUDIO_TRACK, info)
                if (writer.pending.size() >= 512 * 1024 || writer.due()) writer.flush()
                val now = SystemClock.elapsedRealtime()
                if (!stopping && now - lastSpace > 5000) {
                    lastSpace = now
                    if (dir.usableSpace < writer.written + SPARE_BYTES) {
                        error = "storage almost full"
                        requestStop()
                    }
                }
                if (stopping && deadline == Long.MAX_VALUE) deadline = now + 5000
                // An encoder that never reports the end mustn't hold the file open.
                if (now > deadline) break
            }
        } catch (e: Throwable) {
            if (error == null) error = e.message ?: e.toString()
        } finally {
            try {
                writer.finish()
            } catch (_: Throwable) {
            }
            release()
        }
    }

    /** One output buffer of [codec]; true once its stream has ended. */
    private fun drainOne(codec: MediaCodec, track: Int, info: MediaCodec.BufferInfo): Boolean {
        val idx = codec.dequeueOutputBuffer(info, 5_000)
        if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
            writeTrack(track, codec.outputFormat)
            return false
        }
        if (idx < 0) return false
        val buf = codec.getOutputBuffer(idx)
        if (buf != null && info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
            val raw = ByteArray(info.size)
            buf.position(info.offset)
            buf.get(raw)
            val data = if (track == VIDEO_TRACK) Mp4Writer.toLengthPrefixed(raw, 0, raw.size) else raw
            val key = track == AUDIO_TRACK || info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
            writer.pending.write(
                ByteBuffer.allocate(15).put(RecordingFormat.REC_SAMPLE.toByte()).put(track.toByte())
                    .put(if (key) 1 else 0).putLong(info.presentationTimeUs).putInt(data.size).array(),
            )
            writer.pending.write(data)
            if (track == VIDEO_TRACK) {
                if (firstPts < 0) firstPts = info.presentationTimeUs
                lastPts = maxOf(lastPts, info.presentationTimeUs)
            }
            raw.fill(0)
            if (data !== raw) data.fill(0)
        }
        codec.releaseOutputBuffer(idx, false)
        return info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
    }

    private fun writeTrack(track: Int, f: MediaFormat) {
        val isVideo = track == VIDEO_TRACK
        val csd = listOf("csd-0", "csd-1").mapNotNull { k ->
            f.getByteBuffer(k)?.let { b -> ByteArray(b.remaining()).also { b.duplicate().get(it) } }
        }
        val mime = (if (isVideo) MediaFormat.MIMETYPE_VIDEO_AVC else MediaFormat.MIMETYPE_AUDIO_AAC).toByteArray()
        val a = if (isVideo) f.getInteger(MediaFormat.KEY_WIDTH) else f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val b = if (isVideo) f.getInteger(MediaFormat.KEY_HEIGHT) else f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val out = ByteArrayOutputStream()
        out.write(
            ByteBuffer.allocate(1 + 1 + 1 + 2).put(RecordingFormat.REC_TRACK.toByte()).put(track.toByte())
                .put(if (isVideo) 2 else 1).putShort(mime.size.toShort()).array(),
        )
        out.write(mime)
        out.write(ByteBuffer.allocate(4 + 4 + 2 + 1).putInt(a).putInt(b).putShort((if (isVideo) rotation else 0).toShort()).put(csd.size.toByte()).array())
        for (c in csd) {
            out.write(ByteBuffer.allocate(4).putInt(c.size).array())
            out.write(c)
        }
        writer.pending.write(out.toByteArray())
    }

    private fun requestStop() {
        if (stopping) return
        stopping = true
        try {
            video.signalEndOfInputStream()
        } catch (_: Exception) {
        }
    }

    /** Finishes the file. Returns why recording ended early, if it did. */
    fun stop(): String? {
        requestStop()
        audioThread?.join(3000)
        drain?.join(10_000)
        return error
    }

    /** Before [start] succeeded: undo everything, leave no file. */
    fun abort() {
        stopping = true
        try {
            if (::writer.isInitialized) writer.finish()
        } catch (_: Throwable) {
        }
        release()
        RecordingFormat.shred(file)
    }

    private fun release() {
        try {
            mic?.stop()
        } catch (_: Throwable) {
        }
        mic?.release()
        mic = null
        for (c in listOfNotNull(if (::video.isInitialized) video else null, audio)) {
            try {
                c.stop()
            } catch (_: Throwable) {
            }
            try {
                c.release()
            } catch (_: Throwable) {
            }
        }
        audio = null
        if (::inputSurface.isInitialized) inputSurface.release()
    }
}
