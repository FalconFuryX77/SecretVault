package com.example.gesture_unlock

import android.app.usage.StorageStatsManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.storage.StorageManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Handler
import android.os.Looper
import java.io.File
import java.io.RandomAccessFile
import java.security.KeyStore
import java.security.SecureRandom
import java.util.concurrent.Executors
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

class MainActivity : FlutterActivity() {
    companion object {
        private const val SECURITY_CHANNEL = "com.example.secretvault/security"
        private const val KEYS_CHANNEL = "app.vault/keys"
        private const val PDF_CHANNEL = "app.vault/pdf"
        private const val RECORDER_CHANNEL = "app.vault/recorder"
        private const val CAMERA_CHANNEL = "app.vault/camera"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"

        // Neutral alias names: nothing in the keystore says "vault".
        private const val DEVICE_HMAC_ALIAS = "db0"

        // Biometric-bound keys from an earlier version (gesture + fingerprint
        // unlock, since removed). Deleted on startup so old slots are dead.
        private val LEGACY_BIO_ALIASES = listOf("k0", "k1", "k2", "k3")
        private const val GCM_IV_LEN = 12
        private const val GCM_TAG_BITS = 128
    }

    private val keyStore: KeyStore by lazy { KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) } }

    // Bulk crypto and file filling run off the platform thread; results are
    // posted back to it, as MethodChannel requires.
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val random = SecureRandom()

    private fun inBackground(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: ChunkAuthException) {
                mainHandler.post { result.error("auth", e.index.toString(), null) }
            } catch (e: Throwable) {
                // Throwable, not Exception: an OutOfMemoryError here would
                // otherwise kill the app.
                mainHandler.post { result.error("bulk", e.message, null) }
            }
        }
    }

    private class ChunkAuthException(val index: Int) : Exception()

    private val pdfSandbox by lazy { PdfSandbox(this) }
    private var camera: VaultCamera? = null

    /** Whether vault text was copied since the clipboard was last cleared. */
    private var copiedSensitive = false

    /** Videos being streamed into the vault, by handle. */
    private val exports = HashMap<Int, Mp4Exporter>()
    private var nextExport = 1

    override fun onDestroy() {
        camera?.shutdown()
        synchronized(exports) {
            exports.values.forEach { it.close() }
            exports.clear()
        }
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // FLAG_SECURE is applied only inside the vault; the cover Files app
        // must behave normally (screenshots allowed).
        MethodChannel(messenger, SECURITY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecureFlag" -> {
                    val enable = call.argument<Boolean>("enable") ?: true
                    if (enable) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(true)
                }
                // For lockouts: time since boot can't be moved from Settings
                // the way the wall clock can.
                "clock" -> result.success(
                    mapOf(
                        "elapsed" to android.os.SystemClock.elapsedRealtime(),
                        "boot" to android.provider.Settings.Global.getInt(
                            contentResolver,
                            android.provider.Settings.Global.BOOT_COUNT,
                            -1,
                        ),
                    ),
                )
                "copySensitive" -> {
                    // Marked sensitive: keyboards keep it out of their
                    // clipboard history, and Android hides its preview.
                    val cm = getSystemService(android.content.ClipboardManager::class.java)
                    val clip = android.content.ClipData.newPlainText("", call.argument<String>("text") ?: "")
                    clip.description.extras = android.os.PersistableBundle().apply {
                        putBoolean("android.content.extra.IS_SENSITIVE", true)
                    }
                    cm.setPrimaryClip(clip)
                    copiedSensitive = true
                    result.success(true)
                }
                "clearSensitive" -> {
                    if (copiedSensitive) {
                        val cm = getSystemService(android.content.ClipboardManager::class.java)
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                cm.clearPrimaryClip()
                            } else {
                                cm.setPrimaryClip(android.content.ClipData.newPlainText("", ""))
                            }
                        } catch (_: Exception) {
                        }
                        copiedSensitive = false
                    }
                    result.success(true)
                }
                "setKeepScreenOn" -> {
                    if (call.argument<Boolean>("on") == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }
                // Real storage totals for the cover file manager, the same
                // figures the system's own Settings shows.
                "storageStats" -> {
                    try {
                        val totals = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val ssm = getSystemService(StorageStatsManager::class.java)
                            ssm.getTotalBytes(StorageManager.UUID_DEFAULT) to
                                ssm.getFreeBytes(StorageManager.UUID_DEFAULT)
                        } else {
                            val fs = StatFs(Environment.getDataDirectory().path)
                            fs.totalBytes to fs.availableBytes
                        }
                        result.success(mapOf("total" to totals.first, "free" to totals.second))
                    } catch (e: Exception) {
                        result.error("storage", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, PDF_CHANNEL).setMethodCallHandler { call, result ->
            pdfSandbox.handle(call, result)
        }

        MethodChannel(messenger, RECORDER_CHANNEL).setMethodCallHandler { call, result ->
            handleRecorder(call, result)
        }

        val cam = VaultCamera(this, flutterEngine.renderer)
        camera = cam
        MethodChannel(messenger, CAMERA_CHANNEL).setMethodCallHandler { call, result ->
            cam.handle(call, result)
        }

        worker.execute {
            try {
                LEGACY_BIO_ALIASES.forEach { if (keyStore.containsAlias(it)) keyStore.deleteEntry(it) }
            } catch (_: Exception) {
                // Best effort; nothing depends on these keys any more.
            }
        }

        MethodChannel(messenger, KEYS_CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "deviceHmac" -> result.success(deviceHmac(call.argument<ByteArray>("data")!!))
                    "nfc" -> result.success(
                        java.text.Normalizer.normalize(call.argument<String>("text")!!, java.text.Normalizer.Form.NFC),
                    )
                    "gcmSealChunks" -> inBackground(result) {
                        gcmSealChunks(
                            call.argument<ByteArray>("key")!!,
                            call.argument<List<ByteArray>>("plains")!!,
                            call.argument<List<ByteArray>>("aads")!!,
                            call.argument<Int>("chunkSize")!!,
                        )
                    }
                    "gcmOpenChunks" -> inBackground(result) {
                        gcmOpenChunks(
                            call.argument<ByteArray>("key")!!,
                            call.argument<List<ByteArray>>("sealed")!!,
                            call.argument<List<ByteArray>>("aads")!!,
                        )
                    }
                    "fillRandom" -> inBackground(result) {
                        fillRandom(
                            call.argument<String>("path")!!,
                            (call.argument<Number>("offset")!!).toLong(),
                            (call.argument<Number>("length")!!).toLong(),
                        )
                        true
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("keystore", e.message, null)
            }
        }
    }

    // ─── Recorder ───────────────────────────────────────────────────
    //
    // See RecorderService and RecordingFormat. The vault's private key only
    // passes through here to open finished recordings, in memory.

    private fun recorderIntent(action: String) =
        android.content.Intent(this, RecorderService::class.java).setAction(action)

    private fun startRecorderService(intent: android.content.Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
    }

    private fun handleRecorder(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "keyPair" -> {
                    val (pub, priv) = RecordingFormat.newVaultKeyPair()
                    result.success(mapOf("pub" to pub, "priv" to priv))
                }
                "status" -> result.success(
                    mapOf(
                        "armed" to RecorderService.armed,
                        "recording" to RecorderService.recording,
                        "startedAt" to RecorderService.startedAtMs,
                        "error" to RecorderService.lastError,
                        "triggers" to RecorderService.triggers,
                        "armedKey" to RecorderService.armedKeyId,
                        "recordingKey" to RecorderService.recordingKeyId,
                    ),
                )
                "arm" -> {
                    startRecorderService(
                        recorderIntent(RecorderService.ACTION_ARM)
                            .putExtra(RecorderService.EXTRA_KEY, call.argument<ByteArray>("key")!!)
                            .putExtra(RecorderService.EXTRA_VIBRATE, call.argument<Boolean>("vibrate") ?: true)
                            .putExtra(RecorderService.EXTRA_ALWAYS_LISTEN, call.argument<Boolean>("alwaysListen") ?: false)
                            .putExtra(RecorderService.EXTRA_BUTTON, call.argument<Int>("button") ?: -1)
                            .putExtra(RecorderService.EXTRA_PRESSES, call.argument<Int>("presses") ?: 3)
                            .putExtra(RecorderService.EXTRA_ASSIST, call.argument<Boolean>("assist") ?: false),
                    )
                    result.success(true)
                }
                "assistState" -> result.success(
                    mapOf(
                        "enabled" to AssistTriggerActivity.isEnabled(this),
                        "holder" to AssistTriggerActivity.isAssistant(this),
                    ),
                )
                "setAssistEnabled" -> {
                    AssistTriggerActivity.setEnabled(this, call.argument<Boolean>("on") == true)
                    result.success(true)
                }
                "openAssistSettings" -> result.success(AssistTriggerActivity.openSettings(this))
                "disarm" -> {
                    if (RecorderService.running) startService(recorderIntent(RecorderService.ACTION_DISARM))
                    result.success(true)
                }
                "record" -> {
                    startRecorderService(
                        recorderIntent(RecorderService.ACTION_RECORD)
                            .putExtra(RecorderService.EXTRA_KEY, call.argument<ByteArray>("key")!!)
                            .putExtra(
                                RecorderService.EXTRA_ROTATE_FRAMES,
                                call.argument<Int>("rotateFrames") ?: RecorderThread.FRAMES_PER_FILE,
                            )
                            .putExtra(RecorderService.EXTRA_LEGACY_V1, call.argument<Boolean>("legacyV1") ?: false),
                    )
                    result.success(true)
                }
                "stop" -> {
                    if (RecorderService.running) startService(recorderIntent(RecorderService.ACTION_STOP))
                    result.success(true)
                }
                "pending" -> {
                    // List first, then read the active file: read the other
                    // way round, a rotation in between would offer the part
                    // that was just started.
                    val listed = RecorderService.stagingDir(this).listFiles()
                    val active = setOfNotNull(RecorderService.activeFile, VaultCamera.activeFile)
                    val files = listed
                        ?.filter { it.isFile && it.name.endsWith(".bin") && it !in active }
                        ?.sortedBy { it.lastModified() }
                        ?: emptyList()
                    result.success(
                        files.map { mapOf("id" to it.name, "size" to it.length(), "modified" to it.lastModified()) },
                    )
                }
                "open" -> inBackground(result) {
                    val file = stagedFile(call.argument<String>("id")!!)
                    val key = call.argument<ByteArray>("key")!!
                    val pub = call.argument<ByteArray>("pub")
                    try {
                        // Never open a file that is still being written.
                        val usable = file.exists() && !isActive(file)
                        val kind = if (usable) RecordingReader.probe(file, pub, key) else null
                        val rec = if (kind == RecordingReader.Kind.AUDIO || kind == RecordingReader.Kind.EMPTY) {
                            RecordingReader.open(file, pub, key)
                        } else {
                            null
                        }
                        if (kind == RecordingReader.Kind.VIDEO) {
                            mapOf("video" to true)
                        } else if (rec == null) {
                            null
                        } else if (rec.frames.isEmpty() || rec.sampleRate == 0) {
                            mapOf("empty" to true)
                        } else {
                            val (data, ext) = RecordingPacker.pack(rec)
                            rec.wipe()
                            mapOf(
                                "data" to data,
                                "ext" to ext,
                                "startedAt" to rec.startedAtMs,
                                "durationMs" to rec.durationMs,
                                "complete" to rec.complete,
                            )
                        }
                    } finally {
                        key.fill(0)
                    }
                }
                "discard" -> inBackground(result) {
                    val f = stagedFile(call.argument<String>("id")!!)
                    if (f.exists() && !isActive(f)) RecordingFormat.shred(f)
                    true
                }
                "videoOpen" -> inBackground(result) {
                    val file = stagedFile(call.argument<String>("id")!!)
                    val key = call.argument<ByteArray>("key")!!
                    val pub = call.argument<ByteArray>("pub")
                    try {
                        val ex = if (file.exists() && !isActive(file)) Mp4Exporter.open(file, pub, key) else null
                        if (ex == null) {
                            null
                        } else if (ex.scan.count == 0) {
                            ex.close()
                            mapOf("empty" to true)
                        } else {
                            val handle = synchronized(exports) { (nextExport++).also { exports[it] = ex } }
                            val v = ex.scan.tracks.firstOrNull { it.isVideo }
                            mapOf(
                                "handle" to handle,
                                "length" to ex.length,
                                "startedAt" to ex.scan.startedAtMs,
                                "durationMs" to ex.scan.durationMs,
                                "complete" to ex.scan.complete,
                                "width" to (v?.a ?: 0),
                                "height" to (v?.b ?: 0),
                                "rotation" to (v?.rotation ?: 0),
                            )
                        }
                    } finally {
                        key.fill(0)
                    }
                }
                "videoRead" -> inBackground(result) {
                    val ex = synchronized(exports) { exports[call.argument<Int>("handle")!!] }
                        ?: throw IllegalStateException("no such export")
                    ex.read(call.argument<Int>("max") ?: (1 shl 20))
                }
                "videoClose" -> {
                    val ex = synchronized(exports) { exports.remove(call.argument<Int>("handle")!!) }
                    worker.execute { ex?.close() }
                    result.success(true)
                }
                "probeMedia" -> inBackground(result) {
                    // Debug builds only: what Android's own parser makes of an
                    // MP4 (tests check the vault's MP4 writer with it).
                    check(applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0)
                    probeMedia(call.argument<ByteArray>("data")!!)
                }
                "stagingPath" -> result.success(RecorderService.stagingDir(this).absolutePath)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("recorder", e.message, null)
        }
    }

    private fun isActive(f: File) = f == RecorderService.activeFile || f == VaultCamera.activeFile

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.R)
    private fun probeMedia(data: ByteArray): Map<String, Any?> {
        val fd = android.system.Os.memfd_create("probe", 0)
        try {
            var off = 0
            while (off < data.size) off += android.system.Os.write(fd, data, off, data.size - off)
            android.system.Os.lseek(fd, 0, android.system.OsConstants.SEEK_SET)
            val ex = android.media.MediaExtractor()
            ex.setDataSource(fd)
            val tracks = (0 until ex.trackCount).map { i ->
                val f = ex.getTrackFormat(i)
                mapOf(
                    "mime" to f.getString(android.media.MediaFormat.KEY_MIME),
                    "durationUs" to (if (f.containsKey(android.media.MediaFormat.KEY_DURATION)) f.getLong(android.media.MediaFormat.KEY_DURATION) else -1L),
                    "width" to (if (f.containsKey(android.media.MediaFormat.KEY_WIDTH)) f.getInteger(android.media.MediaFormat.KEY_WIDTH) else 0),
                    "height" to (if (f.containsKey(android.media.MediaFormat.KEY_HEIGHT)) f.getInteger(android.media.MediaFormat.KEY_HEIGHT) else 0),
                )
            }
            var samples = 0
            var syncs = 0
            for (i in 0 until ex.trackCount) ex.selectTrack(i)
            while (ex.sampleTime >= 0) {
                samples++
                if (ex.sampleFlags and android.media.MediaExtractor.SAMPLE_FLAG_SYNC != 0) syncs++
                ex.advance()
            }
            ex.release()
            val r = android.media.MediaMetadataRetriever()
            r.setDataSource(fd)
            val rotation = r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
            val duration = r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)
            val frame = r.getFrameAtTime(500_000)
            val frameSize = frame?.let { listOf(it.width, it.height) }
            frame?.recycle()
            r.release()
            return mapOf(
                "tracks" to tracks,
                "samples" to samples,
                "syncs" to syncs,
                "rotation" to rotation,
                "durationMs" to duration,
                "frame" to frameSize,
            )
        } finally {
            android.system.Os.close(fd)
        }
    }

    /** A staged recording by name, refusing anything outside its folder. */
    private fun stagedFile(id: String): File {
        require(STAGED_NAME.matches(id)) { "bad id" }
        return File(RecorderService.stagingDir(this), id)
    }

    private val STAGED_NAME = Regex("^[0-9a-f]{24}[.]bin$")

    // ─── Bulk chunk crypto ──────────────────────────────────────────
    //
    // Same format as the Dart implementation (lib/vault/bulk_crypto.dart):
    // nonce(12) ‖ AES-256-GCM ciphertext ‖ tag(16) ‖ random padding.

    private fun gcmSealChunks(
        key: ByteArray,
        plains: List<ByteArray>,
        aads: List<ByteArray>,
        chunkSize: Int,
    ): List<ByteArray> {
        val k = SecretKeySpec(key, "AES")
        key.fill(0) // SecretKeySpec keeps its own copy
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        return plains.mapIndexed { i, plain ->
            val out = ByteArray(chunkSize)
            val nonce = ByteArray(GCM_IV_LEN).also { random.nextBytes(it) }
            cipher.init(Cipher.ENCRYPT_MODE, k, GCMParameterSpec(GCM_TAG_BITS, nonce))
            cipher.updateAAD(aads[i])
            val sealed = cipher.doFinal(plain)
            val used = GCM_IV_LEN + sealed.size
            require(used <= chunkSize) { "chunk overflow" }
            System.arraycopy(nonce, 0, out, 0, GCM_IV_LEN)
            System.arraycopy(sealed, 0, out, GCM_IV_LEN, sealed.size)
            if (used < chunkSize) {
                val pad = ByteArray(chunkSize - used).also { random.nextBytes(it) }
                System.arraycopy(pad, 0, out, used, pad.size)
            }
            out
        }
    }

    private fun gcmOpenChunks(key: ByteArray, sealed: List<ByteArray>, aads: List<ByteArray>): List<ByteArray> {
        val k = SecretKeySpec(key, "AES")
        key.fill(0) // SecretKeySpec keeps its own copy
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        return sealed.mapIndexed { i, s ->
            if (s.size < GCM_IV_LEN + GCM_TAG_BITS / 8) throw ChunkAuthException(i)
            cipher.init(Cipher.DECRYPT_MODE, k, GCMParameterSpec(GCM_TAG_BITS, s, 0, GCM_IV_LEN))
            cipher.updateAAD(aads[i])
            try {
                cipher.doFinal(s, GCM_IV_LEN, s.size - GCM_IV_LEN)
            } catch (e: AEADBadTagException) {
                throw ChunkAuthException(i)
            }
        }
    }

    /// AES-CTR keystream under a throwaway random key: indistinguishable from
    /// ciphertext, and written straight to disk so it never crosses the channel.
    private fun fillRandom(path: String, offset: Long, length: Long) {
        val key = ByteArray(32).also { random.nextBytes(it) }
        val iv = ByteArray(16).also { random.nextBytes(it) }
        val ctr = Cipher.getInstance("AES/CTR/NoPadding")
        ctr.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
        val zeros = ByteArray(1 shl 20)
        RandomAccessFile(File(path), "rw").use { f ->
            f.seek(offset)
            var left = length
            while (left > 0) {
                val n = minOf(left, zeros.size.toLong()).toInt()
                ctr.update(zeros, 0, n)?.let { f.write(it) }
                left -= n
            }
            // A provider may hold back a partial block until doFinal.
            ctr.doFinal().let { if (it.isNotEmpty()) f.write(it) }
            f.fd.sync()
        }
        key.fill(0)
    }

    // ─── Device binding ─────────────────────────────────────────────
    //
    // HMAC-SHA256 under a non-exportable hardware key. Every PIN / gesture
    // guess has to pass through here, so the container can't be attacked
    // offline on another machine.

    private fun deviceHmac(data: ByteArray): ByteArray {
        val key = (keyStore.getKey(DEVICE_HMAC_ALIAS, null) as? SecretKey) ?: generateHmacKey()
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(key)
        return mac.doFinal(data)
    }

    private fun generateHmacKey(): SecretKey {
        fun spec(strongBox: Boolean): KeyGenParameterSpec {
            val b = KeyGenParameterSpec.Builder(DEVICE_HMAC_ALIAS, KeyProperties.PURPOSE_SIGN)
                .setDigests(KeyProperties.DIGEST_SHA256)
            if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) b.setIsStrongBoxBacked(true)
            return b.build()
        }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, ANDROID_KEYSTORE)
        return try {
            gen.init(spec(strongBox = true))
            gen.generateKey()
        } catch (e: Exception) {
            // No StrongBox chip (StrongBoxUnavailableException) or it refused
            // the key: the TEE-backed keystore is still hardware-isolated.
            gen.init(spec(strongBox = false))
            gen.generateKey()
        }
    }
}
