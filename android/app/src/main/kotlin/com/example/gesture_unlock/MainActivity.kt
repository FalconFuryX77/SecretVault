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
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

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
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("keystore", e.message, null)
            }
        }
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
