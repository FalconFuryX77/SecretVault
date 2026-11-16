package com.example.gesture_unlock

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.nio.ByteBuffer

/**
 * Turns a staged camera video (encrypted records, see [RecordingFormat]) into
 * an MP4 file *as a stream*, so a video of any length moves into the vault
 * without ever existing in the clear, in memory as a whole or on disk.
 *
 * Pass 1 ([scan]) decrypts the file once and keeps only the sample table
 * (sizes, times, sync flags). That fixes every offset, so the complete
 * header (`ftyp` + `moov`, with the index first, "fast start") is written
 * before any media. Pass 2 ([Mp4Exporter.read]) decrypts the file again and
 * hands out the samples in the order they were recorded, as the `mdat` body.
 * Every segment is authenticated on both passes, and pass 2 must find the
 * same samples as pass 1 or the export fails.
 *
 * The MP4 carries no device, place or time metadata.
 */
class MediaTrack(
    val id: Int,
    val kind: Int, // 1 audio, 2 video
    val mime: String,
    val a: Int, // sample rate, or width
    val b: Int, // channels, or height
    val rotation: Int,
    val csd: List<ByteArray>,
) {
    val isVideo: Boolean get() = kind == 2
}

/** The sample table of one staged video, from [MediaScan.scan]. */
class MediaScan(
    val startedAtMs: Long,
    val tracks: List<MediaTrack>,
    val sampleTrack: ByteArray,
    val sampleSize: IntArray,
    val samplePts: LongArray,
    val sampleSync: BooleanArray,
    val count: Int,
    /** False if the recording was cut short (phone died) or damaged. */
    val complete: Boolean,
) {
    val payloadBytes: Long get() {
        var n = 0L
        for (i in 0 until count) n += sampleSize[i]
        return n
    }

    val durationMs: Long get() {
        if (count == 0) return 0
        var lo = Long.MAX_VALUE
        var hi = Long.MIN_VALUE
        for (i in 0 until count) {
            lo = minOf(lo, samplePts[i])
            hi = maxOf(hi, samplePts[i])
        }
        return (hi - lo) / 1000
    }

    companion object {
        /**
         * Reads the sample table of [file]. Null if it isn't this vault's,
         * or isn't a video.
         */
        fun scan(file: File, publicKey: ByteArray?, privateKey: ByteArray): MediaScan? {
            val reader = SegmentReader.open(file, publicKey, privateKey) ?: return null
            reader.use { r ->
                var startedAt = 0L
                val tracks = LinkedHashMap<Int, MediaTrack>()
                var cap = 4096
                var track = ByteArray(cap)
                var size = IntArray(cap)
                var pts = LongArray(cap)
                var sync = BooleanArray(cap)
                var n = 0
                var ended = false
                var video = false
                outer@ while (!ended) {
                    val seg = r.next() ?: break
                    val b = ByteBuffer.wrap(seg)
                    try {
                        while (b.hasRemaining()) {
                            when (b.get().toInt() and 0xff) {
                                RecordingFormat.REC_START -> {
                                    startedAt = b.long
                                    video = true
                                }
                                RecordingFormat.REC_TRACK -> {
                                    val t = readTrack(b)
                                    if (tracks.containsKey(t.id)) break@outer
                                    tracks[t.id] = t
                                    video = true
                                }
                                RecordingFormat.REC_SAMPLE -> {
                                    val id = b.get().toInt() and 0xff
                                    val flags = b.get().toInt()
                                    val time = b.long
                                    val len = b.int
                                    if (len < 0 || len > b.remaining() || !tracks.containsKey(id)) break@outer
                                    b.position(b.position() + len)
                                    if (n == cap) {
                                        cap *= 2
                                        track = track.copyOf(cap)
                                        size = size.copyOf(cap)
                                        pts = pts.copyOf(cap)
                                        sync = sync.copyOf(cap)
                                    }
                                    track[n] = id.toByte()
                                    size[n] = len
                                    pts[n] = time
                                    sync[n] = flags and 1 != 0
                                    n++
                                }
                                RecordingFormat.REC_END -> {
                                    ended = true
                                    break
                                }
                                else -> break@outer
                            }
                        }
                    } catch (_: Exception) {
                        // A record cut short: keep what came before it.
                        break
                    } finally {
                        seg.fill(0)
                    }
                }
                if (!video) return null
                return MediaScan(startedAt, tracks.values.toList(), track, size, pts, sync, n, r.finalSeen && ended)
            }
        }

        private fun readTrack(b: ByteBuffer): MediaTrack {
            val id = b.get().toInt() and 0xff
            val kind = b.get().toInt()
            val mime = String(ByteArray(b.short.toInt() and 0xffff).also { b.get(it) })
            val x = b.int
            val y = b.int
            val rotation = b.short.toInt() and 0xffff
            val count = b.get().toInt() and 0xff
            val csd = ArrayList<ByteArray>()
            repeat(count) {
                val len = b.int
                require(len in 0..65536)
                csd.add(ByteArray(len).also { b.get(it) })
            }
            return MediaTrack(id, kind, mime, x, y, rotation, csd)
        }
    }
}

