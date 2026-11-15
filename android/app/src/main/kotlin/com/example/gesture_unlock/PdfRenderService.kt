package com.example.gesture_unlock

import android.app.Service
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.SharedMemory

/**
 * Draws PDF pages in an isolated process (`android:isolatedProcess="true"`
 * in the manifest).
 *
 * PDF parsers are a classic way in for malicious documents, and people who
 * get searched also get sent booby-trapped files. Here the parser runs under
 * a throwaway user id with no permissions: no network, no access to the
 * app's files, the vault container or its keys, which stay in the main
 * process. A document that compromises the renderer gets a process that can
 * see that one document and nothing else, and the process is killed as soon
 * as the viewer closes.
 *
 * The protocol is three plain Binder calls (no AIDL), see [PdfSandbox]:
 *  - OPEN(fd)                  -> status, page count, page sizes in points
 *  - RENDER(page, w, h, shmem) -> status; RGBA pixels written into shmem
 *  - CLOSE
 */
class PdfRenderService : Service() {
    companion object {
        const val DESCRIPTOR = "app.vault.render"
        const val OPEN = IBinder.FIRST_CALL_TRANSACTION
        const val RENDER = IBinder.FIRST_CALL_TRANSACTION + 1
        const val CLOSE = IBinder.FIRST_CALL_TRANSACTION + 2

        const val OK = 0
        const val PASSWORD = 1
        const val BROKEN = 2

        const val MAX_SIDE = 4096
        const val MAX_PIXELS = 4096L * 4096L
    }

    private val lock = Any()
    private var input: ParcelFileDescriptor? = null
    private var renderer: PdfRenderer? = null

    private val binder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == INTERFACE_TRANSACTION) {
                reply?.writeString(DESCRIPTOR)
                return true
            }
            if (code !in OPEN..CLOSE) return super.onTransact(code, data, reply, flags)
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
                        val sizes = open(pfd)
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

    private fun open(pfd: ParcelFileDescriptor): FloatArray = synchronized(lock) {
        closeDocument()
        input = pfd
        val r = PdfRenderer(pfd)
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
