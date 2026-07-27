package com.kangatnewyork.visioncompanion.relay.transport

import kotlinx.coroutines.flow.Flow

/**
 * Abstracts the glasses input/output surface so the rest of the relay
 * doesn't care whether the audio came from a real Ray-Ban Meta or the
 * phone's microphone.
 *
 * Locked by PROJECT-SPEC.md section 10. Don't expand without updating
 * the spec — the adapter pattern is load-bearing for Gen 1 + Gen 2
 * support and future device additions.
 *
 * Lifecycle:
 *   - `start()` opens the underlying capture / playback resources.
 *   - `audioFlow()` may only be collected while the transport is started.
 *   - `captureImage()` is a suspending call that returns a single JPEG.
 *   - `playPcm()` plays one buffer to completion (suspending).
 *   - `stop()` releases everything.
 *
 * Implementations must be safe to start → stop → start again.
 */
interface GlassesTransport {

    /** Called by the user-visible name for the active transport (logs / UI). */
    val label: String

    /** Returns the audio sample rate this transport emits, in Hz. */
    val audioSampleRateHz: Int get() = 16_000

    /** Returns true if the transport is currently started. */
    val isRunning: Boolean

    suspend fun start()

    suspend fun stop()

    /**
     * Stream of PCM byte arrays. Format matches `audioSampleRateHz`,
     * mono, int16 LE. Implementations should emit ~100 ms chunks for
     * good interactive latency.
     *
     * Cold flow: collection starts capture; cancelling collection
     * pauses capture. Multiple collectors are not supported.
     */
    fun audioFlow(): Flow<ByteArray>

    /**
     * Captures a single still frame. Returns JPEG bytes, or null on
     * failure (no permission, hardware busy, etc — implementations
     * MUST log the cause).
     */
    suspend fun captureImage(): ByteArray?

    /**
     * Plays raw PCM through the transport's audio output. Format is
     * Piper-native: 22050 Hz mono int16 LE.
     */
    suspend fun playPcm(pcm: ByteArray)
}