/**
 * Streams the MP4 for one staged video: [length] bytes in all, handed out
 * by [read]. Not thread-safe.
 */
class Mp4Exporter private constructor(
    private val file: File,
    private val publicKey: ByteArray?,
    private val privateKey: ByteArray,
    val scan: MediaScan,
) : Closeable {
    private val header: ByteArray
    val length: Long
    private var headerAt = 0
    private var reader: SegmentReader? = null
    private var sample = 0
    private var pendingSeg: ByteBuffer? = null
    private var current: ByteArray? = null
    private var currentAt = 0

    companion object {
        /** Null if [file] isn't this vault's video (or has no samples). */
        fun open(file: File, publicKey: ByteArray?, privateKey: ByteArray): Mp4Exporter? {
            val scan = MediaScan.scan(file, publicKey, privateKey) ?: return null
            return Mp4Exporter(file, publicKey, privateKey.copyOf(), scan)
        }
    }

    init {
        header = Mp4Writer.header(scan)
        length = header.size + scan.payloadBytes
    }

    /** Up to [max] more bytes; empty once all [length] bytes were read. */
    fun read(max: Int): ByteArray {
        val out = ByteArrayOutputStream(minOf(max, 4 shl 20))
        while (out.size() < max) {
            if (headerAt < header.size) {
                val n = minOf(max - out.size(), header.size - headerAt)
                out.write(header, headerAt, n)
                headerAt += n
                continue
            }
            val cur = current
            if (cur != null && currentAt < cur.size) {
                val n = minOf(max - out.size(), cur.size - currentAt)
                out.write(cur, currentAt, n)
                currentAt += n
                if (currentAt == cur.size) {
                    cur.fill(0)
                    current = null
                }
                continue
            }
            if (sample >= scan.count) break
            current = nextSample()
            currentAt = 0
        }
        return out.toByteArray()
    }

    /** The data of sample [sample], checked against pass 1. */
    private fun nextSample(): ByteArray {
        while (true) {
            val b = pendingSeg
            if (b != null && b.hasRemaining()) {
                when (b.get().toInt() and 0xff) {
                    RecordingFormat.REC_START -> b.long
                    RecordingFormat.REC_TRACK -> skipTrack(b)
                    RecordingFormat.REC_SAMPLE -> {
                        val id = b.get().toInt() and 0xff
                        b.get()
                        b.long
                        val len = b.int
                        check(id == (scan.sampleTrack[sample].toInt() and 0xff) && len == scan.sampleSize[sample]) {
                            "the video changed between passes"
                        }
                        val data = ByteArray(len).also { b.get(it) }
                        sample++
                        return data
                    }
                    else -> {
                        b.array().fill(0)
                        pendingSeg = null
                    }
                }
                continue
            }
            b?.array()?.fill(0)
            val r = reader ?: (SegmentReader.open(file, publicKey, privateKey)
                ?: throw IllegalStateException("the video can no longer be opened")).also { reader = it }
            val seg = r.next() ?: throw IllegalStateException("the video ended early on the second pass")
            pendingSeg = ByteBuffer.wrap(seg)
        }
    }

    private fun skipTrack(b: ByteBuffer) {
        b.get()
        b.get()
        val mimeLen = b.short.toInt() and 0xffff
        b.position(b.position() + mimeLen + 4 + 4 + 2)
        repeat(b.get().toInt() and 0xff) {
            val len = b.int
            b.position(b.position() + len)
        }
    }

    override fun close() {
        reader?.close()
        pendingSeg?.array()?.fill(0)
        current?.fill(0)
        privateKey.fill(0)
    }
}

/** Builds the `ftyp` + `moov` + `mdat` header of a fast-start MP4. */
object Mp4Writer {
    private const val MOVIE_TIMESCALE = 1000
    private const val VIDEO_TIMESCALE = 90000
    private const val AAC_FRAME = 1024

    private class Timing(
        val timescale: Int,
        val deltas: IntArray,
        val offsets: IntArray?, // composition offsets (ctts), when B-frames reorder
        val startUs: Long, // presentation time of the first presented sample
        val mediaStart: Int, // media time of that sample (elst)
        val duration: Long,
    )

