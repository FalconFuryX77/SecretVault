package com.example.gesture_unlock

import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.system.Os
import android.system.OsConstants
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Recordings made while the vault may be locked.
 *
 * The vault holds a P-256 key pair; only its public half is handed to the
 * recorder. Each recording gets a fresh ephemeral key pair, and the file key
 * is HKDF(ECDH(ephemeral, vault public key)). So the phone can *write* a
 * recording at any time but can't read it back: that needs the vault's
 * private key, which exists only inside the encrypted vault index. The
 * ephemeral private key is discarded as soon as the file key is derived.
 *
 * File layout:
 *   u16 length, ephemeral public key (X.509)
 *   segments: u32 length, AES-256-GCM(ciphertext ‖ tag)
 *     nonce = 0⁴ ‖ u64 index, aad = "rec/v1" ‖ u64 index ‖ final flag
 *
 * Segment plaintexts concatenate into records:
 *   1 config: u64 start time (ms), u32 sample rate, u8 channels, u16 len, AAC config
 *   2 frame:  u16 len, one AAC access unit (1024 samples)
 *   3 end
 * Segments are written about once a second, so if the phone dies mid-way
 * only the last second is lost. The final flag lets a reader tell a finished
 * recording from one cut short.
 */
object RecordingFormat {
    private val INFO = "rec/v1".toByteArray()
    private val random = SecureRandom()

    const val REC_CONFIG = 1
    const val REC_FRAME = 2
    const val REC_END = 3

    fun newVaultKeyPair(): Pair<ByteArray, ByteArray> {
        val g = KeyPairGenerator.getInstance("EC")
        g.initialize(ECGenParameterSpec("secp256r1"), random)
        val kp = g.generateKeyPair()
        return kp.public.encoded to kp.private.encoded
    }

    fun publicKey(x509: ByteArray): PublicKey =
        KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(x509))

    fun privateKey(pkcs8: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(pkcs8))

    fun fileKey(own: PrivateKey, peer: PublicKey, ephemeralPublic: ByteArray): ByteArray {
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(own)
        ka.doPhase(peer, true)
        val shared = ka.generateSecret()
        try {
            return hkdf(shared, INFO + ephemeralPublic)
        } finally {
            shared.fill(0)
        }
    }

    /** HKDF-SHA256 with a zero salt, 32 bytes of output. */
    private fun hkdf(ikm: ByteArray, info: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(ByteArray(32), "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        mac.update(info)
        mac.update(1)
        val okm = mac.doFinal()
        prk.fill(0)
        return okm
    }

    fun nonce(index: Long): ByteArray = ByteArray(12).also { ByteBuffer.wrap(it, 4, 8).putLong(index) }

    fun aad(index: Long, final: Boolean): ByteArray =
        INFO + ByteBuffer.allocate(9).putLong(index).put(if (final) 1 else 0).array()

    /** Fills [file] with random bytes, then deletes it. */
    fun shred(file: File) {
        try {
            // Overwrite the existing blocks in place: opening for writing
            // with truncation would put the random data in fresh blocks and
            // leave the old ciphertext where it was.
            java.io.RandomAccessFile(file, "rw").use { raf ->
                val len = raf.length()
                val buf = ByteArray(64 * 1024)
                var left = len
                while (left > 0) {
                    random.nextBytes(buf)
                    val n = minOf(left, buf.size.toLong()).toInt()
                    raf.write(buf, 0, n)
                    left -= n
                }
                raf.fd.sync()
            }
        } catch (_: Exception) {
        }
        file.delete()
    }
}

/** Writes one encrypted recording, segment by segment. Not thread-safe. */
class RecordingWriter(private val file: File, vaultPublicKey: ByteArray) {
    private val out: FileOutputStream
    private val key: ByteArray
    private val pending = ByteArrayOutputStream()
    private var index = 0L
    private var lastFlush = System.nanoTime()
    var closed = false
        private set

    /** Set after a failed write: the file is left as it is (cut short). */
    private var poisoned = false

