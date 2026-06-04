package com.kangatnewyork.visioncompanion.relay.net

import com.kangatnewyork.visioncompanion.relay.Logger
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONException
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * WebSocket client to the relay_server on the Hermes host.
 *
 * Single connection. Exposes a SharedFlow of `Incoming` events the
 * service can collect. Auto-reconnect is left to the caller (the
 * service), which adds a delay and backoff.
 *
 * The serverUrl is the full WebSocket URL — supports `ws://` (plain) and
 * `wss://` (TLS, used when going through Apache + Let's Encrypt). The
 * token belongs in the URL query string; this class does not extract or
 * massage it.
 */
class RelayClient(
    private val serverUrl: String,
) {
    private val tag = "Net"
    // For logs we strip the token query string so it doesn't leak into log
    // files. The pre-? part is fine to show.
    private val peerLabel: String = serverUrl.substringBefore('?').take(120)

    private val client = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        .connectTimeout(10, TimeUnit.SECONDS)
        .build()

    private val incoming = MutableSharedFlow<Incoming>(
        replay = 0,
        extraBufferCapacity = 64,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    private var ws: WebSocket? = null
    private val opened = AtomicBoolean(false)

    val events: SharedFlow<Incoming> = incoming.asSharedFlow()

    sealed interface Incoming {
        data class Open(val response: Response) : Incoming
        data class TextEvent(val event: JSONObject, val raw: String) : Incoming
        data class TtsPcm(val pcm: ByteArray) : Incoming {
            override fun equals(other: Any?) = false  // ByteArray identity
            override fun hashCode() = System.identityHashCode(this)
        }
        data class Unknown(val tag: Byte, val size: Int) : Incoming
        data class Closing(val code: Int, val reason: String) : Incoming
        data class Failure(val t: Throwable, val response: Response?) : Incoming
    }

    fun connect() {
        if (opened.get()) {
            Logger.w(tag, "connect called while already open peer=$peerLabel")
            return
        }
        Logger.i(tag, "connect url=$peerLabel")
        val request = Request.Builder().url(serverUrl).build()
        ws = client.newWebSocket(request, Listener())
    }

    fun isOpen(): Boolean = opened.get()

    fun close() {
        val w = ws ?: return
        Logger.i(tag, "close peer=$peerLabel")
        try {
            w.close(1000, "client_close")
        } catch (_: Throwable) {}
        ws = null
        opened.set(false)
    }

    fun sendAudio(pcm: ByteArray): Boolean {
        val w = ws ?: return false
        return try {
            val ok = w.send(FrameProtocol.encodeAudio(pcm))
            if (!ok) Logger.w(tag, "sendAudio: queue full bytes=${pcm.size}")
            ok
        } catch (t: Throwable) {
            Logger.e(tag, "sendAudio crashed", t)
            false
        }
    }

    fun sendImage(jpeg: ByteArray): Boolean {
        val w = ws ?: return false
        return try {
            val ok = w.send(FrameProtocol.encodeImage(jpeg))
            if (!ok) Logger.w(tag, "sendImage: queue full bytes=${jpeg.size}")
            ok
        } catch (t: Throwable) {
            Logger.e(tag, "sendImage crashed", t)
            false
        }
    }

    fun sendText(json: JSONObject): Boolean {
        val w = ws ?: return false
        return try {
            w.send(json.toString())
        } catch (t: Throwable) {
            Logger.e(tag, "sendText crashed", t)
            false
        }
    }

    private inner class Listener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            opened.set(true)
            Logger.i(tag, "onOpen peer=$peerLabel http_status=${response.code}")
            incoming.tryEmit(Incoming.Open(response))
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            Logger.v(tag, "text in chars=${text.length}")
            try {
                val obj = JSONObject(text)
                incoming.tryEmit(Incoming.TextEvent(obj, text))
            } catch (e: JSONException) {
                Logger.w(tag, "non-JSON text: ${text.take(80)}")
            }
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            if (bytes.size == 0) return
            val tagByte = FrameProtocol.tagOf(bytes)
            val payload = FrameProtocol.payloadOf(bytes)
            Logger.v(tag, "binary in tag=0x%02x bytes=%d".format(tagByte, payload.size))
            when (tagByte) {
                FrameProtocol.DOWNLINK_TTS_PCM -> incoming.tryEmit(Incoming.TtsPcm(payload))
                else -> incoming.tryEmit(Incoming.Unknown(tagByte, payload.size))
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            Logger.i(tag, "onClosing code=$code reason='$reason' peer=$peerLabel")
            incoming.tryEmit(Incoming.Closing(code, reason))
            // ack with our own close
            try {
                webSocket.close(code, reason)
            } catch (_: Throwable) {}
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            Logger.i(tag, "onClosed code=$code reason='$reason' peer=$peerLabel")
            opened.set(false)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            Logger.e(tag, "onFailure peer=$peerLabel response=${response?.code}", t)
            opened.set(false)
            incoming.tryEmit(Incoming.Failure(t, response))
        }
    }
}
