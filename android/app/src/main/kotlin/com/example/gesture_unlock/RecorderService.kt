package com.example.gesture_unlock

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import java.io.File
import java.security.SecureRandom

/**
 * Records audio into encrypted files (see [RecordingFormat]), either on
 * request from the vault screen or, while *armed*, when volume-down is
 * pressed three times quickly with the screen off.
 *
 * How the screen-off trigger works: while the screen is off, this service
 * holds a media session that reports "playing to a remote device". Android
 * then routes volume keys to it instead of the phone's own volume (as long
 * as nothing else is playing sound), and [onVolumeDown] counts the presses.
 * When the screen turns on, the session goes inactive, so the volume keys
 * behave normally while you use the phone.
 *
 * It runs as a foreground service of type microphone: Android only lets an
 * app use the microphone from the background if that service was started
 * while the app was on screen, which is why arming happens inside the vault.
 * It is not restarted after it's killed or the phone reboots; it has to be
 * armed again.
 */
class RecorderService : Service() {
    companion object {
        const val ACTION_ARM = "arm"
        const val ACTION_DISARM = "disarm"
        const val ACTION_RECORD = "record"
        const val ACTION_STOP = "stop"
        const val EXTRA_KEY = "key"
        const val EXTRA_VIBRATE = "vibrate"
        const val EXTRA_ALWAYS_LISTEN = "alwaysListen"

        /** Tests only: start a new file after this many frames. */
        const val EXTRA_ROTATE_FRAMES = "rotateFrames"

        private const val NOTIFICATION_ID = 7
        private const val CHANNEL_ID = "background"
        private const val PRESS_WINDOW_MS = 1500L

        @Volatile var armed = false
        @Volatile var recording = false
        @Volatile var startedAtMs = 0L
        @Volatile var activeFile: File? = null
        @Volatile var lastError: String? = null
        @Volatile var triggers = 0

        /** Whether a service instance exists (stop/disarm only make sense then). */
        @Volatile var running = false

        /** Short hashes of the keys in use, so each vault sees only its own state. */
        @Volatile var armedKeyId: String? = null
        @Volatile var recordingKeyId: String? = null

        fun keyId(key: ByteArray): String =
            java.security.MessageDigest.getInstance("SHA-256").digest(key).take(8)
                .joinToString("") { "%02x".format(it) }

        fun stagingDir(ctx: Context): File = File(ctx.noBackupFilesDir, "media_cache").apply { mkdirs() }
    }

    private var armedKey: ByteArray? = null
    private var vibrate = true
    private var alwaysListen = false
    private var session: MediaSession? = null
    private var screenReceiver: BroadcastReceiver? = null
    private var worker: RecorderThread? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val presses = ArrayDeque<Long>()
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private var destroyed = false
    private var rotateFrames = RecorderThread.FRAMES_PER_FILE

    override fun onCreate() {
        super.onCreate()
        running = true
    }