    init {
        // Derive the key before creating the file, so a failure here leaves
        // nothing behind.
        val g = KeyPairGenerator.getInstance("EC")
        g.initialize(ECGenParameterSpec("secp256r1"))
        val eph = g.generateKeyPair()
        val ephPub = eph.public.encoded
        key = RecordingFormat.fileKey(eph.private, RecordingFormat.publicKey(vaultPublicKey), ephPub)
        out = FileOutputStream(file)
        try {
            out.write(ByteBuffer.allocate(2).putShort(ephPub.size.toShort()).array())
            out.write(ephPub)
            out.flush()
        } catch (e: Exception) {
            out.close()
            file.delete()
            key.fill(0)
            throw e
        }
    }

    fun config(startedAtMs: Long, sampleRate: Int, channels: Int, csd: ByteArray) {
        val b = ByteBuffer.allocate(1 + 8 + 4 + 1 + 2 + csd.size)
        b.put(RecordingFormat.REC_CONFIG.toByte()).putLong(startedAtMs).putInt(sampleRate)
            .put(channels.toByte()).putShort(csd.size.toShort()).put(csd)
        pending.write(b.array())
    }

    fun frame(data: ByteArray, offset: Int, length: Int) {
        pending.write(RecordingFormat.REC_FRAME)
        pending.write(length shr 8)
        pending.write(length and 0xff)
        pending.write(data, offset, length)
        if (pending.size() >= 32 * 1024) flush(false)
    }

    /** Writes what's buffered if a second has passed, so a crash loses little. */
    fun flushIfDue() {
        if (pending.size() > 0 && System.nanoTime() - lastFlush > 1_000_000_000L) flush(false)
    }

    fun finish() {
        if (closed) return
        closed = true
        try {
            if (!poisoned) {
                pending.write(RecordingFormat.REC_END)
                flush(true)
                out.fd.sync()
            }
        } finally {
            out.close()
            key.fill(0)
        }
    }

    private fun flush(final: Boolean) {
        check(!poisoned) { "an earlier write failed" }
        val plain = pending.toByteArray()
        pending.reset()
        // Claim the index before writing: if the write fails after part of
        // it reached the disk, nothing else is ever sealed under this nonce.
        val i = index++
        try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, RecordingFormat.nonce(i)))
            c.updateAAD(RecordingFormat.aad(i, final))
            val sealed = c.doFinal(plain)
            out.write(ByteBuffer.allocate(4).putInt(sealed.size).array())
            out.write(sealed)
            out.flush()
            out.fd.sync()
        } catch (e: Exception) {
            poisoned = true
            throw e
        } finally {
            plain.fill(0)
        }
        lastFlush = System.nanoTime()
    }
}

/** A recording decrypted in memory. */
class Recording(
    val startedAtMs: Long,
    val sampleRate: Int,
    val channels: Int,
    val csd: ByteArray,
    val frames: List<ByteArray>,
    /** False when the recording was cut short (phone died) or damaged. */
    val complete: Boolean,
) {
    val durationMs: Long get() = frames.size * 1024L * 1000L / maxOf(1, sampleRate)

    fun wipe() {
        frames.forEach { it.fill(0) }
    }
}

object RecordingReader {
    /**
     * Decrypts [file] with the vault's private key. Returns null if it isn't
     * this vault's recording (or is unreadable from the first segment).
     */
    fun open(file: File, vaultPrivateKey: ByteArray): Recording? {
        DataInputStream(FileInputStream(file).buffered()).use { inp ->
            val pubLen = try {
                inp.readUnsignedShort()
            } catch (_: EOFException) {
                return null
            }
            if (pubLen !in 1..512) return null
            val ephPub = ByteArray(pubLen)
            try {
                inp.readFully(ephPub)
            } catch (_: EOFException) {
                return null
            }
            val key = try {
                RecordingFormat.fileKey(RecordingFormat.privateKey(vaultPrivateKey), RecordingFormat.publicKey(ephPub), ephPub)
            } catch (_: Exception) {
                return null
            }
            val plain = ByteArrayOutputStream()
            var index = 0L
            var finalSeen = false
            try {
                while (!finalSeen) {
                    val len = try {
                        inp.readInt()
                    } catch (_: EOFException) {
                        break
                    }
                    if (len !in 16..(16 * 1024 * 1024)) break
                    val sealed = ByteArray(len)
                    try {
                        inp.readFully(sealed)
                    } catch (_: EOFException) {
                        break
                    }
                    val opened = decrypt(key, index, false, sealed)
                        ?: decrypt(key, index, true, sealed)?.also { finalSeen = true }
                    if (opened == null) {
                        if (index == 0L) return null
                        break
                    }
                    plain.write(opened)
                    opened.fill(0)
                    index++
                }
            } finally {
                key.fill(0)
            }
            return parse(plain.toByteArray(), finalSeen)
        }
    }

