package com.example.gesture_unlock

import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.system.Os
import android.system.OsConstants
import java.io.ByteArrayOutputStream
import java.io.Closeable
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
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Recordings (audio, and video from the in-vault camera) made while the
 * vault may be locked.
 *
 * The vault holds a P-256 key pair; only its public half is handed to the
 * recorder. Each recording gets a fresh ephemeral key pair, and the file key
 * is HKDF(ECDH(ephemeral, vault public key)). So the phone can *write* a
 * recording at any time but can't read it back: that needs the vault's
 * private key, which exists only inside the encrypted vault index. The
 * ephemeral private key is discarded as soon as the file key is derived.
 *
 * File layout, v2 (written since v2.2; every byte looks random to anyone
 * without the vault's public key, which also lives only inside the vault):
 *   salt (16 random bytes)
 *   header: AES-CTR(K_h, iv 0)( u16 length ‖ ephemeral public key (X.509) ‖ 0⁸ )
 *     K_h = HKDF(vault public key, salt, "rec/v2 hdr"); the zeros let the
 *     owner recognise its own files even before any audio was written
 *   segments: (u32 length XOR mask(i)) ‖ AES-256-GCM(ciphertext ‖ tag)
 *     mask(i) = first 4 bytes of AES-ECB(K_h, FF⁸ ‖ u64 i)
 *     nonce = 0⁴ ‖ u64 i, aad = "rec/v2" ‖ u64 i ‖ final flag
 *     file key = HKDF(ECDH, zero salt, "rec/v2" ‖ ephemeral public key)
 *
 * v1 (v2.1.0): u16 length ‖ ephemeral public key in the clear, then
 * u32 length ‖ sealed segments, with "rec/v1" in place of "rec/v2". Still
 * read, so recordings staged by v2.1.0 move in after an update.
 *
 * Segment plaintexts concatenate into records, and a record never spans two
 * segments:
 *   audio: 1 config: u64 start time (ms), u32 sample rate, u8 channels,
 *                    u16 len, AAC config
 *          2 frame:  u16 len, one AAC access unit (1024 samples)
 *   video (see [MediaRecording]):
 *          0x12 start: u64 start time (ms)
 *          0x10 track: u8 id, u8 kind (1 audio, 2 video), u16 len, MIME,
 *                      u32 a, u32 b (rate and channels, or width and height),
 *                      u16 rotation, u8 count, (u32 len, codec config)…
 *          0x11 sample: u8 track, u8 flags (1 = sync), u64 time (µs),
 *                       u32 len, data (H.264 as length-prefixed NAL units)
 *   both:  3 end
 * Segments are written about once a second, so if the phone dies mid-way
 * only the last second is lost. The final flag lets a reader tell a finished
 * recording from one cut short.
 */
object RecordingFormat {
    private val INFO = "rec/v1".toByteArray()
    private val INFO2 = "rec/v2".toByteArray()
    private val HEADER_INFO = "rec/v2 hdr".toByteArray()
    private val random = SecureRandom()

    const val SALT_LEN = 16
    private const val CHECK_LEN = 8

    const val REC_CONFIG = 1
    const val REC_FRAME = 2
    const val REC_END = 3
    const val REC_TRACK = 0x10
    const val REC_SAMPLE = 0x11
    const val REC_START = 0x12

    /** Largest segment a reader accepts. */
    const val MAX_SEGMENT = 16 * 1024 * 1024

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

    fun fileKey(own: PrivateKey, peer: PublicKey, ephemeralPublic: ByteArray, v2: Boolean): ByteArray {
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(own)
        ka.doPhase(peer, true)
        val shared = ka.generateSecret()
        try {
            return hkdf(shared, (if (v2) INFO2 else INFO) + ephemeralPublic)
        } finally {
            shared.fill(0)
        }
    }

    /** K_h: hides a v2 file's header and segment lengths. */
    fun headerKey(vaultPublic: ByteArray, salt: ByteArray): ByteArray = hkdf(vaultPublic, HEADER_INFO, salt)

    /** HKDF-SHA256, 32 bytes of output ([salt] defaults to 32 zero bytes). */
    private fun hkdf(ikm: ByteArray, info: ByteArray, salt: ByteArray = ByteArray(32)): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        mac.update(info)
        mac.update(1)
        val okm = mac.doFinal()
        prk.fill(0)
        return okm
    }

    fun nonce(index: Long): ByteArray = ByteArray(12).also { ByteBuffer.wrap(it, 4, 8).putLong(index) }

    fun aad(index: Long, final: Boolean, v2: Boolean): ByteArray =
        (if (v2) INFO2 else INFO) + ByteBuffer.allocate(9).putLong(index).put(if (final) 1 else 0).array()

    /** The AES-CTR stream that hides a v2 header, positioned at its start. */
    fun headerCipher(headerKey: ByteArray, mode: Int): Cipher =
        Cipher.getInstance("AES/CTR/NoPadding").apply {
            init(mode, SecretKeySpec(headerKey, "AES"), IvParameterSpec(ByteArray(16)))
        }

    /** The value XORed into segment [index]'s length (v2). */
    fun lengthMask(headerKey: ByteArray, index: Long): Int {
        val c = Cipher.getInstance("AES/ECB/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(headerKey, "AES"))
        val block = ByteBuffer.allocate(16).putLong(-1L).putLong(index).array()
        return ByteBuffer.wrap(c.doFinal(block)).int
    }

    /** The v2 header plaintext for [ephemeralPublic]. */
    fun headerPlain(ephemeralPublic: ByteArray): ByteArray =
        ByteBuffer.allocate(2 + ephemeralPublic.size + CHECK_LEN)
            .putShort(ephemeralPublic.size.toShort()).put(ephemeralPublic).array()

    fun checkLen(): Int = CHECK_LEN

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

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

/**
 * Writes the encrypted segments of one v2 recording. Callers add whole
 * records to [pending] and call [flush] between records, so a record never
 * spans two segments. Not thread-safe.
 */
class SegmentWriter(
    private val file: File,
    vaultPublicKey: ByteArray,
    /** Tests only: write the v2.1.0 format, to test that it's still read. */
    private val v1: Boolean = false,
) {
    private val out: FileOutputStream
    private val key: ByteArray
    private val headerKey: ByteArray
    val pending = ByteArrayOutputStream()
    private var index = 0L
    private var lastFlush = System.nanoTime()

    /** Bytes written to the file so far. */
    var written = 0L
        private set

    var closed = false
        private set

    /** Set after a failed write: the file is left as it is (cut short). */
    private var poisoned = false

    init {
        // Derive the keys before creating the file, so a failure here leaves
        // nothing behind.
        val g = KeyPairGenerator.getInstance("EC")
        g.initialize(ECGenParameterSpec("secp256r1"))
        val eph = g.generateKeyPair()
        val ephPub = eph.public.encoded
        key = RecordingFormat.fileKey(eph.private, RecordingFormat.publicKey(vaultPublicKey), ephPub, v2 = !v1)
        val salt = RecordingFormat.randomBytes(RecordingFormat.SALT_LEN)
        headerKey = RecordingFormat.headerKey(vaultPublicKey, salt)
        val header = if (v1) {
            ByteBuffer.allocate(2 + ephPub.size).putShort(ephPub.size.toShort()).put(ephPub).array()
        } else {
            RecordingFormat.headerCipher(headerKey, Cipher.ENCRYPT_MODE).doFinal(RecordingFormat.headerPlain(ephPub))
        }
        out = FileOutputStream(file)
        try {
            if (!v1) out.write(salt)
            out.write(header)
            out.flush()
            written = (if (v1) 0 else salt.size).toLong() + header.size
        } catch (e: Exception) {
            out.close()
            file.delete()
            key.fill(0)
            headerKey.fill(0)
            throw e
        }
    }

    /** Whether a second has passed since the last segment. */
    fun due(): Boolean = pending.size() > 0 && System.nanoTime() - lastFlush > 1_000_000_000L

    /** Ends the file with an end record. */
    fun finish() {
        if (closed) return
        closed = true
        try {
            if (!poisoned) {
                pending.write(RecordingFormat.REC_END)
                flush(true)
            }
        } finally {
            out.close()
            key.fill(0)
            headerKey.fill(0)
        }
    }

    fun flush(final: Boolean = false) {
        check(!poisoned) { "an earlier write failed" }
        val plain = pending.toByteArray()
        pending.reset()
        // Claim the index before writing: if the write fails after part of
        // it reached the disk, nothing else is ever sealed under this nonce.
        val i = index++
        try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, RecordingFormat.nonce(i)))
            c.updateAAD(RecordingFormat.aad(i, final, v2 = !v1))
            val sealed = c.doFinal(plain)
            val len = if (v1) sealed.size else sealed.size xor RecordingFormat.lengthMask(headerKey, i)
            out.write(ByteBuffer.allocate(4).putInt(len).array())
            out.write(sealed)
            out.flush()
            out.fd.sync()
            written += 4 + sealed.size
        } catch (e: Exception) {
            poisoned = true
            throw e
        } finally {
            plain.fill(0)
        }
        lastFlush = System.nanoTime()
    }
}

