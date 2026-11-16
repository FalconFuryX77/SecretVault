package com.example.gesture_unlock

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Looper
import android.os.SystemClock

/**
 * Where the phone is, for the in-vault camera. It listens while the camera
 * is open and keeps the best recent fix, so a photo (EXIF GPS) or a video
 * (the MP4's location) records where it was taken, as evidence of where it
 * came from. It only asks Android's own location service: nothing without
 * the location permission or with location turned off, and the app itself
 * makes no connection for it.
 */
class PlaceTracker(private val context: Context) {
    private val lm: LocationManager? = context.getSystemService(LocationManager::class.java)
    private val listener = LocationListener { offer(it) }
    @Volatile private var best: Location? = null
    private var listening = false

    val allowed: Boolean
        get() = granted(Manifest.permission.ACCESS_FINE_LOCATION) || granted(Manifest.permission.ACCESS_COARSE_LOCATION)

    private fun granted(p: String) = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    /** Starts listening (callbacks on [looper]); a no-op without permission. */
    @SuppressLint("MissingPermission")
    fun start(looper: Looper) {
        val m = lm ?: return
        if (listening || !allowed) return
        for (p in runCatching { m.getProviders(true) }.getOrDefault(emptyList())) {
            runCatching { m.getLastKnownLocation(p) }.getOrNull()?.let { offer(it) }
            runCatching { m.requestLocationUpdates(p, 1000L, 0f, listener, looper) }
        }
        listening = true
    }

    fun stop() {
        if (listening) runCatching { lm?.removeUpdates(listener) }
        listening = false
    }

    /** The best fix from the last [MAX_AGE_MS], or null. */
    fun now(): Location? = best?.takeIf { ageMs(it) <= MAX_AGE_MS }

    private fun offer(l: Location) {
        val b = best
        val newer = b == null || ageMs(l) + FRESHER_MS < ageMs(b)
        val sharper = b != null && l.hasAccuracy() && (!b.hasAccuracy() || l.accuracy <= b.accuracy) &&
            ageMs(l) <= ageMs(b) + FRESHER_MS
        if (newer || sharper) best = l
    }

    private fun ageMs(l: Location) = (SystemClock.elapsedRealtimeNanos() - l.elapsedRealtimeNanos) / 1_000_000

    private companion object {
        const val MAX_AGE_MS = 10 * 60_000L
        const val FRESHER_MS = 60_000L
    }
}
