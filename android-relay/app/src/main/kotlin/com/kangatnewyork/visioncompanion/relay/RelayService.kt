package com.kangatnewyork.visioncompanion.relay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import com.kangatnewyork.visioncompanion.relay.image.ImageCaptureHelper
import com.kangatnewyork.visioncompanion.relay.net.RelayClient
import com.kangatnewyork.visioncompanion.relay.transport.GlassesTransport
import com.kangatnewyork.visioncompanion.relay.transport.MetaSdkTransport
import com.kangatnewyork.visioncompanion.relay.transport.PhoneMicTransport
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import kotlin.math.max
import kotlin.math.min

/**
 * Foreground service that wires the three moving pieces together:
 *
 *   GlassesTransport.audioFlow()  --PCM-->  RelayClient.sendAudio()
 *   ImageCaptureHelper (timer)    --JPEG--> RelayClient.sendImage()
 *   RelayClient.events            --TTS-->  GlassesTransport.playPcm()
 *                                 --event-> Log + (future) UI broadcast
 *
 * The service handles reconnect with exponential backoff and posts a
 * sticky notification so Android doesn't kill it under doze.
 */
class RelayService : LifecycleService() {

    private val tag = "Service"

    private lateinit var settings: Settings
    private var transport: GlassesTransport? = null
    private var imageHelper: ImageCaptureHelper? = null
    private var client: RelayClient? = null
    private var supervisor: Job? = null

