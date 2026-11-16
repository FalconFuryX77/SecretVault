package com.example.gesture_unlock

import android.app.Service
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.pdf.PdfRenderer
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.SharedMemory
import java.io.FileInputStream
import java.nio.ByteBuffer
import kotlin.math.sqrt

/**
 * Draws PDF pages, and decodes images, in an isolated process
 * (`android:isolatedProcess="true"` in the manifest).
 *
 * PDF parsers are a classic way in for malicious documents, and people who
 * get searched also get sent booby-trapped files. Here the parser runs under
 * a throwaway user id with no permissions: no network, no access to the
 * app's files, the vault container or its keys, which stay in the main
 * process. A document that compromises the renderer gets a process that can
 * see that one document and nothing else, and the process is killed as soon
 * as the viewer closes.
 *
 * Image formats (JPEG, PNG, WebP, HEIF, GIF…) are the same kind of target,
 * so vault images are decoded here too.
 *
 * The protocol is plain Binder calls (no AIDL), see [PdfSandbox]:
 *  - OPEN(fd, password?)       -> status, page count, page sizes in points
 *  - SEARCH(query)             -> status, matches (page, rectangles in points)
 *  - RENDER(page, w, h, shmem) -> status; RGBA pixels written into shmem
 *  - CLOSE
 *  - DECODE(fd, maxSide, maxPixels) -> status, width, height (image kept)
 *  - PIXELS(shmem)             -> status; the decoded image's RGBA pixels
 */
class PdfRenderService : Service() {
    companion object {
        const val DESCRIPTOR = "app.vault.render"
        const val OPEN = IBinder.FIRST_CALL_TRANSACTION
        const val RENDER = IBinder.FIRST_CALL_TRANSACTION + 1
        const val CLOSE = IBinder.FIRST_CALL_TRANSACTION + 2
        const val DECODE = IBinder.FIRST_CALL_TRANSACTION + 3
        const val PIXELS = IBinder.FIRST_CALL_TRANSACTION + 4
        const val SEARCH = IBinder.FIRST_CALL_TRANSACTION + 5

        /** Not on this Android version (passwords and search: Android 15). */
        const val UNSUPPORTED = 3

        const val MAX_MATCHES = 1000

        /** Largest encoded image accepted. */
        const val MAX_IMAGE_BYTES = 128L * 1024 * 1024

        const val OK = 0
        const val PASSWORD = 1
        const val BROKEN = 2

        const val MAX_SIDE = 4096
        const val MAX_PIXELS = 4096L * 4096L
    }

    private val lock = Any()
    private var input: ParcelFileDescriptor? = null
    private var renderer: PdfRenderer? = null
    private var image: Bitmap? = null

