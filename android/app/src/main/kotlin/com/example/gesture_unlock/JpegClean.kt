package com.example.gesture_unlock

import java.io.ByteArrayOutputStream

/**
 * Strips a camera JPEG down to its pixels: every metadata segment (EXIF with
 * the phone's make and model, capture settings and times; XMP; maker notes;
 * comments) is dropped. Only the orientation survives, in a minimal EXIF
 * block of its own, so the photo still shows the right way up.
 */
object JpegClean {
    fun clean(jpeg: ByteArray): ByteArray {
        if (jpeg.size < 4 || u8(jpeg, 0) != 0xFF || u8(jpeg, 1) != 0xD8) return jpeg
        var orientation = 1
        val kept = ByteArrayOutputStream(jpeg.size)
        var i = 2
        while (i + 4 <= jpeg.size) {
            if (u8(jpeg, i) != 0xFF) return jpeg // not where a marker should be: leave it alone
            val marker = u8(jpeg, i + 1)
            if (marker == 0xFF) { // fill byte
                i++
                continue
            }
            if (marker == 0xDA) { // start of scan: the rest is image data
                kept.write(jpeg, i, jpeg.size - i)
                break
            }
            val len = (u8(jpeg, i + 2) shl 8) or u8(jpeg, i + 3)
            if (len < 2 || i + 2 + len > jpeg.size) return jpeg
            val isApp = marker in 0xE0..0xEF
            when {
                marker == 0xE1 && isExif(jpeg, i + 4, len - 2) -> orientation = readOrientation(jpeg, i + 10, len - 8)
                marker == 0xE0 -> kept.write(jpeg, i, 2 + len) // JFIF: harmless
                marker == 0xE2 && startsWith(jpeg, i + 4, "ICC_PROFILE") -> kept.write(jpeg, i, 2 + len) // colours
                isApp || marker == 0xFE -> {} // other metadata and comments: dropped
                else -> kept.write(jpeg, i, 2 + len) // tables, frame header…
            }
            i += 2 + len
        }
        val out = ByteArrayOutputStream(jpeg.size)
        out.write(0xFF)
        out.write(0xD8)
        if (orientation != 1) out.write(minimalExif(orientation))
        kept.writeTo(out)
        return out.toByteArray()
    }

    private fun u8(b: ByteArray, i: Int) = b[i].toInt() and 0xff

    private fun startsWith(b: ByteArray, at: Int, s: String): Boolean =
        at + s.length <= b.size && s.indices.all { b[at + it].toInt() == s[it].code }

    private fun isExif(b: ByteArray, at: Int, len: Int) =
        len >= 6 && startsWith(b, at, "Exif") && b[at + 4].toInt() == 0 && b[at + 5].toInt() == 0

    /** The orientation tag in a TIFF block, 1 if missing or unreadable. */
    private fun readOrientation(b: ByteArray, tiff: Int, len: Int): Int {
        try {
            if (len < 8) return 1
            val little = b[tiff].toInt() == 'I'.code
            fun u16(at: Int) = if (little) u8(b, at) or (u8(b, at + 1) shl 8) else (u8(b, at) shl 8) or u8(b, at + 1)
            fun u32(at: Int) = if (little) u16(at) or (u16(at + 2) shl 16) else (u16(at) shl 16) or u16(at + 2)
            val ifd = tiff + u32(tiff + 4)
            if (ifd + 2 > tiff + len) return 1
            val count = u16(ifd)
            for (e in 0 until count) {
                val at = ifd + 2 + e * 12
                if (at + 12 > tiff + len) break
                if (u16(at) == 0x0112) return u16(at + 8).takeIf { it in 1..8 } ?: 1
            }
        } catch (_: Exception) {
        }
        return 1
    }

    /** APP1 with a single IFD entry: Orientation. */
    private fun minimalExif(orientation: Int): ByteArray {
        val tiff = byteArrayOf(
            'M'.code.toByte(), 'M'.code.toByte(), 0, 42, 0, 0, 0, 8, // big-endian, IFD0 at 8
            0, 1, // one entry
            0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, orientation.toByte(), 0, 0, // Orientation, SHORT, 1
            0, 0, 0, 0, // no next IFD
        )
        val body = "Exif".toByteArray() + byteArrayOf(0, 0) + tiff
        val len = body.size + 2
        return byteArrayOf(0xFF.toByte(), 0xE1.toByte(), (len shr 8).toByte(), len.toByte()) + body
    }
}
