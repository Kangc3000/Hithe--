package com.kangatnewyork.visioncompanion.relay

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileWriter
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * Structured logger used throughout the relay app.
 *
 * Two sinks:
 *   - Logcat (always)
 *   - Rotating file in `/Android/data/<pkg>/files/logs/relay-YYYY-MM-DD.log`
 *     so the log can be pulled with adb / mtp without root.
 *
 * Log lines follow a simple key=value tail format so a `grep | awk` debug
 * session is easy. Example:
 *
 *   2026-05-10T14:32:11.452 INFO  Relay/WS connect host=hermes-host port=8765
 *   2026-05-10T14:32:11.901 INFO  Relay/Audio chunk bytes=3200 rms_dbfs=-32.1
 *
 * The level is a runtime setting (Settings.logLevel) so field debugging
 * doesn't require a rebuild.
 */
object Logger {

    enum class Level(val priority: Int) {
        VERBOSE(Log.VERBOSE),
        DEBUG(Log.DEBUG),
        INFO(Log.INFO),
        WARN(Log.WARN),
        ERROR(Log.ERROR);

        companion object {
            fun fromName(s: String): Level =
                values().firstOrNull { it.name.equals(s, ignoreCase = true) } ?: INFO
        }
    }

    private const val TAG_PREFIX = "VC"
    private val tsFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US)
    private val dayFormat = SimpleDateFormat("yyyy-MM-dd", Locale.US)

    private val minLevel = AtomicReference(Level.INFO)
    private val logDir = AtomicReference<File?>(null)
    private val writer = AtomicReference<PrintWriter?>(null)
    private val currentDay = AtomicReference<String?>(null)

    // Writes happen on a background thread so the audio loop isn't held up
    // by disk I/O. A bounded queue would be safer; the unbounded one is OK
    // for this app's log volume but watch for memory growth on slow disks.
    private val ioExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "vc-logger-io").apply { isDaemon = true }
    }
    private val pendingInit = ConcurrentLinkedQueue<String>()

    fun init(context: Context, level: Level) {
        minLevel.set(level)
        val dir = File(context.getExternalFilesDir(null), "logs")
        if (!dir.exists()) dir.mkdirs()
        logDir.set(dir)
        ioExecutor.submit { rollIfNeeded() }
        // Flush any messages that arrived before init finished.
        while (true) {
            val line = pendingInit.poll() ?: break
            ioExecutor.submit { writeToFile(line) }
        }
        i("Logger", "init level=${level.name} dir=${dir.absolutePath}")
    }

    fun setLevel(level: Level) {
        val old = minLevel.getAndSet(level)
        if (old != level) i("Logger", "level changed from=${old.name} to=${level.name}")
    }

    fun v(tag: String, msg: String) = log(Level.VERBOSE, tag, msg, null)
    fun d(tag: String, msg: String) = log(Level.DEBUG, tag, msg, null)
    fun i(tag: String, msg: String) = log(Level.INFO, tag, msg, null)
    fun w(tag: String, msg: String, t: Throwable? = null) = log(Level.WARN, tag, msg, t)
    fun e(tag: String, msg: String, t: Throwable? = null) = log(Level.ERROR, tag, msg, t)

    private fun log(level: Level, tag: String, msg: String, t: Throwable?) {
        if (level.priority < minLevel.get().priority) return

        val fullTag = "$TAG_PREFIX/$tag"
        if (t == null) {
            Log.println(level.priority, fullTag, msg)
        } else {
            Log.println(level.priority, fullTag, "$msg\n${stackString(t)}")
        }

        val ts = tsFormat.format(Date())
        val line = buildString {
            append(ts).append(' ').append(level.name.padEnd(5)).append(' ')
            append(fullTag).append(' ').append(msg)
            if (t != null) append('\n').append(stackString(t))
            append('\n')
        }
        if (logDir.get() == null) {
            pendingInit.offer(line)
        } else {
            ioExecutor.submit { writeToFile(line) }
        }
    }

    private fun stackString(t: Throwable): String {
        val sw = StringWriter()
        t.printStackTrace(PrintWriter(sw))
        return sw.toString().trimEnd()
    }

    private fun writeToFile(line: String) {
        try {
            rollIfNeeded()
            writer.get()?.let {
                it.write(line)
                it.flush()
            }
        } catch (e: Throwable) {
            Log.w("VC/Logger", "file write failed: ${e.message}")
        }
    }

    private fun rollIfNeeded() {
        val today = dayFormat.format(Date())
        if (today == currentDay.get() && writer.get() != null) return
        try {
            writer.get()?.close()
        } catch (_: Throwable) {}
        val dir = logDir.get() ?: return
        val file = File(dir, "relay-$today.log")
        writer.set(PrintWriter(FileWriter(file, true)))
        currentDay.set(today)
        pruneOld(dir, keepDays = 14)
    }

    private fun pruneOld(dir: File, keepDays: Int) {
        try {
            val cutoff = System.currentTimeMillis() - keepDays * 24L * 60 * 60 * 1000
            dir.listFiles { f -> f.name.startsWith("relay-") && f.name.endsWith(".log") }
                ?.filter { it.lastModified() < cutoff }
                ?.forEach { it.delete() }
        } catch (_: Throwable) {
            // Best-effort cleanup; ignore failures.
        }
    }
}
