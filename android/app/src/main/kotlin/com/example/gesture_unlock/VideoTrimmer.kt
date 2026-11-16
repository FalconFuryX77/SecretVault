package com.example.gesture_unlock

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * The cover app: a real video trimmer (channel `app.trim/video`). Picks a
 * video with Android's photo picker (no storage permission), cuts it
 * without re-encoding (at the key frame before the chosen start), optionally
 * without sound, and saves it to Movies/Video Trimmer.
 */
class VideoTrimmer(private val activity: Activity) {
    companion object {
        const val REQUEST_PICK = 0x7101
        const val FOLDER = "Video Trimmer"
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(result)
            "info" -> background(result) { info(Uri.parse(call.argument<String>("uri")!!)) }
            "frame" -> background(result) {
                frame(Uri.parse(call.argument<String>("uri")!!), (call.argument<Number>("timeMs") ?: 0).toLong(), call.argument<Int>("maxSide") ?: 320)
            }
            "trim" -> background(result) {
                trim(
                    Uri.parse(call.argument<String>("uri")!!),
                    (call.argument<Number>("startMs") ?: 0).toLong(),
                    (call.argument<Number>("endMs") ?: 0).toLong(),
                    call.argument<Boolean>("mute") == true,
                )
            }
            "recent" -> background(result) { recent() }
            "delete" -> background(result) { activity.contentResolver.delete(Uri.parse(call.argument<String>("uri")!!), null, null) > 0 }
            "view" -> {
                try {
                    activity.startActivity(
                        Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(call.argument<String>("uri")!!), "video/*")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                    )
                    result.success(true)
                } catch (_: Exception) {
                    result.success(false)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun pick(result: MethodChannel.Result) {
        pending?.success(null)
        pending = result
        val intent = if (Build.VERSION.SDK_INT >= 33) {
            Intent(MediaStore.ACTION_PICK_IMAGES).setType("video/*")
        } else {
            Intent(Intent.ACTION_GET_CONTENT).setType("video/*").addCategory(Intent.CATEGORY_OPENABLE)
        }
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, REQUEST_PICK)
        } catch (_: Exception) {
            pending = null
            result.success(null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK) return false
        val r = pending ?: return true
        pending = null
        r.success(if (resultCode == Activity.RESULT_OK) data?.data?.toString() else null)
        return true
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try {
                val v = block()
                main.post { result.success(v) }
            } catch (e: Throwable) {
                main.post { result.error("trim", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun info(uri: Uri): Map<String, Any?> {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(activity, uri)
            fun num(k: Int) = r.extractMetadata(k)?.toLongOrNull() ?: 0L
            return mapOf(
                "durationMs" to num(MediaMetadataRetriever.METADATA_KEY_DURATION),
                "width" to num(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH),
                "height" to num(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT),
                "rotation" to num(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION),
            )
        } finally {
            r.release()
        }
    }

    /** A JPEG of the frame near [timeMs], at most [maxSide] pixels a side. */
    private fun frame(uri: Uri, timeMs: Long, maxSide: Int): ByteArray? {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(activity, uri)
            val us = timeMs * 1000
            val bmp = if (Build.VERSION.SDK_INT >= 27) {
                r.getScaledFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, maxSide, maxSide)
            } else {
                r.getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            } ?: return null
            val out = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, 80, out)
            bmp.recycle()
            return out.toByteArray()
        } finally {
            r.release()
        }
    }

    /** Cuts [startMs]..[endMs] into a new video in Movies/Video Trimmer. */
    private fun trim(uri: Uri, startMs: Long, endMs: Long, mute: Boolean): String {
        require(endMs > startMs) { "the end must be after the start" }
        val name = "Trim_" + SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date()) + ".mp4"
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            if (Build.VERSION.SDK_INT >= 29) {
                put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/$FOLDER")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
        }
        val resolver = activity.contentResolver
        val collection = if (Build.VERSION.SDK_INT >= 29) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }
        val outUri = resolver.insert(collection, values) ?: throw IllegalStateException("can't save to Movies")
        try {
            val rotation = (info(uri)["rotation"] as Long).toInt()
            resolver.openFileDescriptor(outUri, "rw")!!.use { pfd ->
                val extractor = MediaExtractor()
                extractor.setDataSource(activity, uri, null)
                val muxer = MediaMuxer(pfd.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                try {
                    val map = HashMap<Int, Int>()
                    var maxInput = 1 shl 20
                    for (i in 0 until extractor.trackCount) {
                        val f = extractor.getTrackFormat(i)
                        val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                        val isVideo = mime.startsWith("video/")
                        if (!isVideo && (!mime.startsWith("audio/") || mute)) continue
                        extractor.selectTrack(i)
                        map[i] = muxer.addTrack(f)
                        if (f.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) maxInput = maxOf(maxInput, f.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                    }
                    require(map.isNotEmpty()) { "no video in that file" }
                    muxer.setOrientationHint(rotation)
                    muxer.start()
                    extractor.seekTo(startMs * 1000, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                    val buf = ByteBuffer.allocate(maxInput)
                    val info = MediaCodec.BufferInfo()
                    var base = -1L
                    val endUs = endMs * 1000
                    while (true) {
                        val t = extractor.sampleTrackIndex
                        if (t < 0) break
                        val time = extractor.sampleTime
                        if (time > endUs) break
                        val dst = map[t]
                        if (dst != null) {
                            if (base < 0) base = time
                            if (time >= base) {
                                buf.clear()
                                val n = extractor.readSampleData(buf, 0)
                                if (n > 0) {
                                    info.set(0, n, time - base, extractor.sampleFlags.let {
                                        if (it and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                                    })
                                    muxer.writeSampleData(dst, buf, info)
                                }
                            }
                        }
                        extractor.advance()
                    }
                    muxer.stop()
                } finally {
                    muxer.release()
                    extractor.release()
                }
            }
            if (Build.VERSION.SDK_INT >= 29) {
                resolver.update(outUri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
            }
            return outUri.toString()
        } catch (e: Throwable) {
            resolver.delete(outUri, null, null)
            throw e
        }
    }

    /** Videos this app saved, newest first. */
    private fun recent(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val collection = if (Build.VERSION.SDK_INT >= 29) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }
        val (selection, args) = if (Build.VERSION.SDK_INT >= 29) {
            "${MediaStore.Video.Media.RELATIVE_PATH} LIKE ?" to arrayOf("Movies/$FOLDER%")
        } else {
            "${MediaStore.Video.Media.DISPLAY_NAME} LIKE ?" to arrayOf("Trim_%")
        }
        activity.contentResolver.query(
            collection,
            arrayOf(
                MediaStore.Video.Media._ID,
                MediaStore.Video.Media.DISPLAY_NAME,
                MediaStore.Video.Media.DURATION,
                MediaStore.Video.Media.SIZE,
                MediaStore.Video.Media.DATE_ADDED,
            ),
            selection,
            args,
            "${MediaStore.Video.Media.DATE_ADDED} DESC",
        )?.use { c ->
            while (c.moveToNext() && out.size < 200) {
                val id = c.getLong(0)
                out.add(
                    mapOf(
                        "uri" to android.content.ContentUris.withAppendedId(collection, id).toString(),
                        "name" to c.getString(1),
                        "durationMs" to c.getLong(2),
                        "size" to c.getLong(3),
                        "added" to c.getLong(4) * 1000,
                    ),
                )
            }
        }
        return out
    }
}
