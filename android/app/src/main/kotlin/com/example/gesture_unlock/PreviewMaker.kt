package com.example.gesture_unlock

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.Metadata
import androidx.media3.common.MimeTypes
import androidx.media3.effect.Presentation
import androidx.media3.muxer.BufferInfo
import androidx.media3.muxer.Muxer
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import com.google.common.collect.ImmutableList
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Small copies of photos, videos and recordings, which backup sends first
 * on a bad connection (SYNC_DESIGN §5). Nothing is written in the clear:
 *
 *  - a photo is decoded in the isolated renderer ([PdfSandbox]), scaled to
 *    at most 1600 px, and re-encoded here as JPEG, in memory;
 *  - a video or recording is read from the vault's own loopback stream
 *    (the one its player uses), transcoded by Media3 Transformer, and the
 *    encoded samples go straight into a staging file sealed to a key pair
 *    that exists only in memory for this one preview (the records the
 *    camera writes); the MP4 is then read out as a stream by [Mp4Exporter],
 *    as often as backup needs, and the staging file is shredded at close.
 *
 * A staging file left by a killed app can't be opened by anyone (its key
 * died with the process) and is shredded on the next start.
 */
class PreviewMaker(private val context: Context, private val sandbox: PdfSandbox) {
    companion object {
        const val VIDEO_SHORT_SIDE = 480
        const val VIDEO_BITRATE = 600_000
        const val VIDEO_AUDIO_BITRATE = 64_000
        const val AUDIO_BITRATE = 32_000
        const val PHOTO_SIDE = 1600
        const val PHOTO_QUALITY = 75
        private const val VIDEO_TRACK = 1
        private const val AUDIO_TRACK = 2
    }

    private class Job(val file: File, val publicKey: ByteArray, val privateKey: ByteArray) {
        var transformer: Transformer? = null
        var exporter: Mp4Exporter? = null
        var length = 0L
    }

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val jobs = HashMap<Int, Job>()
    private var nextId = 1
    private val dir: File by lazy { File(context.noBackupFilesDir, "pv").apply { mkdirs() } }

