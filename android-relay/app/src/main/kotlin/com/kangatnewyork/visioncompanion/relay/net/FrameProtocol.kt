package com.kangatnewyork.visioncompanion.relay.net

import okio.ByteString
import okio.ByteString.Companion.toByteString

/**
 * Wire format shared with `openclaw-skills/relay/relay_server.py`. Keep in
 * sync — changes here MUST be mirrored on the Hermes side and vice versa.
 *
 * Binary frames are tagged with a single byte at offset 0:
 *
 *   uplink (Android -> Hermes):
 *     0x01  raw PCM, 16kHz mono int16 LE
 *     0x02  JPEG bytes
 *
 *   downlink (Hermes -> Android):
 *     0x03  TTS PCM, 22050Hz mono int16 LE (Piper output)
 *
 * Text frames are JSON objects with a "type" or "event" key; no tag byte.
 */
object FrameProtocol {

    const val UPLINK_AUDIO_PCM: Byte = 0x01
    const val UPLINK_IMAGE_JPEG: Byte = 0x02
    const val DOWNLINK_TTS_PCM: Byte = 0x03

    /** PCM format for the uplink audio stream. */
    const val AUDIO_SAMPLE_RATE_HZ = 16_000
    const val AUDIO_CHANNELS = 1
    const val AUDIO_SAMPLE_WIDTH_BYTES = 2 // int16 LE

    /** PCM format the relay sends back (Piper-native). */
    const val TTS_SAMPLE_RATE_HZ = 22_050
    const val TTS_CHANNELS = 1
    const val TTS_SAMPLE_WIDTH_BYTES = 2 // int16 LE

    fun encodeAudio(pcm: ByteArray): ByteString {
        val out = ByteArray(pcm.size + 1)
        out[0] = UPLINK_AUDIO_PCM
        System.arraycopy(pcm, 0, out, 1, pcm.size)
        return out.toByteString()
    }

    fun encodeImage(jpeg: ByteArray): ByteString {
        val out = ByteArray(jpeg.size + 1)
        out[0] = UPLINK_IMAGE_JPEG
        System.arraycopy(jpeg, 0, out, 1, jpeg.size)
        return out.toByteString()
    }

    /** Returns the tag byte, or 0 for empty payloads. */
    fun tagOf(bytes: ByteString): Byte =
        if (bytes.size > 0) bytes[0] else 0

    /** Returns the payload bytes following the tag. */
    fun payloadOf(bytes: ByteString): ByteArray =
        if (bytes.size > 1) bytes.substring(1).toByteArray() else ByteArray(0)
}
