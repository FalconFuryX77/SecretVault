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
 * RGBA bytes, close().
 */
class PdfSandbox(private val activity: Activity) {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    // Touched only on [executor].
    private var binder: IBinder? = null
    private var connection: ServiceConnection? = null
    private var pixels: SharedMemory? = null

    private class SandboxError(val code: String, message: String) : Exception(message)

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> run(result) { open(call.argument<ByteArray>("data")!!) }
            "render" -> run(result) {
                render(call.argument<Int>("page")!!, call.argument<Int>("width")!!, call.argument<Int>("height")!!)
            }
            "close" -> run(result) {
                close()
                true
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
            main.post { activity.unbindService(conn) }
            throw SandboxError("failed", "the renderer did not start")
        }
        connection = conn
        binder = service
        return service!!
    }

    private fun unbind() {
        val conn = connection ?: return
        connection = null
        binder = null
        main.post {
            try {
                activity.unbindService(conn)
            } catch (_: Exception) {
            }
        }
    }

    private fun transact(code: Int, write: (Parcel) -> Unit, read: (Parcel) -> Any?): Any? {
        val b = connect()
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(PdfRenderService.DESCRIPTOR)
            write(data)
            b.transact(code, data, reply, 0)
            when (reply.readInt()) {
                PdfRenderService.OK -> return read(reply)
                PdfRenderService.PASSWORD -> throw SandboxError("password", "password-protected")
                else -> throw SandboxError("broken", "the renderer could not read this document")
            }
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    private fun open(bytes: ByteArray): List<Double> {
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
                return transact(PdfRenderService.OPEN, { it.writeFileDescriptor(shared.fileDescriptor) }) { r ->
                    val count = r.readInt()
                    val sizes = FloatArray(count * 2)
                    r.readFloatArray(sizes)
                    sizes.map { it.toDouble() }
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
