package com.example.gesture_unlock

import android.app.Activity
import android.app.role.RoleManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager

/**
 * The "assistant button" trigger. Phones don't let apps read the assistant
 * key (or Samsung's Bixby key) directly, but whatever that key opens, it
 * opens the phone's *digital assistant app*. If the user picks this app as
 * the assistant, the key lands here, and this starts or stops a recording
 * exactly as the volume trigger does, then disappears without drawing.
 *
 * Disabled until the user turns it on in the hidden recorder, so the app
 * isn't offered as an assistant at all otherwise. It does nothing unless the
 * recorder is armed with the assistant button allowed.
 */
class AssistTriggerActivity : Activity() {
    companion object {
        private fun component(ctx: Context) = ComponentName(ctx, AssistTriggerActivity::class.java)

        fun isEnabled(ctx: Context): Boolean =
            ctx.packageManager.getComponentEnabledSetting(component(ctx)) ==
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED

        fun setEnabled(ctx: Context, on: Boolean) {
            ctx.packageManager.setComponentEnabledSetting(
                component(ctx),
                if (on) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DEFAULT,
                PackageManager.DONT_KILL_APP,
            )
        }

        /** Whether this app is the phone's digital assistant app (Android 10+). */
        fun isAssistant(ctx: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
            return try {
                ctx.getSystemService(RoleManager::class.java).isRoleHeld(RoleManager.ROLE_ASSISTANT)
            } catch (_: Exception) {
                false
            }
        }

        /** Opens the system screen where the assistant app is chosen. */
        fun openSettings(ctx: Activity): Boolean {
            for (action in listOf(Settings.ACTION_VOICE_INPUT_SETTINGS, Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)) {
                try {
                    ctx.startActivity(Intent(action))
                    return true
                } catch (_: Exception) {
                }
            }
            return false
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
        }
        if (RecorderService.running && RecorderService.armed && RecorderService.assistEnabled && fromSystem()) {
            try {
                startService(Intent(this, RecorderService::class.java).setAction(RecorderService.ACTION_TOGGLE))
            } catch (_: Exception) {
            }
        }
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    /**
     * Only the system opens the assistant. Any app can send this activity an
     * assist intent, so refuse one that names its own referrer (an app can
     * forge that) or whose real referrer, which the system fills in from the
     * caller's identity, isn't a system app.
     */
    private fun fromSystem(): Boolean = try {
        val extras = intent?.extras
        if (extras != null && (extras.containsKey(Intent.EXTRA_REFERRER) || extras.containsKey(Intent.EXTRA_REFERRER_NAME))) {
            false
        } else {
            val pkg = referrer?.takeIf { it.scheme == "android-app" }?.host
            if (pkg == null) {
                false
            } else {
                val info = packageManager.getApplicationInfo(pkg, 0)
                info.flags and ApplicationInfo.FLAG_SYSTEM != 0
            }
        }
    } catch (_: Exception) {
        false
    }
}