    fun header(scan: MediaScan): ByteArray {
        val tracks = scan.tracks.filter { t -> (0 until scan.count).any { scan.sampleTrack[it].toInt() and 0xff == t.id } }
        val indices = tracks.associate { t ->
            t.id to (0 until scan.count).filter { scan.sampleTrack[it].toInt() and 0xff == t.id }.toIntArray()
        }
        val timings = tracks.associate { t -> t.id to timing(t, indices.getValue(t.id), scan) }
        val t0 = timings.values.minOf { it.startUs }

        val ftyp = box("ftyp") {
            it.str("isom"); it.u32(0x200); it.str("isom"); it.str("iso2"); it.str("avc1"); it.str("mp41")
        }
        // The moov size doesn't depend on the chunk offsets' values, so build
        // it once with zero offsets to learn where the media will start.
        fun moov(mediaStart: Long): ByteArray {
            val offsets = LongArray(scan.count)
            var at = mediaStart
            for (i in 0 until scan.count) {
                offsets[i] = at
                at += scan.sampleSize[i]
            }
            var movieDuration = 0L
            val traks = tracks.mapIndexed { n, t ->
                val tm = timings.getValue(t.id)
                val gapMs = (tm.startUs - t0) / 1000
                val durMs = tm.duration * 1000 / tm.timescale
                movieDuration = maxOf(movieDuration, gapMs + durMs)
                trak(n + 1, t, tm, indices.getValue(t.id), offsets, scan, gapMs, durMs)
            }
            return box("moov") { b ->
                b.raw(box("mvhd") {
                    it.u32(0); it.u32(0); it.u32(0); it.u32(MOVIE_TIMESCALE); it.u32(movieDuration.toInt())
                    it.u32(0x00010000); it.u16(0x0100); it.zeros(10); matrix(it, 0); it.zeros(24); it.u32(tracks.size + 1)
                })
                traks.forEach { b.raw(it) }
            }
        }
        val probe = moov(0)
        val mediaStart = ftyp.size.toLong() + probe.size + 16
        val moov = moov(mediaStart)
        check(moov.size == probe.size)
        val mdat = ByteBuffer.allocate(16).putInt(1).put("mdat".toByteArray()).putLong(16 + scan.payloadBytes).array()
        return ftyp + moov + mdat
    }

    private fun timing(t: MediaTrack, idx: IntArray, scan: MediaScan): Timing {
        val n = idx.size
        if (!t.isVideo && t.mime == "audio/mp4a-latm") {
            // AAC frames are exactly 1024 samples long: steady deltas, timed
            // from the first frame.
            val deltas = IntArray(n) { AAC_FRAME }
            return Timing(t.a, deltas, null, scan.samplePts[idx[0]], 0, n.toLong() * AAC_FRAME)
        }
        val scale = VIDEO_TIMESCALE
        val pts = LongArray(n) { scan.samplePts[idx[it]] }
        val sorted = pts.sortedArray()
        // Decode times are the sorted presentation times, shifted so no
        // sample is decoded after it's presented.
        var shift = 0L
        for (i in 0 until n) shift = maxOf(shift, sorted[i] - pts[i])
        val dts = LongArray(n) { sorted[it] - shift }
        fun ticks(us: Long) = (us * scale + 500_000) / 1_000_000
        val deltas = IntArray(n)
        for (i in 0 until n - 1) deltas[i] = maxOf(1L, ticks(dts[i + 1]) - ticks(dts[i])).toInt()
        deltas[n - 1] = if (n > 1) deltas[n - 2] else scale / 30
        val reordered = shift > 0 || (0 until n - 1).any { pts[it + 1] <= pts[it] }
        val offsets = if (reordered) IntArray(n) { (ticks(pts[it]) - ticks(dts[it])).toInt() } else null
        val first = sorted[0]
        var duration = 0L
        deltas.forEach { duration += it }
        return Timing(scale, deltas, offsets, first, (ticks(first) - ticks(dts[0])).toInt(), duration)
    }