/** Writes one encrypted audio recording (AAC frames). Not thread-safe. */
class RecordingWriter(file: File, vaultPublicKey: ByteArray, v1: Boolean = false) {
    private val w = SegmentWriter(file, vaultPublicKey, v1)

    val closed: Boolean get() = w.closed

    fun config(startedAtMs: Long, sampleRate: Int, channels: Int, csd: ByteArray) {
        val b = ByteBuffer.allocate(1 + 8 + 4 + 1 + 2 + csd.size)
        b.put(RecordingFormat.REC_CONFIG.toByte()).putLong(startedAtMs).putInt(sampleRate)
            .put(channels.toByte()).putShort(csd.size.toShort()).put(csd)
        w.pending.write(b.array())
    }

    fun frame(data: ByteArray, offset: Int, length: Int) {
        w.pending.write(RecordingFormat.REC_FRAME)
        w.pending.write(length shr 8)
        w.pending.write(length and 0xff)
        w.pending.write(data, offset, length)
        if (w.pending.size() >= 32 * 1024) w.flush()
    }

    /** Writes what's buffered if a second has passed, so a crash loses little. */
    fun flushIfDue() {
        if (w.due()) w.flush()
    }

    fun finish() = w.finish()
}

/**
 * Reads the segments of one recording (v2 or v1), verified, in order. Open
 * with [open]; [next] returns each segment's plaintext until the end, a cut,
 * or damage. Not thread-safe.
 */