    init {
        io.execute { dir.listFiles()?.forEach { RecordingFormat.shred(it) } }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "image" -> {
                val data = call.argument<ByteArray>("data")!!
                io.execute {
                    val out = try {
                        image(data)
                    } catch (e: Exception) {
                        null
                    }
                    main.post { result.success(out) }
                }
            }
            "transcode" -> {
                val url = call.argument<String>("url")!!
                val audioOnly = call.argument<Boolean>("audio") == true
                // Only ever scale down: probe the size first (network I/O,
                // so not on the main thread), then start on the main looper.
                io.execute {
                    val shortSide = if (audioOnly) null else shortSide(url)
                    val scale = shortSide == null || shortSide > VIDEO_SHORT_SIDE
                    main.post { transcode(url, audioOnly, scale, result) }
                }
            }
            "open" -> {
                val id = call.argument<Int>("id")!!
                io.execute {
                    val ok = try {
                        reopen(id)
                    } catch (e: Exception) {
                        false
                    }
                    main.post { result.success(ok) }
                }
            }
            "read" -> {
                val id = call.argument<Int>("id")!!
                val max = call.argument<Int>("max") ?: (1 shl 20)
                io.execute {
                    try {
                        val job = synchronized(jobs) { jobs[id] } ?: throw IllegalStateException("closed")
                        val out = job.exporter?.read(max) ?: throw IllegalStateException("not open")
                        main.post { result.success(out) }
                    } catch (e: Exception) {
                        main.post { result.error("read", e.message, null) }
                    }
                }
            }
            "close" -> {
                close(call.argument<Int>("id")!!)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** A JPEG of at most [PHOTO_SIDE] px, or null if the renderer can't decode it. */
    private fun image(data: ByteArray): ByteArray? {
        val decoded = sandbox.decodeImage(data, PHOTO_SIDE, PHOTO_SIDE.toLong() * PHOTO_SIDE) ?: return null
        val (w, h, rgba) = decoded
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        try {
            bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
            rgba.fill(0)
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, PHOTO_QUALITY, out)
            return out.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }

    /** The video's shorter side, or null if it can't be read. */
    private fun shortSide(url: String): Int? {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(url, HashMap())
            val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
            val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
            if (w != null && h != null) minOf(w, h) else null
        } catch (e: Exception) {
            null
        } finally {
            r.release()
        }
    }

    private fun transcode(url: String, audioOnly: Boolean, scale: Boolean, result: MethodChannel.Result) {
        val (pub, priv) = RecordingFormat.newVaultKeyPair()
        val name = ByteArray(12).also { java.security.SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
        val job = Job(File(dir, "$name.bin"), pub, priv)
        val id = synchronized(jobs) { nextId++.also { jobs[it] = job } }
        val encoders = DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(VIDEO_BITRATE).build())
            .setRequestedAudioEncoderSettings(
                AudioEncoderSettings.Builder().setBitrate(if (audioOnly) AUDIO_BITRATE else VIDEO_AUDIO_BITRATE).build(),
            )
            .build()
        val item = EditedMediaItem.Builder(MediaItem.fromUri(url))
            .setRemoveVideo(audioOnly)
            .setEffects(
                if (audioOnly || !scale) Effects.EMPTY
                else Effects(listOf(), listOf(Presentation.createForShortSide(VIDEO_SHORT_SIDE))),
            )
            .build()
        val transformer = Transformer.Builder(context)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .setEncoderFactory(encoders)
            .setMuxerFactory(StagingMuxer.Factory(job.file, pub))
            .setLooper(Looper.getMainLooper())
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    job.transformer = null
                    io.execute {
                        val ok = try {
                            reopen(id)
                        } catch (e: Exception) {
                            false
                        }
                        main.post {
                            if (ok) {
                                result.success(mapOf("id" to id, "length" to job.length))
                            } else {
                                close(id)
                                result.error("export", "the preview couldn't be read back", null)
                            }
                        }
                    }
                }

                override fun onError(composition: Composition, exportResult: ExportResult, e: ExportException) {
                    job.transformer = null
                    close(id)
                    result.error("transcode", "${e.errorCodeName}: ${e.message}", null)
                }
            })
            .build()
        job.transformer = transformer
        // The path only names the job: [StagingMuxer] writes [Job.file].
        transformer.start(item, File(dir, "$name.mp4").path)
    }

    /** (Re)opens the preview's MP4 stream at its start. */
    private fun reopen(id: Int): Boolean {
        val job = synchronized(jobs) { jobs[id] } ?: return false
        job.exporter?.close()
        val exporter = Mp4Exporter.open(job.file, job.publicKey, job.privateKey) ?: return false
        job.exporter = exporter
        job.length = exporter.length
        return true
    }

    private fun close(id: Int) {
        val job = synchronized(jobs) { jobs.remove(id) } ?: return
        job.transformer?.cancel()
        io.execute {
            try {
                job.exporter?.close()
            } catch (_: Exception) {
            }
            RecordingFormat.shred(job.file)
            job.privateKey.fill(0)
        }
    }

    /**
     * Takes Transformer's encoded samples and writes them sealed, as the
     * camera's staging records (see [VideoRecorder]), never as a file in
     * the clear.
     */
    private class StagingMuxer(file: File, vaultKey: ByteArray) : Muxer {
        class Factory(private val file: File, private val vaultKey: ByteArray) : Muxer.Factory {
            override fun create(path: String): Muxer = StagingMuxer(file, vaultKey)
            override fun getSupportedSampleMimeTypes(trackType: Int): ImmutableList<String> = when (trackType) {
                C.TRACK_TYPE_VIDEO -> ImmutableList.of(MimeTypes.VIDEO_H264)
                C.TRACK_TYPE_AUDIO -> ImmutableList.of(MimeTypes.AUDIO_AAC)
                else -> ImmutableList.of()
            }
        }

        private val writer = SegmentWriter(file, vaultKey)
        private val video = HashSet<Int>()
        private var closed = false

        init {
            writer.pending.write(
                ByteBuffer.allocate(9).put(RecordingFormat.REC_START.toByte()).putLong(0L).array(),
            )
        }

        override fun addTrack(format: Format): Int {
            val isVideo = MimeTypes.isVideo(format.sampleMimeType)
            val track = if (isVideo) VIDEO_TRACK else AUDIO_TRACK
            if (isVideo) video.add(track)
            val mime = (format.sampleMimeType ?: "").toByteArray()
            val a = if (isVideo) format.width else format.sampleRate
            val b = if (isVideo) format.height else format.channelCount
            val csd = format.initializationData
            val out = ByteArrayOutputStream()
            out.write(
                ByteBuffer.allocate(5).put(RecordingFormat.REC_TRACK.toByte()).put(track.toByte())
                    .put(if (isVideo) 2 else 1).putShort(mime.size.toShort()).array(),
            )
            out.write(mime)
            out.write(
                ByteBuffer.allocate(11).putInt(a).putInt(b)
                    .putShort((if (isVideo) format.rotationDegrees else 0).toShort()).put(csd.size.toByte()).array(),
            )
            for (c in csd) {
                out.write(ByteBuffer.allocate(4).putInt(c.size).array())
                out.write(c)
            }
            writer.pending.write(out.toByteArray())
            return track
        }

        override fun writeSampleData(trackId: Int, data: ByteBuffer, bufferInfo: BufferInfo) {
            val raw = ByteArray(bufferInfo.size)
            data.duplicate().get(raw)
            val isVideo = trackId in video
            val out = if (isVideo) Mp4Writer.toLengthPrefixed(raw, 0, raw.size) else raw
            val key = !isVideo || bufferInfo.flags and C.BUFFER_FLAG_KEY_FRAME != 0
            writer.pending.write(
                ByteBuffer.allocate(15).put(RecordingFormat.REC_SAMPLE.toByte()).put(trackId.toByte())
                    .put(if (key) 1 else 0).putLong(bufferInfo.presentationTimeUs).putInt(out.size).array(),
            )
            writer.pending.write(out)
            raw.fill(0)
            if (out !== raw) out.fill(0)
            if (writer.pending.size() >= 512 * 1024 || writer.due()) writer.flush()
        }

        override fun addMetadataEntry(metadataEntry: Metadata.Entry) {
            // No metadata: a preview carries no place, time or device.
        }

        override fun close() {
            if (closed) return
            closed = true
            writer.finish()
        }
    }
}
