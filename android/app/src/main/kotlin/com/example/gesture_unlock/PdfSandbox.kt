package com.example.gesture_unlock

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.RemoteException
import android.os.SharedMemory
import android.system.Os
import android.system.OsConstants
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileDescriptor
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Main-process side of the PDF sandbox: hands a decrypted document to
 * [PdfRenderService] (an isolated process) through an in-memory file and
 * gets page pixels back through shared memory. Nothing touches storage.
 *
 * Channel `app.vault/pdf`: open(data) -> page sizes, render(page, w, h) ->
 * RGBA bytes, close(), and image(data, maxSide, maxPixels) -> {width,
 * height, RGBA data} for vault images.
 */
class PdfSandbox(private val activity: Activity) {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    // Touched only on [executor], except [connection], which close() and
    // the watchdog also clear from the main thread.
    private var binder: IBinder? = null
    private val connection = java.util.concurrent.atomic.AtomicReference<ServiceConnection?>(null)
    private var pixels: SharedMemory? = null

    companion object {
        /** Treat everything the renderer says as hostile: it parses the PDF. */
        const val MAX_PAGES = 20_000
        const val MAX_POINTS = 14_400f // 200 inches, the PDF limit
        const val OPEN_TIMEOUT_MS = 60_000L
        const val RENDER_TIMEOUT_MS = 30_000L
    }