    private fun trak(
        trackId: Int,
        t: MediaTrack,
        tm: Timing,
        idx: IntArray,
        offsets: LongArray,
        scan: MediaScan,
        gapMs: Long,
        durMs: Long,
    ): ByteArray = box("trak") { trak ->
        trak.raw(box("tkhd") {
            it.u32(0x00000003); it.u32(0); it.u32(0); it.u32(trackId); it.u32(0); it.u32((gapMs + durMs).toInt())
            it.zeros(8); it.u16(0); it.u16(0); it.u16(if (t.isVideo) 0 else 0x0100); it.u16(0)
            matrix(it, if (t.isVideo) t.rotation else 0)
            it.u32(if (t.isVideo) t.a shl 16 else 0); it.u32(if (t.isVideo) t.b shl 16 else 0)
        })
        trak.raw(box("edts") { edts ->
            edts.raw(box("elst") {
                val entries = if (gapMs > 0) 2 else 1
                it.u32(0); it.u32(entries)
                if (gapMs > 0) { it.u32(gapMs.toInt()); it.u32(-1); it.u32(0x00010000) }
                it.u32(durMs.toInt()); it.u32(tm.mediaStart); it.u32(0x00010000)
            })
        })
        trak.raw(box("mdia") { mdia ->
            mdia.raw(box("mdhd") {
                it.u32(0); it.u32(0); it.u32(0); it.u32(tm.timescale); it.u32(tm.duration.toInt()); it.u16(0x55C4); it.u16(0)
            })
            mdia.raw(box("hdlr") {
                it.u32(0); it.u32(0); it.str(if (t.isVideo) "vide" else "soun"); it.zeros(12)
                it.raw((if (t.isVideo) "VideoHandle" else "SoundHandle").toByteArray() + byteArrayOf(0))
            })
            mdia.raw(box("minf") { minf ->
                if (t.isVideo) {
                    minf.raw(box("vmhd") { it.u32(1); it.zeros(8) })
                } else {
                    minf.raw(box("smhd") { it.u32(0); it.zeros(4) })
                }
                minf.raw(box("dinf") { dinf ->
                    dinf.raw(box("dref") { it.u32(0); it.u32(1); it.raw(box("url ") { u -> u.u32(1) }) })
                })
                minf.raw(stbl(t, tm, idx, offsets, scan))
            })
        })
    }

    private fun stbl(t: MediaTrack, tm: Timing, idx: IntArray, offsets: LongArray, scan: MediaScan) = box("stbl") { stbl ->
        stbl.raw(box("stsd") {
            it.u32(0); it.u32(1)
            it.raw(if (t.isVideo) avc1(t) else mp4a(t))
        })
        stbl.raw(box("stts") { b ->
            val runs = ArrayList<Pair<Int, Int>>()
            for (d in tm.deltas) {
                if (runs.isNotEmpty() && runs.last().second == d) runs[runs.size - 1] = runs.last().first + 1 to d
                else runs.add(1 to d)
            }
            b.u32(0); b.u32(runs.size)
            runs.forEach { (count, d) -> b.u32(count); b.u32(d) }
        })
        tm.offsets?.let { off ->
            stbl.raw(box("ctts") { b ->
                val runs = ArrayList<Pair<Int, Int>>()
                for (o in off) {
                    if (runs.isNotEmpty() && runs.last().second == o) runs[runs.size - 1] = runs.last().first + 1 to o
                    else runs.add(1 to o)
                }
                b.u32(0); b.u32(runs.size)
                runs.forEach { (count, o) -> b.u32(count); b.u32(o) }
            })
        }
        if (t.isVideo) {
            val syncs = idx.indices.filter { scan.sampleSync[idx[it]] }
            stbl.raw(box("stss") { b ->
                b.u32(0); b.u32(syncs.size)
                syncs.forEach { b.u32(it + 1) }
            })
        }
        stbl.raw(box("stsc") { it.u32(0); it.u32(1); it.u32(1); it.u32(1); it.u32(1) })
        stbl.raw(box("stsz") { b ->
            b.u32(0); b.u32(0); b.u32(idx.size)
            idx.forEach { b.u32(scan.sampleSize[it]) }
        })
        stbl.raw(box("co64") { b ->
            b.u32(0); b.u32(idx.size)
            idx.forEach { b.u64(offsets[it]) }
        })
    }

    private fun avc1(t: MediaTrack): ByteArray {
        val nals = t.csd.flatMap { splitAnnexB(it) }
        val sps = nals.filter { it.isNotEmpty() && it[0].toInt() and 0x1f == 7 }
        val pps = nals.filter { it.isNotEmpty() && it[0].toInt() and 0x1f == 8 }
        require(sps.isNotEmpty() && pps.isNotEmpty()) { "no H.264 parameter sets" }
        val s0 = sps[0]
        val avcC = box("avcC") { b ->
            b.u8(1); b.u8(s0[1].toInt()); b.u8(s0[2].toInt()); b.u8(s0[3].toInt()); b.u8(0xFF)
            b.u8(0xE0 or sps.size)
            sps.forEach { b.u16(it.size); b.raw(it) }
            b.u8(pps.size)
            pps.forEach { b.u16(it.size); b.raw(it) }
            if ((s0[1].toInt() and 0xff) in setOf(100, 110, 122, 144)) {
                // 4:2:0, 8-bit, no SPS extensions (what phone encoders make).
                b.u8(0xFC or 1); b.u8(0xF8); b.u8(0xF8); b.u8(0)
            }
        }
        return box("avc1") { b ->
            b.zeros(6); b.u16(1); b.zeros(16); b.u16(t.a); b.u16(t.b)
            b.u32(0x00480000); b.u32(0x00480000); b.u32(0); b.u16(1); b.zeros(32); b.u16(0x0018); b.u16(0xFFFF)
            b.raw(avcC)
        }
    }