class SegmentReader private constructor(
    private val inp: DataInputStream,
    private val key: ByteArray,
    private val headerKey: ByteArray?,
) : Closeable {
    private var index = 0L
    private var ended = false

    /** Whether the last segment was marked final (the recording finished). */
    var finalSeen = false
        private set

    val v2: Boolean get() = headerKey != null

    companion object {
        /**
         * Opens [file] with a vault's key pair. Returns null if the file
         * isn't that vault's (or is unreadable from the start). [publicKey]
         * is needed for v2 files; v1 files need only the private key.
         */
        fun open(file: File, publicKey: ByteArray?, privateKey: ByteArray): SegmentReader? {
            if (publicKey != null) openV2(file, publicKey, privateKey)?.let { return it }
            return openV1(file, privateKey)
        }

        private fun stream(file: File) = DataInputStream(FileInputStream(file).buffered(256 * 1024))

        private fun openV2(file: File, publicKey: ByteArray, privateKey: ByteArray): SegmentReader? {
            val inp = stream(file)
            var keep = false
            try {
                val salt = ByteArray(RecordingFormat.SALT_LEN)
                inp.readFully(salt)
                val hk = RecordingFormat.headerKey(publicKey, salt)
                val ctr = RecordingFormat.headerCipher(hk, Cipher.DECRYPT_MODE)
                val lenBytes = ctr.update(ByteArray(2).also { inp.readFully(it) })
                val pubLen = ByteBuffer.wrap(lenBytes).short.toInt() and 0xffff
                if (pubLen !in 32..256) {
                    hk.fill(0)
                    return null
                }
                val rest = ctr.doFinal(ByteArray(pubLen + RecordingFormat.checkLen()).also { inp.readFully(it) })
                if (rest.copyOfRange(pubLen, rest.size).any { it.toInt() != 0 }) {
                    hk.fill(0)
                    return null
                }
                val ephPub = rest.copyOfRange(0, pubLen)
                val key = try {
                    RecordingFormat.fileKey(RecordingFormat.privateKey(privateKey), RecordingFormat.publicKey(ephPub), ephPub, v2 = true)
                } catch (_: Exception) {
                    hk.fill(0)
                    return null
                }
                keep = true
                return SegmentReader(inp, key, hk)
            } catch (_: Exception) {
                return null
            } finally {
                if (!keep) inp.close()
            }
        }

        private fun openV1(file: File, privateKey: ByteArray): SegmentReader? {
            val inp = stream(file)
            var keep = false
            try {
                val pubLen = inp.readUnsignedShort()
                if (pubLen !in 1..512) return null
                val ephPub = ByteArray(pubLen)
                inp.readFully(ephPub)
                val key = try {
                    RecordingFormat.fileKey(RecordingFormat.privateKey(privateKey), RecordingFormat.publicKey(ephPub), ephPub, v2 = false)
                } catch (_: Exception) {
                    return null
                }
                val r = SegmentReader(inp, key, null)
                // v1 has no check value: the first segment must open.
                val first = r.next()
                if (first == null && r.index == 0L && r.sawSegment) {
                    r.close()
                    return null
                }
                r.firstV1 = first
                keep = true
                return r
            } catch (_: Exception) {
                return null
            } finally {
                if (!keep) inp.close()
            }
        }
    }

    /** v1 only: the first segment, read while checking ownership. */
    private var firstV1: ByteArray? = null
    private var sawSegment = false

    /** The next segment's plaintext, or null at the end, a cut or damage. */
    fun next(): ByteArray? {
        firstV1?.let {
            firstV1 = null
            return it
        }
        if (ended) return null
        val raw = try {
            inp.readInt()
        } catch (_: EOFException) {
            ended = true
            return null
        }
        sawSegment = true
        val len = if (headerKey != null) raw xor RecordingFormat.lengthMask(headerKey, index) else raw
        if (len !in 16..RecordingFormat.MAX_SEGMENT) {
            ended = true
            return null
        }
        val sealed = ByteArray(len)
        try {
            inp.readFully(sealed)
        } catch (_: EOFException) {
            ended = true
            return null
        }
        val opened = decrypt(index, false, sealed)
            ?: decrypt(index, true, sealed)?.also { finalSeen = true }
        if (opened == null) {
            ended = true
            return null
        }
        index++
        if (finalSeen) ended = true
        return opened
    }

    /** Segments read so far. */
    val count: Long get() = index

    private fun decrypt(i: Long, final: Boolean, sealed: ByteArray): ByteArray? = try {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, RecordingFormat.nonce(i)))
        c.updateAAD(RecordingFormat.aad(i, final, v2 = headerKey != null))
        c.doFinal(sealed)
    } catch (_: Exception) {
        null
    }

    override fun close() {
        key.fill(0)
        headerKey?.fill(0)
        firstV1?.fill(0)
        try {
            inp.close()
        } catch (_: Exception) {
        }
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
    /** What a staged file holds, as far as its first segment tells. */
    enum class Kind { AUDIO, VIDEO, EMPTY }

    /**
     * Whether [file] belongs to the vault with this key pair, and if so what
     * it holds. Null if it's another vault's.
     */
    fun probe(file: File, publicKey: ByteArray?, privateKey: ByteArray): Kind? {
        val r = SegmentReader.open(file, publicKey, privateKey) ?: return null
        r.use {
            val first = it.next() ?: return Kind.EMPTY
            val kind = when (first.firstOrNull()?.toInt()) {
                RecordingFormat.REC_START, RecordingFormat.REC_TRACK -> Kind.VIDEO
                RecordingFormat.REC_CONFIG, RecordingFormat.REC_FRAME -> Kind.AUDIO
                else -> Kind.EMPTY
            }
            first.fill(0)
            return kind
        }
    }

    /**
     * Decrypts an audio recording with the vault's key pair. Returns null if
     * it isn't this vault's recording (or is unreadable from the start).
     */
    fun open(file: File, publicKey: ByteArray?, privateKey: ByteArray): Recording? {
        val r = SegmentReader.open(file, publicKey, privateKey) ?: return null
        val plain = ByteArrayOutputStream()
        r.use {
            while (true) {
                val seg = it.next() ?: break
                plain.write(seg)
                seg.fill(0)
            }
            return parse(plain.toByteArray(), it.finalSeen)
        }
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