    /** Debug builds only: release builds log nothing about the recorder. */
    private fun debug(msg: String) {
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            android.util.Log.d("rec", msg)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_ARM -> {
                if (!goForeground()) return START_NOT_STICKY
                armedKey = intent.getByteArrayExtra(EXTRA_KEY)
                vibrate = intent.getBooleanExtra(EXTRA_VIBRATE, true)
                alwaysListen = intent.getBooleanExtra(EXTRA_ALWAYS_LISTEN, false)
                armed = armedKey != null
                armedKeyId = armedKey?.let { keyId(it) }
                if (armed) listenForTrigger() else stopIfIdle()
            }
            ACTION_DISARM -> {
                armed = false
                armedKey = null
                armedKeyId = null
                stopListening()
                stopIfIdle()
            }
            ACTION_RECORD -> {
                if (!goForeground()) return START_NOT_STICKY
                rotateFrames = intent.getIntExtra(EXTRA_ROTATE_FRAMES, RecorderThread.FRAMES_PER_FILE)
                val key = intent.getByteArrayExtra(EXTRA_KEY)
                if (key == null || !startRecording(key)) stopIfIdle()
            }
            ACTION_STOP -> {
                stopRecording()
                stopIfIdle()
            }
            else -> stopIfIdle()
        }
        // Not sticky: a microphone service may not be restarted from the background.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        destroyed = true
        // The recorder thread finishes its file on its own and then clears
        // the recording state (recorderEnded).
        worker?.requestStop()
        stopListening()
        armed = false
        armedKey = null
        armedKeyId = null
        running = false
        super.onDestroy()
    }

    // ─── Foreground notification ────────────────────────────────────

    /** False if Android refused (no microphone permission, not on screen). */
    private fun goForeground(): Boolean {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Background tasks", NotificationManager.IMPORTANCE_MIN).apply {
                    setShowBadge(false)
                },
            )
        }
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_MIN)
        }
        // Deliberately plain. On Android 13+ it only appears in the system's
        // list of running apps unless notifications are allowed for the app.
        val n = builder
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle("Files")
            .setContentText("Running in the background")
            .setOngoing(true)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, n)
            }
            return true
        } catch (e: Exception) {
            // No microphone permission, or not started from the screen.
            lastError = "could not start: ${e.message}"
            armed = false
            stopSelf()
            return false
        }
    }

    private fun stopIfIdle() {
        if (armed || recording || destroyed) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    // ─── Screen-off trigger ─────────────────────────────────────────

    private fun listenForTrigger() {
        if (session == null) {
            val s = MediaSession(this, "files")
            // Volume presses are delivered through the session's callback
            // handler; without one attached, Android drops them silently.
            s.setCallback(object : MediaSession.Callback() {}, android.os.Handler(mainLooper))
            s.setPlaybackToRemote(object : VolumeProvider(VOLUME_CONTROL_RELATIVE, 100, 50) {
                override fun onAdjustVolume(direction: Int) {
                    debug("volume $direction")
                    if (direction < 0) onVolumeDown()
                }
            })
            s.setPlaybackState(
                PlaybackState.Builder().setState(PlaybackState.STATE_PLAYING, 0, 1f).build(),
            )
            session = s
        }
        if (screenReceiver == null) {
            val r = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) = updateSessionActive()
            }
            registerReceiver(r, IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
            })
            screenReceiver = r
        }
        updateSessionActive()
    }

    private fun updateSessionActive() {
        val screenOn = getSystemService(PowerManager::class.java).isInteractive
        session?.isActive = armed && (alwaysListen || !screenOn)
        debug("screenOn=$screenOn active=${session?.isActive}")
    }

    private fun stopListening() {
        screenReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        screenReceiver = null
        session?.isActive = false
        session?.release()
        session = null
    }

    private fun onVolumeDown() {
        val now = SystemClock.elapsedRealtime()
        presses.addLast(now)
        while (presses.isNotEmpty() && now - presses.first() > PRESS_WINDOW_MS) presses.removeFirst()
        if (presses.size < 3) return
        presses.clear()
        triggers++
        if (stopping) return // the last stop is still being written
        if (recording) {
            stopRecording()
            buzz(longArrayOf(0, 60, 120, 60))
        } else {
            val key = armedKey ?: return
            if (startRecording(key)) buzz(longArrayOf(0, 90))
        }
    }

    private fun buzz(pattern: LongArray) {
        if (!vibrate) return
        try {
            @Suppress("DEPRECATION")
            val v = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createWaveform(pattern, -1))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(pattern, -1)
            }
        } catch (_: Exception) {
        }
    }

    // ─── Recording ──────────────────────────────────────────────────

    private fun startRecording(vaultKey: ByteArray): Boolean {
        if (recording) {
            // Still finishing the last recording: refuse visibly rather than
            // pretend to start (it ends within a few seconds).
            if (stopping) {
                lastError = "microphone busy"
                return false
            }
            if (recordingKeyId == keyId(vaultKey)) return true
            // Another vault's recording holds the microphone. Say so the way
            // any busy microphone would, without naming who has it.
            lastError = "microphone busy"
            return false
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            lastError = "microphone permission missing"
            return false
        }
        val t = RecorderThread(
            stagingDir(this),
            vaultKey,
            framesPerFile = rotateFrames,
            onFile = { file -> activeFile = file },
            onEnded = { thread, error -> main.post { recorderEnded(thread, error) } },
        )
        lastError = null
        worker = t
        recordingKeyId = keyId(vaultKey)
        startedAtMs = System.currentTimeMillis()
        recording = true
        acquireWakeLock()
        t.start()
        return true
    }

    /** True between asking the recorder to stop and it having stopped. */
    private var stopping = false

    /** Asks the recorder to finish; [recorderEnded] runs once it has. */
    private fun stopRecording() {
        val w = worker ?: return
        stopping = true
        w.requestStop()
    }

    /** On the main thread, after the recorder thread has closed its file. */
    private fun recorderEnded(t: RecorderThread, error: String?) {
        if (worker !== t) return
        worker = null
        stopping = false
        if (error != null) lastError = error
        recording = false
        activeFile = null
        recordingKeyId = null
        releaseWakeLock()
        stopIfIdle()
    }

    private fun acquireWakeLock() {
        val pm = getSystemService(PowerManager::class.java)
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "files:sync").apply {
            setReferenceCounted(false)
            acquire(8 * 60 * 60 * 1000L)
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }
}

/**
 * Microphone → AAC encoder → encrypted segments. Starts a new file every
 * [FRAMES_PER_FILE] frames (30 minutes), so no single recording is too big
 * to decrypt in memory when it moves into the vault, and a finished part
 * can move in while recording goes on. [requestStop] asks it to finish.
 */