    private fun mp4a(t: MediaTrack): ByteArray {
        val asc = t.csd.firstOrNull() ?: ByteArray(0)
        fun desc(tag: Int, body: ByteArray) = byteArrayOf(
            tag.toByte(), 0x80.toByte(), 0x80.toByte(), 0x80.toByte(), body.size.toByte(),
        ) + body
        val dsi = desc(0x05, asc)
        val dcd = desc(
            0x04,
            ByteBuffer.allocate(13).put(0x40).put(0x15).put(0).putShort(0x1800)
                .putInt(128000).putInt(128000).array() + dsi,
        )
        val sl = desc(0x06, byteArrayOf(0x02))
        val es = desc(0x03, byteArrayOf(0, 0, 0) + dcd + sl)
        val esds = box("esds") { it.u32(0); it.raw(es) }
        return box("mp4a") { b ->
            b.zeros(6); b.u16(1); b.zeros(8); b.u16(t.b); b.u16(16); b.u16(0); b.u16(0); b.u32(t.a shl 16)
            b.raw(esds)
        }
    }

    /** NAL units of an Annex-B buffer (start codes removed). */
    fun splitAnnexB(data: ByteArray): List<ByteArray> {
        val starts = ArrayList<Pair<Int, Int>>() // (start code position, NAL start)
        var i = 0
        while (i + 2 < data.size) {
            if (data[i].toInt() == 0 && data[i + 1].toInt() == 0) {
                if (data[i + 2].toInt() == 1) {
                    starts.add(i to i + 3)
                    i += 3
                    continue
                }
                if (i + 3 < data.size && data[i + 2].toInt() == 0 && data[i + 3].toInt() == 1) {
                    starts.add(i to i + 4)
                    i += 4
                    continue
                }
            }
            i++
        }
        if (starts.isEmpty()) return listOf(data)
        return starts.mapIndexed { n, (_, from) ->
            val to = if (n + 1 < starts.size) starts[n + 1].first else data.size
            data.copyOfRange(from, to)
        }
    }

    /** An Annex-B access unit as 4-byte-length-prefixed NAL units (MP4). */
    fun toLengthPrefixed(data: ByteArray, offset: Int, length: Int): ByteArray {
        val nals = splitAnnexB(data.copyOfRange(offset, offset + length))
        val out = ByteBuffer.allocate(nals.sumOf { 4 + it.size })
        nals.forEach { out.putInt(it.size); out.put(it) }
        return out.array()
    }

    private fun matrix(b: Buf, rotation: Int) {
        val (a, bb, c, d) = when (rotation) {
            90 -> listOf(0, 0x00010000, -0x00010000, 0)
            180 -> listOf(-0x00010000, 0, 0, -0x00010000)
            270 -> listOf(0, -0x00010000, 0x00010000, 0)
            else -> listOf(0x00010000, 0, 0, 0x00010000)
        }
        b.u32(a); b.u32(bb); b.u32(0); b.u32(c); b.u32(d); b.u32(0); b.u32(0); b.u32(0); b.u32(0x40000000)
    }

    private class Buf {
        val out = ByteArrayOutputStream()
        fun u8(v: Int) = out.write(v and 0xff)
        fun u16(v: Int) { u8(v shr 8); u8(v) }
        fun u32(v: Int) { u16(v ushr 16); u16(v) }
        fun u64(v: Long) { u32((v ushr 32).toInt()); u32(v.toInt()) }
        fun str(s: String) = out.write(s.toByteArray())
        fun zeros(n: Int) = out.write(ByteArray(n))
        fun raw(b: ByteArray) = out.write(b)
    }

    private fun box(type: String, body: (Buf) -> Unit): ByteArray {
        val b = Buf()
        body(b)
        val content = b.out.toByteArray()
        return ByteBuffer.allocate(8 + content.size).putInt(8 + content.size).put(type.toByteArray()).put(content).array()
    }
}