    private class SandboxError(val code: String, message: String) : Exception(message)

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> run(result) { open(call.argument<ByteArray>("data")!!, call.argument<String>("password")) }
            "search" -> run(result) { search(call.argument<String>("query") ?: "") }
            "render" -> run(result) {
                render(call.argument<Int>("page")!!, call.argument<Int>("width")!!, call.argument<Int>("height")!!)
            }
            "image" -> run(result) {
                image(
                    call.argument<ByteArray>("data")!!,
                    call.argument<Int>("maxSide") ?: 4096,
                    (call.argument<Number>("maxPixels") ?: 12_000_000).toLong(),
                )
            }
            "close" -> {
                // Unbind right away on this (main) thread, not behind a call
                // that may be stuck: Android then kills the isolated process,
                // and a stuck transact fails with DeadObjectException.
                unbindNow()
                run(result) {
                    close()
                    true
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun run(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: SandboxError) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: RemoteException) {
                // The renderer died: a crash, or killed for using too much memory.
                binder = null
                main.post { result.error("crashed", e.toString(), null) }
            } catch (e: Throwable) {
                main.post { result.error("failed", e.toString(), null) }
            }
        }
    }

    private fun connect(): IBinder {
        binder?.let { if (it.isBinderAlive) return it }
        unbind()
        val ready = CountDownLatch(1)
        var service: IBinder? = null
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, b: IBinder) {
                service = b
                ready.countDown()
            }

            override fun onServiceDisconnected(name: ComponentName) {}
        }
        main.post {
            activity.bindService(Intent(activity, PdfRenderService::class.java), conn, Context.BIND_AUTO_CREATE)
        }
        if (!ready.await(15, TimeUnit.SECONDS)) {
            main.post {
                try {
                    activity.unbindService(conn)
                } catch (_: Exception) {
                }
            }
            throw SandboxError("failed", "the renderer did not start")
        }
        connection.set(conn)
        binder = service
        return service!!
    }

    private fun unbind() {
        binder = null
        main.post { unbindNow() }
    }

    /** Main thread only. */
    private fun unbindNow() {
        val conn = connection.getAndSet(null) ?: return
        try {
            activity.unbindService(conn)
        } catch (_: Exception) {
        }
    }

    private fun transact(code: Int, write: (Parcel) -> Unit, read: (Parcel) -> Any?): Any? {
        val b = connect()
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        // A renderer that never answers (an exploit, or a pathological file)
        // is cut off: unbinding kills it and the call below then throws.
        val watchdog = Runnable { unbindNow() }
        val slow = code == PdfRenderService.OPEN || code == PdfRenderService.DECODE || code == PdfRenderService.SEARCH
        main.postDelayed(watchdog, if (slow) OPEN_TIMEOUT_MS else RENDER_TIMEOUT_MS)
        try {
            data.writeInterfaceToken(PdfRenderService.DESCRIPTOR)
            write(data)
            b.transact(code, data, reply, 0)
            main.removeCallbacks(watchdog)
            when (reply.readInt()) {
                PdfRenderService.OK -> return read(reply)
                PdfRenderService.PASSWORD -> throw SandboxError("password", "password-protected")
                PdfRenderService.UNSUPPORTED -> throw SandboxError("unsupported", "needs Android 15")
                else -> throw SandboxError("broken", "the renderer could not read this document")
            }
        } finally {
            main.removeCallbacks(watchdog)
            data.recycle()
            reply.recycle()
        }
    }

    /** Matches of [query]: a flat list per match, page then rectangles. */
    private fun search(query: String): List<List<Double>> {
        if (Build.VERSION.SDK_INT < 35) throw SandboxError("unsupported", "needs Android 15")
        @Suppress("UNCHECKED_CAST")
        return transact(PdfRenderService.SEARCH, { it.writeString(query) }) { r ->
            val n = r.readInt()
            if (n !in 0..PdfRenderService.MAX_MATCHES) throw SandboxError("broken", "bad reply from the renderer")
            val out = ArrayList<List<Double>>(n)
            repeat(n) {
                val page = r.readInt()
                val len = r.readInt()
                // Hostile renderer: a page it doesn't have, or absurd rectangles.
                if (page < 0 || page >= MAX_PAGES || len !in 0..400 || len % 4 != 0 || r.dataAvail() < len * 4) {
                    throw SandboxError("broken", "bad reply from the renderer")
                }
                val m = ArrayList<Double>(len + 1)
                m.add(page.toDouble())
                repeat(len) {
                    val v = r.readFloat()
                    if (!v.isFinite() || v < -MAX_POINTS || v > MAX_POINTS) throw SandboxError("broken", "bad reply from the renderer")
                    m.add(v.toDouble())
                }
                out.add(m)
            }
            out
        } as List<List<Double>>
    }

    private fun open(bytes: ByteArray, password: String? = null): List<Double> {
        // An in-memory file needs memfd_create (Android 11). Older phones
        // get a clear message instead of a decrypted copy on storage.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            bytes.fill(0)
            throw SandboxError("unsupported", "needs Android 11")
        }
        val fd: FileDescriptor = Os.memfd_create("doc", 0)
        try {
            var off = 0
            while (off < bytes.size) off += Os.write(fd, bytes, off, bytes.size - off)
            Os.lseek(fd, 0, OsConstants.SEEK_SET)
            val shared = ParcelFileDescriptor.dup(fd)
            try {
                @Suppress("UNCHECKED_CAST")
                return transact(PdfRenderService.OPEN, {
                    it.writeFileDescriptor(shared.fileDescriptor)
                    it.writeString(password)
                }) { r ->
                    val count = r.readInt()
                    // Check before allocating anything the renderer sized:
                    // writeFloatArray put a length int, then 2 floats a page.
                    if (count !in 0..MAX_PAGES || r.dataAvail() < 4 + count * 8) {
                        throw SandboxError("broken", "bad reply from the renderer")
                    }
                    if (r.readInt() != count * 2) throw SandboxError("broken", "bad reply from the renderer")
                    val sizes = DoubleArray(count * 2)
                    for (i in 0 until count * 2) {
                        val v = r.readFloat()
                        if (!v.isFinite() || v <= 0f || v > MAX_POINTS) {
                            throw SandboxError("broken", "bad page size from the renderer")
                        }
                        sizes[i] = v.toDouble()
                    }
                    sizes.toList()
                } as List<Double>
            } finally {
                shared.close()
            }
        } finally {
            Os.close(fd)
            bytes.fill(0)
        }
    }

    private fun render(page: Int, width: Int, height: Int): ByteArray {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) throw SandboxError("unsupported", "needs Android 11")
        if (width <= 0 || height <= 0 || width > PdfRenderService.MAX_SIDE || height > PdfRenderService.MAX_SIDE ||
            width.toLong() * height > PdfRenderService.MAX_PIXELS
        ) {
            throw SandboxError("failed", "page too large")
        }
        val size = width * height * 4
        val shm = pixels?.takeIf { it.size >= size } ?: run {
            pixels?.close()
            SharedMemory.create("page", size).also { pixels = it }
        }
        transact(PdfRenderService.RENDER, {
            it.writeInt(page)
            it.writeInt(width)
            it.writeInt(height)
            shm.writeToParcel(it, 0)
        }) { null }
        val buffer = shm.mapReadOnly()
        try {
            val out = ByteArray(size)
            buffer.get(out, 0, size)
            return out
        } finally {
            SharedMemory.unmap(buffer)
        }
    }

    /** Decodes an image in the renderer: (width, height, RGBA pixels). */
    private fun image(bytes: ByteArray, maxSide: Int, maxPixels: Long): Map<String, Any> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            bytes.fill(0)
            throw SandboxError("unsupported", "needs Android 11")
        }
        val side = maxSide.coerceIn(1, PdfRenderService.MAX_SIDE)
        val pixelsMax = maxPixels.coerceIn(1, PdfRenderService.MAX_PIXELS)
        val fd: FileDescriptor = Os.memfd_create("img", 0)
        val (w, h) = try {
            var off = 0
            while (off < bytes.size) off += Os.write(fd, bytes, off, bytes.size - off)
            Os.lseek(fd, 0, OsConstants.SEEK_SET)
            val shared = ParcelFileDescriptor.dup(fd)
            try {
                @Suppress("UNCHECKED_CAST")
                transact(PdfRenderService.DECODE, {
                    it.writeFileDescriptor(shared.fileDescriptor)
                    it.writeInt(side)
                    it.writeLong(pixelsMax)
                }) { r ->
                    if (r.dataAvail() < 8) throw SandboxError("broken", "bad reply from the renderer")
                    val width = r.readInt()
                    val height = r.readInt()
                    // The renderer parsed hostile data: check what it says.
                    if (width !in 1..side || height !in 1..side || width.toLong() * height > pixelsMax) {
                        throw SandboxError("broken", "bad image size from the renderer")
                    }
                    width to height
                } as Pair<Int, Int>
            } finally {
                shared.close()
            }
        } finally {
            Os.close(fd)
            bytes.fill(0)
        }
        val size = w * h * 4
        val shm = SharedMemory.create("img", size)
        try {
            transact(PdfRenderService.PIXELS, { shm.writeToParcel(it, 0) }) { null }
            val buffer = shm.mapReadOnly()
            try {
                val out = ByteArray(size)
                buffer.get(out, 0, size)
                return mapOf("width" to w, "height" to h, "data" to out)
            } finally {
                SharedMemory.unmap(buffer)
            }
        } finally {
            shm.close()
        }
    }

    private fun close() {
        if (binder?.isBinderAlive == true) {
            try {
                transact(PdfRenderService.CLOSE, {}) { null }
            } catch (_: Exception) {
            }
        }
        unbind()
        pixels?.close()
        pixels = null
    }
}
