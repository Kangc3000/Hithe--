package com.kangatnewyork.visioncompanion.relay.transport

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import androidx.core.content.ContextCompat
import com.kangatnewyork.visioncompanion.relay.Logger
import com.kangatnewyork.visioncompanion.relay.net.FrameProtocol
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume
import kotlin.math.max

/**
 * Dev-mode transport that captures audio from the phone's microphone and
 * plays TTS back through the phone's speaker. Image capture is delegated
 * to CameraX in a separate file (called via the relay service).
 *
 * Use this transport when:
 *   - Meta SDK access hasn't been granted yet
 *   - Iterating on the Hermes pipeline without the glasses in hand
 *   - Reproducing a bug that's easier to repro on the phone
 *
 * NOT a substitute for the real glasses transport for these reasons:
 *   - Phone mic is on the device, not at the user's ear
 *   - Phone speaker, not the open-ear glasses speaker
 *   - No touchpad events
 *
 * Image capture lives in ImageCapture.kt and is called from RelayService
 * rather than going through this class to avoid forcing every transport
 * implementation to embed CameraX. captureImage() here returns null and
 * delegates to the service layer when run-mode = PHONE.
 */
class PhoneMicTransport(
    private val context: Context,
) : GlassesTransport {

    private val tag = "Transport/Phone"

    override val label = "Phone mic + speaker"

    @Volatile private var running = false
    override val isRunning: Boolean get() = running

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val audioBus = MutableSharedFlow<ByteArray>(
        replay = 0, extraBufferCapacity = 32
    )

    private var recorder: AudioRecord? = null

    override suspend fun start() {
        if (running) return
        if (!hasRecordPermission()) {
            Logger.w(tag, "start: RECORD_AUDIO not granted; transport cannot capture")
            return
        }
        running = true
        scope.launch { captureLoop() }
        Logger.i(tag, "started sample_rate=${FrameProtocol.AUDIO_SAMPLE_RATE_HZ}")
    }

    override suspend fun stop() {
        if (!running) return
        running = false
        try { recorder?.stop() } catch (_: Throwable) {}
        try { recorder?.release() } catch (_: Throwable) {}
        recorder = null
        scope.coroutineContext.cancel()
        Logger.i(tag, "stopped")
    }

    override fun audioFlow(): Flow<ByteArray> = audioBus.asSharedFlow()

    override suspend fun captureImage(): ByteArray? {
        // Image capture goes through CameraX from the service; the transport
        // returns null here to signal "the host should call the camera path."
        return null
    }

    override suspend fun playPcm(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        val sampleRate = FrameProtocol.TTS_SAMPLE_RATE_HZ
        val channelMask = AudioFormat.CHANNEL_OUT_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minBuf = AudioTrack.getMinBufferSize(sampleRate, channelMask, encoding)
        val bufSize = max(minBuf, pcm.size)

        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setChannelMask(channelMask)
                    .setEncoding(encoding)
                    .build()
            )
            .setBufferSizeInBytes(bufSize)
            .setTransferMode(AudioTrack.MODE_STATIC)
            .build()

        try {
            track.write(pcm, 0, pcm.size)
            track.play()
            // Wait for playback to finish. AudioTrack.MODE_STATIC has no
            // marker callback equivalent that's pleasant from coroutines,
            // so we busy-poll the playback head until it stops advancing.
            withContext(Dispatchers.IO) {
                awaitPlaybackComplete(track, pcm.size / FrameProtocol.TTS_SAMPLE_WIDTH_BYTES)
            }
            Logger.d(tag, "playPcm bytes=${pcm.size} samples=${pcm.size / 2}")
        } catch (t: Throwable) {
            Logger.e(tag, "playPcm failed", t)
        } finally {
            try { track.stop() } catch (_: Throwable) {}
            try { track.release() } catch (_: Throwable) {}
        }
    }

    private suspend fun awaitPlaybackComplete(track: AudioTrack, totalSamples: Int) {
        suspendCancellableCoroutine<Unit> { cont ->
            val poller = Thread {
                try {
                    while (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                        val pos = track.playbackHeadPosition
                        if (pos >= totalSamples) break
                        Thread.sleep(20)
                    }
                } catch (_: InterruptedException) {
                    // ignore
                } finally {
                    if (cont.isActive) cont.resume(Unit)
                }
            }
            poller.isDaemon = true
            poller.start()
            cont.invokeOnCancellation { poller.interrupt() }
        }
    }

    @SuppressLint("MissingPermission") // checked in start()
    private suspend fun captureLoop() = withContext(Dispatchers.IO) {
        val sampleRate = FrameProtocol.AUDIO_SAMPLE_RATE_HZ
        val channelMask = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelMask, encoding)
        val bufSize = max(minBuf, sampleRate * 2 / 5) // ~200ms internal buffer

        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            sampleRate,
            channelMask,
            encoding,
            bufSize
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            Logger.e(tag, "AudioRecord not initialized; state=${rec.state}")
            try { rec.release() } catch (_: Throwable) {}
            running = false
            return@withContext
        }
        recorder = rec

        // Emit ~100ms chunks: 16000 Hz × 0.1s × 2 bytes = 3200 bytes
        val chunkBytes = (sampleRate / 10) * FrameProtocol.AUDIO_SAMPLE_WIDTH_BYTES
        val buf = ByteArray(chunkBytes)

        try {
            rec.startRecording()
            Logger.i(tag, "AudioRecord started buffer_bytes=$bufSize chunk_bytes=$chunkBytes")
            while (running && isActive) {
                var read = 0
                while (read < buf.size) {
                    val n = rec.read(buf, read, buf.size - read)
                    if (n <= 0) {
                        if (n == AudioRecord.ERROR_INVALID_OPERATION || n == AudioRecord.ERROR_BAD_VALUE) {
                            Logger.w(tag, "AudioRecord.read error=$n; stopping")
                            running = false
                        }
                        break
                    }
                    read += n
                }
                if (read == buf.size) {
                    audioBus.emit(buf.copyOf())
                }
            }
        } catch (t: Throwable) {
            Logger.e(tag, "captureLoop crashed", t)
        } finally {
            try { rec.stop() } catch (_: Throwable) {}
            try { rec.release() } catch (_: Throwable) {}
            recorder = null
            Logger.i(tag, "captureLoop exited")
        }
    }

    private fun hasRecordPermission(): Boolean =
        ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
}
