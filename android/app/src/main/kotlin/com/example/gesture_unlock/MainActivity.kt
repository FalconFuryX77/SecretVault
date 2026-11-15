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
            } catch (e: Exception) {
                mainHandler.post { result.error("bulk", e.message, null) }
            }
        }
    }

    private class ChunkAuthException(val index: Int) : Exception()

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