    override fun onCreate() {
        super.onCreate()
        settings = Settings(applicationContext)
        Logger.init(applicationContext, settings.logLevel)
        Logger.i(tag, "onCreate")
        startForegroundWithNotification(connected = false)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        Logger.i(tag, "onStartCommand action=${intent?.action}")
        when (intent?.action) {
            ACTION_START -> ensureRunning()
            ACTION_STOP  -> { stopRunning(); stopSelf() }
            null         -> ensureRunning()  // e.g. system-restarted with sticky intent
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent): IBinder? {
        super.onBind(intent)
        return null
    }

    override fun onDestroy() {
        Logger.i(tag, "onDestroy")
        stopRunning()
        super.onDestroy()
    }

    private fun ensureRunning() {
        if (supervisor?.isActive == true) {
            Logger.d(tag, "ensureRunning: already running")
            return
        }
        supervisor = lifecycleScope.launch(Dispatchers.Default) {
            try {
                runPipeline()
            } catch (t: Throwable) {
                Logger.e(tag, "supervisor crashed", t)
            }
        }
    }

    private fun stopRunning() {
        Logger.i(tag, "stopRunning")
        supervisor?.cancel()
        supervisor = null
        runCatching { lifecycleScope.launch { transport?.stop() } }
        client?.close()
        imageHelper?.stop()
        client = null
        transport = null
        imageHelper = null
        updateNotification(connected = false, host = "")
    }

    private suspend fun runPipeline() {
        val host = settings.host.trim()
        val port = settings.port
        if (host.isEmpty()) {
            Logger.e(tag, "runPipeline: host not configured; idling")
            return
        }

        val t = when (settings.transport) {
            Settings.Transport.PHONE -> PhoneMicTransport(applicationContext)
            Settings.Transport.META  -> MetaSdkTransport(applicationContext)
        }
        transport = t
        t.start()
        Logger.i(tag, "transport started label='${t.label}'")

        if (settings.imageFps > 0 && settings.transport == Settings.Transport.PHONE) {
            val helper = ImageCaptureHelper(applicationContext, this@RelayService)
            try {
                helper.start()
                imageHelper = helper
                Logger.i(tag, "image helper started fps=${settings.imageFps}")
            } catch (cause: Throwable) {
                Logger.w(tag, "image helper failed to start; continuing without images", cause)
            }
        }

        // Backoff: 1s, 2s, 4s, 8s, capped at 30s.
        var backoffMs = 1_000L
        while (currentCoroutineActive()) {
            val c = RelayClient(host, port)
            client = c
            c.connect()

            val collectJob = launch { drainClient(c, t) }
            val audioJob = launch { drainAudio(t, c) }
            val imageJob = launch { drainImages(c) }

            // Wait until any of them ends (connection lost / cancelled).
            collectJob.join()
            audioJob.cancel()
            imageJob.cancel()

            if (!currentCoroutineActive()) break
            if (!settings.autoReconnect) {
                Logger.i(tag, "autoReconnect disabled; exiting supervisor")
                break
            }
            Logger.w(tag, "connection lost; reconnecting in ${backoffMs}ms")
            delay(backoffMs)
            backoffMs = min(backoffMs * 2, 30_000L)
        }
        Logger.i(tag, "runPipeline: supervisor exit")
        t.stop()
    }

    private fun currentCoroutineActive(): Boolean = supervisor?.isActive == true

    private suspend fun drainClient(client: RelayClient, transport: GlassesTransport) {
        client.events.collect { ev ->
            when (ev) {
                is RelayClient.Incoming.Open -> {
                    Logger.i(tag, "ws open; sending hello")
                    val hello = JSONObject()
                        .put("type", "hello")
                        .put("version", BuildConfig.VERSION_NAME)
                        .put("transport", transport.label)
                    client.sendText(hello)
                    updateNotification(connected = true, host = "${client}")
                }
                is RelayClient.Incoming.TextEvent -> handleEvent(ev.event, ev.raw)
                is RelayClient.Incoming.TtsPcm -> {
                    Logger.i(tag, "tts pcm bytes=${ev.pcm.size}")
                    transport.playPcm(ev.pcm)
                }
                is RelayClient.Incoming.Unknown -> {
                    Logger.w(tag, "unknown frame tag=0x%02x bytes=%d".format(ev.tag, ev.size))
                }
                is RelayClient.Incoming.Closing -> {
                    Logger.i(tag, "ws closing code=${ev.code} reason='${ev.reason}'")
                    return@collect  // exit loop, supervisor will reconnect
                }
                is RelayClient.Incoming.Failure -> {
                    Logger.e(tag, "ws failure: ${ev.t.message}")
                    return@collect
                }
            }
        }
    }

    private fun handleEvent(event: JSONObject, raw: String) {
        val type = event.optString("event", event.optString("type", "?"))
        when (type) {
            "session_started" -> {
                Logger.i(tag, "session_started voice_gallery=${event.optInt("voice_gallery_size")} face_gallery=${event.optInt("face_gallery_size")} active=${event.optBoolean("active")}")
            }
            "speaker_identified" -> {
                Logger.i(tag, "speaker_identified name=${event.optString("name_en")}/${event.optString("name_zh")} conf=${event.optDouble("confidence")}")
            }
            "face_identified" -> {
                Logger.i(tag, "face_identified name=${event.optString("name_en")}/${event.optString("name_zh")} dist=${event.optDouble("distance_estimate_m")} bearing=${event.optString("bearing")} conf=${event.optDouble("confidence")}")
            }
            "daemon_status" -> {
                Logger.i(tag, "daemon_status daemon=${event.optString("daemon")} status=${event.optString("status")} msg=${event.optString("message")}")
            }
            "pong" -> {
                Logger.d(tag, "pong echo=${event.optString("echo")}")
            }
            else -> {
                Logger.d(tag, "event other type=$type raw=${raw.take(160)}")
            }
        }
    }

    private suspend fun drainAudio(transport: GlassesTransport, client: RelayClient) {
        transport.audioFlow().collectLatest { chunk ->
            if (!client.isOpen()) return@collectLatest
            client.sendAudio(chunk)
        }
    }

    private suspend fun drainImages(client: RelayClient) {
        val helper = imageHelper ?: return
        val fps = max(1, settings.imageFps)
        val periodMs = (1000L / fps).coerceAtLeast(100L)
        Logger.i(tag, "drainImages fps=$fps period=${periodMs}ms")
        while (currentCoroutineActive()) {
            if (!client.isOpen()) {
                delay(periodMs)
                continue
            }
            val jpeg = helper.captureJpeg()
            if (jpeg != null) {
                client.sendImage(jpeg)
            }
            delay(periodMs)
        }
    }

    // ---------- foreground notification ----------

    private fun startForegroundWithNotification(connected: Boolean) {
        ensureChannel()
        val notif = buildNotification(connected = connected, host = "")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIF_ID,
                notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA,
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun updateNotification(connected: Boolean, host: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIF_ID, buildNotification(connected = connected, host = host))
    }

    private fun buildNotification(connected: Boolean, host: String): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        val text = if (connected)
            getString(R.string.notif_text_connected, host)
        else
            getString(R.string.notif_text_disconnected)
        return NotificationCompat.Builder(this, NOTIF_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle(getString(R.string.notif_title))
            .setContentText(text)
            .setContentIntent(openIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun ensureChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(NOTIF_CHANNEL) == null) {
            val ch = NotificationChannel(
                NOTIF_CHANNEL,
                getString(R.string.notif_channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = getString(R.string.notif_channel_desc)
                setShowBadge(false)
            }
            nm.createNotificationChannel(ch)
        }
    }

    companion object {
        const val ACTION_START = "com.kangatnewyork.visioncompanion.relay.START"
        const val ACTION_STOP  = "com.kangatnewyork.visioncompanion.relay.STOP"
        private const val NOTIF_CHANNEL = "vc-relay-fg"
        private const val NOTIF_ID = 1001

        fun start(context: Context) {
            val i = Intent(context, RelayService::class.java).setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        fun stop(context: Context) {
            val i = Intent(context, RelayService::class.java).setAction(ACTION_STOP)
            context.startService(i)
        }
    }
}