    private val binder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == INTERFACE_TRANSACTION) {
                reply?.writeString(DESCRIPTOR)
                return true
            }
            if (code !in OPEN..SEARCH) return super.onTransact(code, data, reply, flags)
            data.enforceInterface(DESCRIPTOR)
            // The main process never binds on older versions (see PdfSandbox).
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                reply?.writeInt(BROKEN)
                return true
            }
            try {
                when (code) {
                    OPEN -> {
                        val pfd = data.readFileDescriptor() ?: throw IllegalArgumentException("no document")
                        val password = data.readString()
                        if (password != null && Build.VERSION.SDK_INT < 35) {
                            pfd.close()
                            reply?.writeInt(UNSUPPORTED)
                            return true
                        }
                        val sizes = open(pfd, password)
                        reply?.writeInt(OK)
                        reply?.writeInt(sizes.size / 2)
                        reply?.writeFloatArray(sizes)
                    }
                    RENDER -> {
                        val page = data.readInt()
                        val width = data.readInt()
                        val height = data.readInt()
                        val out = SharedMemory.CREATOR.createFromParcel(data)
                        try {
                            render(page, width, height, out)
                        } finally {
                            out.close()
                        }
                        reply?.writeInt(OK)
                    }
                    CLOSE -> {
                        closeDocument()
                        reply?.writeInt(OK)
                    }
                    SEARCH -> {
                        if (Build.VERSION.SDK_INT < 35) {
                            reply?.writeInt(UNSUPPORTED)
                            return true
                        }
                        val matches = search(data.readString() ?: "")
                        reply?.writeInt(OK)
                        reply?.writeInt(matches.size)
                        for ((page, rects) in matches) {
                            reply?.writeInt(page)
                            reply?.writeFloatArray(rects)
                        }
                    }
                    DECODE -> {
                        val pfd = data.readFileDescriptor() ?: throw IllegalArgumentException("no image")
                        val maxSide = data.readInt()
                        val maxPixels = data.readLong()
                        val bmp = decodeImage(pfd, maxSide, maxPixels)
                        reply?.writeInt(OK)
                        reply?.writeInt(bmp.width)
                        reply?.writeInt(bmp.height)
                    }
                    PIXELS -> {
                        val out = SharedMemory.CREATOR.createFromParcel(data)
                        try {
                            imagePixels(out)
                        } finally {
                            out.close()
                        }
                        reply?.writeInt(OK)
                    }
                }
            } catch (e: SecurityException) {
                // PdfRenderer's answer to a password-protected document.
                reply?.writeInt(PASSWORD)
            } catch (e: Exception) {
                reply?.writeInt(BROKEN)
            }
            return true
        }
    }

    override fun onBind(intent: Intent): IBinder = binder

    override fun onUnbind(intent: Intent): Boolean {
        closeDocument()
        return false
    }

    override fun onDestroy() {
        closeDocument()
        super.onDestroy()
    }

    private fun open(pfd: ParcelFileDescriptor, password: String?): FloatArray = synchronized(lock) {
        closeDocument()
        input = pfd
        val r = if (password != null && Build.VERSION.SDK_INT >= 35) {
            PdfRenderer(pfd, android.graphics.pdf.LoadParams.Builder().setPassword(password).build())
        } else {
            PdfRenderer(pfd)
        }
        renderer = r
        val sizes = FloatArray(r.pageCount * 2)
        for (i in 0 until r.pageCount) {
            r.openPage(i).use { p ->
                sizes[2 * i] = p.width.toFloat()
                sizes[2 * i + 1] = p.height.toFloat()
            }
        }
        sizes
    }

    private fun render(page: Int, width: Int, height: Int, out: SharedMemory) = synchronized(lock) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) throw IllegalStateException("needs Android 11")
        val r = renderer ?: throw IllegalStateException("no document open")
        require(page in 0 until r.pageCount) { "no such page" }
        require(width in 1..MAX_SIDE && height in 1..MAX_SIDE && width.toLong() * height <= MAX_PIXELS) {
            "page too large"
        }
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            // Pages are drawn onto transparency; paper is white.
            bitmap.eraseColor(Color.WHITE)
            r.openPage(page).use { p ->
                // No transform: the page is scaled to fill the bitmap.
                p.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            }
            val buffer = out.mapReadWrite()
            try {
                require(buffer.capacity() >= width * height * 4) { "buffer too small" }
                bitmap.copyPixelsToBuffer(buffer)
            } finally {
                SharedMemory.unmap(buffer)
            }
        } finally {
            bitmap.recycle()
        }
    }

    /** Every match of [query]: (page, [left, top, right, bottom]… in points). */
    @androidx.annotation.RequiresApi(35)
    private fun search(query: String): List<Pair<Int, FloatArray>> = synchronized(lock) {
        val r = renderer ?: throw IllegalStateException("no document open")
        val out = ArrayList<Pair<Int, FloatArray>>()
        if (query.isBlank() || query.length > 200) return out
        for (i in 0 until r.pageCount) {
            r.openPage(i).use { p ->
                for (m in p.searchText(query)) {
                    val rects = m.bounds
                    val f = FloatArray(rects.size * 4)
                    rects.forEachIndexed { k, rc ->
                        f[4 * k] = rc.left
                        f[4 * k + 1] = rc.top
                        f[4 * k + 2] = rc.right
                        f[4 * k + 3] = rc.bottom
                    }
                    out.add(i to f)
                    if (out.size >= MAX_MATCHES) return out
                }
            }
        }
        out
    }

    private fun decodeImage(pfd: ParcelFileDescriptor, maxSide: Int, maxPixels: Long): Bitmap = synchronized(lock) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) throw IllegalStateException("needs Android 11")
        dropImage()
        require(maxSide in 1..MAX_SIDE && maxPixels in 1..MAX_PIXELS) { "bad limits" }
        val bytes = pfd.use {
            require(it.statSize in 1..MAX_IMAGE_BYTES) { "image too large" }
            FileInputStream(it.fileDescriptor).readBytes()
        }
        val decoded = ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
            // Software pixels (copyable), scaled down to the limits, EXIF
            // orientation applied by the decoder; first frame of animations.
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val w = info.size.width.toDouble()
            val h = info.size.height.toDouble()
            require(w >= 1 && h >= 1) { "empty image" }
            val scale = minOf(1.0, maxSide / maxOf(w, h), sqrt(maxPixels / (w * h)))
            if (scale < 1.0) decoder.setTargetSize(maxOf(1, (w * scale).toInt()), maxOf(1, (h * scale).toInt()))
        }
        bytes.fill(0)
        val bmp = if (decoded.config == Bitmap.Config.ARGB_8888) {
            decoded
        } else {
            decoded.copy(Bitmap.Config.ARGB_8888, false).also { decoded.recycle() }
        }
        require(bmp.width in 1..maxSide && bmp.height in 1..maxSide && bmp.width.toLong() * bmp.height <= maxPixels) {
            "decoded image too large"
        }
        image = bmp
        bmp
    }

    private fun imagePixels(out: SharedMemory) = synchronized(lock) {
        val bmp = image ?: throw IllegalStateException("no image decoded")
        try {
            val buffer = out.mapReadWrite()
            try {
                require(buffer.capacity() >= bmp.width * bmp.height * 4) { "buffer too small" }
                bmp.copyPixelsToBuffer(buffer)
            } finally {
                SharedMemory.unmap(buffer)
            }
        } finally {
            dropImage()
        }
    }

    private fun dropImage() {
        image?.recycle()
        image = null
    }

    private fun closeDocument() = synchronized(lock) {
        try {
            renderer?.close()
        } catch (_: Exception) {
        }
        try {
            input?.close()
        } catch (_: Exception) {
        }
        renderer = null
        input = null
    }
}