    private fun decrypt(key: ByteArray, index: Long, final: Boolean, sealed: ByteArray): ByteArray? = try {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, RecordingFormat.nonce(index)))
        c.updateAAD(RecordingFormat.aad(index, final))
        c.doFinal(sealed)
    } catch (_: Exception) {
        null
    }

    private fun parse(data: ByteArray, finalSeen: Boolean): Recording {
        val b = ByteBuffer.wrap(data)
        var startedAt = 0L
        var sampleRate = 0
        var channels = 1
        var csd = ByteArray(0)
        val frames = ArrayList<ByteArray>()
        var ended = false
        try {
            while (b.hasRemaining() && !ended) {
                when (b.get().toInt()) {
                    RecordingFormat.REC_CONFIG -> {
                        startedAt = b.long
                        sampleRate = b.int
                        channels = b.get().toInt()
                        csd = ByteArray(b.short.toInt() and 0xffff).also { b.get(it) }
                    }
                    RecordingFormat.REC_FRAME -> {
                        val len = b.short.toInt() and 0xffff
                        frames.add(ByteArray(len).also { b.get(it) })
                    }
                    RecordingFormat.REC_END -> ended = true
                    else -> break
                }
            }
        } catch (_: Exception) {
            // Truncated record at the end of a cut-short recording.
        }
        data.fill(0)
        // Decrypted with this vault's key but no audio (the recorder failed
        // before the encoder started, or the phone died in the first
        // second): the owner gets an empty recording and discards it.
        return Recording(startedAt, sampleRate, channels, csd, frames, finalSeen && ended)
    }
}

/** Packs AAC frames into a playable file, in memory. */
object RecordingPacker {
    /** M4A (seekable, with a duration) on Android 11+, else ADTS (.aac). */
    fun pack(r: Recording): Pair<ByteArray, String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) m4a(r) to "m4a" else adts(r) to "aac"

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.R)
    private fun m4a(r: Recording): ByteArray {
        // MediaMuxer needs a seekable file: an in-memory one, never on disk.
        val fd = Os.memfd_create("rec", 0)
        try {
            val muxer = MediaMuxer(fd, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, r.sampleRate, r.channels)
            format.setByteBuffer("csd-0", ByteBuffer.wrap(r.csd))
            val track = muxer.addTrack(format)
            muxer.start()
            val info = MediaCodec.BufferInfo()
            r.frames.forEachIndexed { i, frame ->
                info.set(0, frame.size, i * 1024L * 1_000_000L / r.sampleRate, MediaCodec.BUFFER_FLAG_KEY_FRAME)
                muxer.writeSampleData(track, ByteBuffer.wrap(frame), info)
            }
            muxer.stop()
            muxer.release()
            val size = Os.fstat(fd).st_size.toInt()
            Os.lseek(fd, 0, OsConstants.SEEK_SET)
            val out = ByteArray(size)
            var off = 0
            while (off < size) {
                val n = Os.read(fd, out, off, size - off)
                if (n <= 0) break
                off += n
            }
            return out
        } finally {
            Os.close(fd)
        }
    }

    private val SAMPLE_RATES = intArrayOf(96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)

    private fun adts(r: Recording): ByteArray {
        val sfi = SAMPLE_RATES.indexOf(r.sampleRate).let { if (it < 0) 4 else it }
        val out = ByteArrayOutputStream()
        for (f in r.frames) {
            val len = f.size + 7
            val h = ByteArray(7)
            h[0] = 0xFF.toByte()
            h[1] = 0xF1.toByte()
            h[2] = ((1 shl 6) or (sfi shl 2) or (r.channels shr 2)).toByte() // profile LC
            h[3] = (((r.channels and 3) shl 6) or (len shr 11)).toByte()
            h[4] = ((len shr 3) and 0xFF).toByte()
            h[5] = (((len and 7) shl 5) or 0x1F).toByte()
            h[6] = 0xFC.toByte()
            out.write(h)
            out.write(f)
        }
        return out.toByteArray()
    }
}
