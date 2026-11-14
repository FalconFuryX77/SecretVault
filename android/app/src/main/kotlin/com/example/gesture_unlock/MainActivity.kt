package com.example.gesture_unlock

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
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

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val SECURITY_CHANNEL = "com.example.secretvault/security"
        private const val KEYS_CHANNEL = "app.vault/keys"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"

        // Neutral alias names: nothing in the keystore says "vault".
        private const val DEVICE_HMAC_ALIAS = "db0"
        private const val BIO_ALIAS_PREFIX = "k"
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
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, KEYS_CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "deviceHmac" -> result.success(deviceHmac(call.argument<ByteArray>("data")!!))
                    "bioAvailable" -> result.success(
                        BiometricManager.from(this).canAuthenticate(BIOMETRIC_STRONG) ==
                            BiometricManager.BIOMETRIC_SUCCESS
                    )
                    "bioEnsureSlots" -> {
                        val count = call.argument<Int>("count") ?: 0
                        for (i in 0 until count) {
                            if (!keyStore.containsAlias(bioAlias(i))) generateBioKey(i)
                        }
                        result.success(true)
                    }
                    "bioWrap" -> bioWrap(call, result)
                    "bioUnwrap" -> bioUnwrap(call, result)
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

    // ─── Biometric-bound vault keys ─────────────────────────────────
    //
    // One AES key per container record. The hardware only lets it be used
    // after a strong biometric, and it's destroyed if a new fingerprint is
    // enrolled (so adding someone else's finger can't open the vault).

    private fun bioAlias(slot: Int) = "$BIO_ALIAS_PREFIX$slot"

    private fun generateBioKey(slot: Int): SecretKey {
        val b = KeyGenParameterSpec.Builder(
            bioAlias(slot),
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            b.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            @Suppress("DEPRECATION")
            b.setUserAuthenticationValidityDurationSeconds(-1)
        }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        gen.init(b.build())
        return gen.generateKey()
    }

    private fun bioKey(slot: Int): SecretKey =
        (keyStore.getKey(bioAlias(slot), null) as? SecretKey) ?: generateBioKey(slot)

    private fun bioWrap(call: MethodCall, result: MethodChannel.Result) {
        val slot = call.argument<Int>("slot")!!
        val data = call.argument<ByteArray>("data")!!
        val reason = call.argument<String>("reason") ?: ""
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        try {
            cipher.init(Cipher.ENCRYPT_MODE, bioKey(slot))
        } catch (e: KeyPermanentlyInvalidatedException) {
            // Enrolling a fresh gesture: replace the dead key.
            keyStore.deleteEntry(bioAlias(slot))
            cipher.init(Cipher.ENCRYPT_MODE, generateBioKey(slot))
        }
        prompt(cipher, reason, result) { c -> c.iv + c.doFinal(data) }
    }

    private fun bioUnwrap(call: MethodCall, result: MethodChannel.Result) {
        val slot = call.argument<Int>("slot")!!
        val blob = call.argument<ByteArray>("data")!!
        val reason = call.argument<String>("reason") ?: ""
        if (blob.size <= GCM_IV_LEN) {
            result.error("bad_blob", null, null)
            return
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        try {
            cipher.init(
                Cipher.DECRYPT_MODE,
                bioKey(slot),
                GCMParameterSpec(GCM_TAG_BITS, blob.copyOfRange(0, GCM_IV_LEN))
            )
        } catch (e: KeyPermanentlyInvalidatedException) {
            result.error("invalidated", "biometric enrollment changed", null)
            return
        }
        prompt(cipher, reason, result) { c -> c.doFinal(blob.copyOfRange(GCM_IV_LEN, blob.size)) }
    }

    private fun prompt(
        cipher: Cipher,
        reason: String,
        result: MethodChannel.Result,
        onAuthenticated: (Cipher) -> ByteArray,
    ) {
        var replied = false
        fun reply(block: () -> Unit) {
            if (!replied) {
                replied = true
                block()
            }
        }
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(r: BiometricPrompt.AuthenticationResult) {
                reply {
                    try {
                        val c = r.cryptoObject?.cipher ?: throw IllegalStateException("no cipher")
                        result.success(onAuthenticated(c))
                    } catch (e: Exception) {
                        result.error("crypto", e.message, null)
                    }
                }
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                reply { result.error("cancelled", errString.toString(), null) }
            }
            // onAuthenticationFailed = one bad finger; the prompt stays open.
        }
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(reason)
            .setNegativeButtonText("Cancel")
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .build()
        BiometricPrompt(this, ContextCompat.getMainExecutor(this), callback)
            .authenticate(info, BiometricPrompt.CryptoObject(cipher))
    }
}
