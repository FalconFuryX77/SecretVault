package com.example.gesture_unlock

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * Channel `app.vault/move`: copies the (encrypted) vault file to and from a
 * place the user picks with Android's document picker, for moving a vault
 * to another phone or app. Streams in 1 MiB blocks, so any size works, and
 * reports progress for a progress bar.
 */
class FileMover(private val activity: Activity) {
    companion object {
        const val REQUEST_CREATE = 0x5601
        const val REQUEST_OPEN = 0x5602
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private val done = AtomicLong(0)
    private val total = AtomicLong(0)

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> pick(result, REQUEST_CREATE) {
                Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("application/octet-stream")
                    .putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "file.bin")
            }
            "open" -> pick(result, REQUEST_OPEN) {
                Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
            }
            "copyOut" -> background(result) {
                copyOut(
                    File(call.argument<String>("path")!!),
                    Uri.parse(call.argument<String>("uri")!!),
                    call.argument<Int>("patchOffset") ?: -1,
                    call.argument<ByteArray>("patch") ?: ByteArray(0),
                )
                true
            }
            "copyIn" -> background(result) {
                copyIn(Uri.parse(call.argument<String>("uri")!!), File(call.argument<String>("path")!!))
                true
            }
            "progress" -> result.success(mapOf("done" to done.get(), "total" to total.get()))
            "delete" -> background(result) {
                try {
                    android.provider.DocumentsContract.deleteDocument(activity.contentResolver, Uri.parse(call.argument<String>("uri")!!))
                } catch (_: Exception) {
                    false
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun pick(result: MethodChannel.Result, code: Int, intent: () -> Intent) {
        pending?.success(null)
        pending = result
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent(), code)
        } catch (e: Exception) {
            pending = null
            result.error("move", "no document picker", null)
        }
    }

    /** From MainActivity.onActivityResult. True if it was ours. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CREATE && requestCode != REQUEST_OPEN) return false
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
                main.post { result.error("move", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun copyOut(src: File, dest: Uri, patchOffset: Int, patch: ByteArray) {
        val size = src.length()
        done.set(0)
        total.set(size)
        val out = activity.contentResolver.openOutputStream(dest, "wt") ?: throw IllegalStateException("can't write there")
        out.use { o ->
            FileInputStream(src).use { inp ->
                val buf = ByteArray(1 shl 20)
                var pos = 0L
                while (true) {
                    val n = inp.read(buf)
                    if (n < 0) break
                    // Put the patch in the copy only, where it falls in this block.
                    if (patchOffset >= 0) {
                        val from = maxOf(pos, patchOffset.toLong())
                        val to = minOf(pos + n, patchOffset.toLong() + patch.size)
                        for (k in from until to) buf[(k - pos).toInt()] = patch[(k - patchOffset).toInt()]
                    }
                    o.write(buf, 0, n)
                    pos += n
                    done.set(pos)
                }
                buf.fill(0)
            }
            o.flush()
        }
        if (done.get() != size) throw IllegalStateException("the copy is incomplete")
    }

    private fun copyIn(src: Uri, dest: File) {
        done.set(0)
        total.set(try {
            activity.contentResolver.openFileDescriptor(src, "r")?.use { it.statSize } ?: -1
        } catch (_: Exception) {
            -1
        })
        dest.parentFile?.mkdirs()
        val inp = activity.contentResolver.openInputStream(src) ?: throw IllegalStateException("can't read that file")
        inp.use { i ->
            FileOutputStream(dest).use { o ->
                val buf = ByteArray(1 shl 20)
                var pos = 0L
                while (true) {
                    val n = i.read(buf)
                    if (n < 0) break
                    o.write(buf, 0, n)
                    pos += n
                    done.set(pos)
                }
                o.fd.sync()
            }
        }
    }
}
