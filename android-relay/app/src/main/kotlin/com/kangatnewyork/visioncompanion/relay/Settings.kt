package com.kangatnewyork.visioncompanion.relay

import android.content.Context
import android.content.SharedPreferences

/**
 * Persistent user settings backed by SharedPreferences.
 *
 * Kept deliberately small — fancier DataStore is overkill for ~5 keys.
 *
 * All keys are read-through (no in-memory cache) so a settings edit on
 * the UI side is picked up by the next foreground service start without
 * extra coordination.
 */
class Settings(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    var host: String
        get() = prefs.getString(KEY_HOST, "") ?: ""
        set(value) = prefs.edit().putString(KEY_HOST, value).apply()

    var port: Int
        get() = prefs.getInt(KEY_PORT, DEFAULT_PORT)
        set(value) = prefs.edit().putInt(KEY_PORT, value).apply()

    /** Frames per second for image uplink. 0 disables image capture entirely. */
    var imageFps: Int
        get() = prefs.getInt(KEY_IMAGE_FPS, 0)
        set(value) = prefs.edit().putInt(KEY_IMAGE_FPS, value).apply()

    var logLevel: Logger.Level
        get() = Logger.Level.fromName(prefs.getString(KEY_LOG_LEVEL, Logger.Level.INFO.name) ?: "")
        set(value) = prefs.edit().putString(KEY_LOG_LEVEL, value.name).apply()

    var transport: Transport
        get() = Transport.fromName(prefs.getString(KEY_TRANSPORT, Transport.PHONE.name) ?: "")
        set(value) = prefs.edit().putString(KEY_TRANSPORT, value.name).apply()

    /** Auto-reconnect on WebSocket failure. Default ON. */
    var autoReconnect: Boolean
        get() = prefs.getBoolean(KEY_AUTO_RECONNECT, true)
        set(value) = prefs.edit().putBoolean(KEY_AUTO_RECONNECT, value).apply()

    enum class Transport {
        /** Phone microphone + camera. Development / no-Meta-SDK fallback. */
        PHONE,
        /** Real Meta Wearables Device Access Toolkit. Stub until SDK access granted. */
        META;

        companion object {
            fun fromName(s: String): Transport =
                values().firstOrNull { it.name.equals(s, ignoreCase = true) } ?: PHONE
        }
    }

    companion object {
        private const val PREFS_NAME = "vc_relay_prefs"
        private const val KEY_HOST = "host"
        private const val KEY_PORT = "port"
        private const val KEY_IMAGE_FPS = "image_fps"
        private const val KEY_LOG_LEVEL = "log_level"
        private const val KEY_TRANSPORT = "transport"
        private const val KEY_AUTO_RECONNECT = "auto_reconnect"

        const val DEFAULT_PORT = 8765
    }
}