class RecorderThread(
    private val dir: File,
    private val vaultKey: ByteArray,
    private val framesPerFile: Int = FRAMES_PER_FILE,
    private val onFile: (File) -> Unit,
    private val onEnded: (RecorderThread, String?) -> Unit,
) : Thread("recorder") {
    @Volatile private var running = true

    companion object {
        const val SAMPLE_RATE = 44100
        const val BIT_RATE = 64000
        const val FRAMES_PER_FILE = 30 * 60 * SAMPLE_RATE / 1024

        /** Stop before the phone runs out of space. */
        const val MIN_FREE_BYTES = 200L * 1024 * 1024
    }

    fun requestStop() {
        running = false
    }

    private fun newWriter(): RecordingWriter {
        val name = ByteArray(12).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
        val file = File(dir, "$name.bin")
        // Marked active before it exists, so it's never offered for import
        // while it's being written.
        onFile(file)
        return RecordingWriter(file, vaultKey)
    }

    override fun run() {
        var writer: RecordingWriter? = null
        var record: AudioRecord? = null
        var codec: MediaCodec? = null
        var failed: String? = null
        try {
            writer = newWriter()
            var fileStartedAt = System.currentTimeMillis()
            var csd: ByteArray? = null
            var framesInFile = 0
            val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            @Suppress("MissingPermission")
            val rec = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf * 4, 16384),
            )
            record = rec
            if (rec.state != AudioRecord.STATE_INITIALIZED) throw IllegalStateException("microphone unavailable")
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
            }
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            codec = enc
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            enc.start()
            rec.startRecording()

            val pcm = ByteArray(4096)
            val info = MediaCodec.BufferInfo()
            var samples = 0L
            var eosSent = false
            var eosDeadline = 0L
            var done = false
            var frameBuf = ByteArray(2048)
            var lastSpaceCheck = 0L
            while (!done) {
                if (!eosSent) {
                    if (running) {
                        val n = rec.read(pcm, 0, pcm.size)
                        if (n < 0) throw IllegalStateException("microphone read failed ($n)")
                        if (n > 0) {
                            val idx = enc.dequeueInputBuffer(100_000)
                            if (idx >= 0) {
                                val buf = enc.getInputBuffer(idx)!!
                                buf.clear()
                                val take = minOf(n, buf.remaining())
                                buf.put(pcm, 0, take)
                                enc.queueInputBuffer(idx, 0, take, samples * 1_000_000L / SAMPLE_RATE, 0)
                                samples += take / 2
                            }
                        }
                    } else {
                        val idx = enc.dequeueInputBuffer(100_000)
                        if (idx >= 0) {
                            enc.queueInputBuffer(idx, 0, 0, samples * 1_000_000L / SAMPLE_RATE, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            eosSent = true
                            eosDeadline = SystemClock.elapsedRealtime() + 3000
                        }
                    }
                } else if (SystemClock.elapsedRealtime() > eosDeadline) {
                    // An encoder that never reports end-of-stream mustn't
                    // hold the file open forever.
                    break
                }
                var out = enc.dequeueOutputBuffer(info, if (eosSent) 10_000 else 0)
                while (out != MediaCodec.INFO_TRY_AGAIN_LATER) {
                    if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        val csdBuf = enc.outputFormat.getByteBuffer("csd-0")
                        val c = ByteArray(csdBuf?.remaining() ?: 0).also { csdBuf?.get(it) }
                        csd = c
                        writer!!.config(fileStartedAt, SAMPLE_RATE, 1, c)
                    } else if (out >= 0) {
                        val buf = enc.getOutputBuffer(out)!!
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                            if (frameBuf.size < info.size) frameBuf = ByteArray(info.size)
                            buf.position(info.offset)
                            buf.get(frameBuf, 0, info.size)
                            writer!!.frame(frameBuf, 0, info.size)
                            framesInFile++
                        }
                        enc.releaseOutputBuffer(out, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            done = true
                            break
                        }
                        val c = csd
                        if (framesInFile >= framesPerFile && c != null && running) {
                            writer!!.finish()
                            fileStartedAt = System.currentTimeMillis()
                            writer = newWriter()
                            writer.config(fileStartedAt, SAMPLE_RATE, 1, c)
                            framesInFile = 0
                        }
                    }
                    out = enc.dequeueOutputBuffer(info, 0)
                }
                writer!!.flushIfDue()
                val now = SystemClock.elapsedRealtime()
                if (running && now - lastSpaceCheck > 10_000) {
                    lastSpaceCheck = now
                    if (dir.usableSpace < MIN_FREE_BYTES) {
                        failed = "storage almost full"
                        running = false
                    }
                }
            }
        } catch (e: Throwable) {
            failed = e.message ?: e.toString()
        } finally {
            try {
                record?.stop()
            } catch (_: Throwable) {
            }
            record?.release()
            try {
                codec?.stop()
            } catch (_: Throwable) {
            }
            codec?.release()
            try {
                writer?.finish()
            } catch (_: Throwable) {
            }
        }
        onEnded(this, failed)
    }
}
