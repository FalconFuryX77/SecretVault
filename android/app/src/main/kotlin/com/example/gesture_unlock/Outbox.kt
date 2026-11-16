package com.example.gesture_unlock

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Uploading while the vault is locked (SYNC_DESIGN §9, option B).
 *
 * While a vault is open and can't reach its server, backup seals what it
 * would have sent (pieces and log records, already encrypted under the
 * vault's keys) into this queue. A background job then sends them whenever
 * a network appears, holding only an upload-only token: it can add pieces
 * and log records to the account, and read, list or delete nothing. It has
 * no vault key, file name or anything readable.
 *
 * On disk: `no_backup/rc/` with a state file (server, token, the queue's
 * order) sealed under a hardware-keystore key that needs no unlock (it has
 * to work while locked), and one file per queued item.
 *
 * The emergency stop ([stop]: "Clear cache" in the cover app, or the stop
 * code on the lock screen) shreds the queue, the state and the key, and
 * cancels the job. It touches nothing in the vault or on the server.
 */
class Outbox(context: Context) {
    companion object {
        private const val KEY_ALIAS = "rc0"
        const val WORK = "render-cache"
        /** The queue may use at most this, or a tenth of the free space. */
        const val MAX_BYTES = 1L shl 30
        /** And always leaves this much free on the phone. */
        const val MIN_FREE = 2L shl 30
        val lock = Any()
        private val calls = Executors.newSingleThreadExecutor()
        private val random = SecureRandom()

        fun dir(c: Context) = File(c.noBackupFilesDir, "rc")
    }

    private val ctx = context.applicationContext
    private val dir = dir(ctx)
    private val qdir = File(dir, "q")
    private val stateFile = File(dir, "s")

    // ── State, sealed under the keystore key ──

    private fun key(create: Boolean): SecretKey? {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        if (!create) return null
        val g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        g.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return g.generateKey()
    }

    private fun load(): JSONObject? {
        if (!stateFile.exists()) return null
        val k = key(false) ?: return null
        return try {
            val raw = stateFile.readBytes()
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, k, GCMParameterSpec(128, raw, 0, 12))
            JSONObject(String(c.doFinal(raw, 12, raw.size - 12), Charsets.UTF_8))
        } catch (e: Exception) {
            null
        }
    }

    private fun save(s: JSONObject) {
        dir.mkdirs()
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key(true))
        val sealed = c.iv + c.doFinal(s.toString().toByteArray(Charsets.UTF_8))
        val tmp = File(dir, "s.tmp")
        tmp.writeBytes(sealed)
        if (!tmp.renameTo(stateFile)) {
            stateFile.delete()
            tmp.renameTo(stateFile)
        }
    }

    private fun entries(s: JSONObject): JSONArray = s.optJSONArray("entries") ?: JSONArray().also { s.put("entries", it) }

    private fun pendingBytes(s: JSONObject): Long {
        val e = entries(s)
        var n = 0L
        for (i in 0 until e.length()) n += e.getJSONObject(i).getLong("s")
        return n
    }

    private fun cap(): Long = minOf(MAX_BYTES, dir.apply { mkdirs() }.usableSpace / 10)

    // ── Calls from the vault ──

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        calls.execute {
            try {
                val out: Any? = synchronized(lock) {
                    when (call.method) {
                        "status" -> status()
                        "arm" -> {
                            arm(
                                call.argument<String>("server")!!,
                                call.argument<Boolean>("tor") == true,
                                call.argument<String>("token")!!,
                                (call.argument<Number>("expires")!!).toLong(),
                                call.argument<String>("arm")!!,
                                call.argument<ByteArray>("stop"),
                            )
                            null
                        }
                        "enqueue" -> enqueue(
                            call.argument<Boolean>("log") == true,
                            call.argument<String>("id"),
                            (call.argument<Number>("counter") ?: 0).toInt(),
                            call.argument<ByteArray>("data")!!,
                        )
                        "entries" -> listEntries()
                        "read" -> File(qdir, call.argument<String>("name")!!).readBytes()
                        "remove" -> {
                            remove(call.argument<String>("name")!!)
                            null
                        }
                        "setStop" -> {
                            val s = load() ?: throw IllegalStateException("not armed")
                            val tag = call.argument<ByteArray>("tag")
                            if (tag == null) s.remove("stop") else s.put("stop", b64(tag))
                            save(s)
                            null
                        }
                        "stopIfMatches" -> stopIfMatches(call.argument<ByteArray>("tag")!!)
                        "stop" -> {
                            stop()
                            null
                        }
                        "kick" -> {
                            kick()
                            null
                        }
                        else -> throw UnsupportedOperationException(call.method)
                    }
                }
                android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(out) }
            } catch (e: Exception) {
                android.os.Handler(android.os.Looper.getMainLooper()).post { result.error("outbox", e.message, null) }
            }
        }
    }

    private fun status(): Map<String, Any?> {
        val s = load() ?: return mapOf("armed" to false)
        return mapOf(
            "armed" to true,
            "arm" to s.optString("arm"),
            "expires" to s.optLong("expires"),
            "count" to entries(s).length(),
            "bytes" to pendingBytes(s),
            "cap" to cap(),
            "stop" to s.has("stop"),
        )
    }

    private fun arm(server: String, tor: Boolean, token: String, expires: Long, arm: String, stop: ByteArray?) {
        val s = load() ?: JSONObject()
        s.put("server", server.trimEnd('/'))
        s.put("tor", tor)
        s.put("token", token)
        s.put("expires", expires)
        s.put("arm", arm)
        if (stop != null) s.put("stop", b64(stop))
        entries(s)
        save(s)
        schedule()
    }

    /** False if the queue is full (see [MAX_BYTES], [MIN_FREE]). */
    private fun enqueue(log: Boolean, id: String?, counter: Int, data: ByteArray): Boolean {
        val s = load() ?: throw IllegalStateException("not armed")
        if (pendingBytes(s) + data.size > cap() || dir.usableSpace - data.size < MIN_FREE) return false
        qdir.mkdirs()
        val name = ByteArray(12).also { random.nextBytes(it) }.joinToString("") { "%02x".format(it) }
        File(qdir, name).writeBytes(data)
        entries(s).put(
            JSONObject().put("n", name).put("k", if (log) "l" else "p").put("id", id ?: "").put("c", counter).put("s", data.size.toLong()),
        )
        save(s)
        return true
    }

    private fun listEntries(): List<Map<String, Any>> {
        val s = load() ?: return emptyList()
        val e = entries(s)
        return (0 until e.length()).map {
            val o = e.getJSONObject(it)
            mapOf("name" to o.getString("n"), "log" to (o.getString("k") == "l"), "id" to o.getString("id"), "counter" to o.getInt("c"), "size" to o.getLong("s"))
        }
    }

    private fun remove(name: String) {
        val s = load() ?: return
        val e = entries(s)
        val kept = JSONArray()
        for (i in 0 until e.length()) if (e.getJSONObject(i).getString("n") != name) kept.put(e.getJSONObject(i))
        s.put("entries", kept)
        save(s)
        File(qdir, name).delete()
    }

    private fun stopIfMatches(tag: ByteArray): Boolean {
        val s = load() ?: return false
        val stored = s.optString("stop", "")
        if (stored.isEmpty()) return false
        if (!MessageDigest.isEqual(Base64.decode(stored, Base64.NO_WRAP), tag)) return false
        stop()
        return true
    }

    /** The emergency stop: queue, state and key gone, job cancelled. */
    fun stop() {
        synchronized(lock) {
            val wm = WorkManager.getInstance(ctx)
            wm.cancelUniqueWork(WORK)
            wm.cancelUniqueWork("$WORK-now")
            wm.pruneWork()
            qdir.listFiles()?.forEach { RecordingFormat.shred(it) }
            if (stateFile.exists()) RecordingFormat.shred(stateFile)
            dir.deleteRecursively()
            try {
                KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(KEY_ALIAS)
            } catch (_: Exception) {
            }
        }
    }

    private fun constraints() = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

    private fun schedule() {
        WorkManager.getInstance(ctx).enqueueUniquePeriodicWork(
            WORK,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<OutboxWorker>(15, TimeUnit.MINUTES).setConstraints(constraints()).build(),
        )
    }

    /** Send what's queued as soon as there's a network. */
    fun kick() {
        if (!stateFile.exists()) return
        WorkManager.getInstance(ctx).enqueueUniqueWork(
            "$WORK-now",
            ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequestBuilder<OutboxWorker>().setConstraints(constraints()).build(),
        )
    }

    // ── The background job ──

    enum class Run { DONE, RETRY }

    /** Sends the queue in order. Never reads anything back from the server. */
    fun upload(): Run {
        while (true) {
            val (s, entry) = synchronized(lock) {
                val s = load() ?: return Run.DONE
                val e = entries(s)
                if (e.length() == 0) return Run.DONE
                s to e.getJSONObject(0)
            }
            if (s.optLong("expires") < System.currentTimeMillis()) return Run.DONE // renewed at the next unlock
            val name = entry.getString("n")
            val file = File(qdir, name)
            if (!file.exists()) {
                synchronized(lock) { remove(name) }
                continue
            }
            val data = file.readBytes()
            val code: Int
            val body: String
            try {
                val (c, b) = if (entry.getString("k") == "p") {
                    send(s, "PUT", "/v1/pieces/${entry.getString("id")}", data, "application/octet-stream", sha256Header(data))
                } else {
                    val json = JSONObject().put("counter", entry.getInt("c")).put("record", b64(data)).toString()
                    send(s, "POST", "/v1/log", json.toByteArray(), "application/json", null)
                }
                code = c
                body = b
            } catch (e: Exception) {
                return Run.RETRY // no network, a drop, or Tor not running
            }
            when {
                code in 200..299 -> synchronized(lock) { remove(name) }
                code == 409 && entry.getString("k") == "l" -> {
                    // Already appended (an earlier reply was lost): drop it.
                    // A gap instead means something before it is missing:
                    // leave it for the vault to sort out at its next unlock.
                    val expected = Regex("\"expected\"\\s*:\\s*(\\d+)").find(body)?.groupValues?.get(1)?.toIntOrNull()
                    if (expected != null && expected > entry.getInt("c")) synchronized(lock) { remove(name) } else return Run.DONE
                }
                code == 401 || code == 403 -> return Run.DONE // token revoked or expired
                code >= 500 || code == 408 || code == 429 -> return Run.RETRY
                else -> return Run.DONE
            }
        }
    }

    private fun send(s: JSONObject, method: String, path: String, data: ByteArray, type: String, digest: String?): Pair<Int, String> {
        val url = URL(s.getString("server") + path)
        val conn = (if (s.optBoolean("tor")) url.openConnection(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", 8118))) else url.openConnection()) as HttpURLConnection
        try {
            conn.requestMethod = method
            conn.connectTimeout = 30_000
            conn.readTimeout = 60_000
            conn.doOutput = true
            conn.setFixedLengthStreamingMode(data.size)
            conn.setRequestProperty("Authorization", "Bearer ${s.getString("token")}")
            conn.setRequestProperty("Content-Type", type)
            if (digest != null) conn.setRequestProperty("Content-Digest", digest)
            conn.outputStream.use { it.write(data) }
            val code = conn.responseCode
            val body = (if (code >= 400) conn.errorStream else conn.inputStream)?.use { String(it.readBytes()) } ?: ""
            return code to body
        } finally {
            conn.disconnect()
        }
    }

    private fun sha256Header(data: ByteArray) = "sha-256=:${b64(MessageDigest.getInstance("SHA-256").digest(data))}:"

    private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.NO_WRAP)
}

/** WorkManager's entry point for [Outbox.upload]. */
class OutboxWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result = when (Outbox(applicationContext).upload()) {
        Outbox.Run.DONE -> Result.success()
        Outbox.Run.RETRY -> Result.retry()
    }
}
