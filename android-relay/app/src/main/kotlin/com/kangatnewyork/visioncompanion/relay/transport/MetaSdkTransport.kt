package com.kangatnewyork.visioncompanion.relay.transport

import android.content.Context
import com.kangatnewyork.visioncompanion.relay.Logger
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

/**
 * STUB implementation of GlassesTransport for the Ray-Ban Meta Gen 1/Gen 2
 * via the Wearables Device Access Toolkit. Until SDK access is granted
 * (INSTALLATION-ANDROID.md Step 4) and the dependency is uncommented in
 * `app/build.gradle.kts`, this class throws on use.
 *
 * Once the SDK is available, the implementation should:
 *
 *   1. Acquire a `MetaWearablesClient` from the SDK using the credentials
 *      configured during pairing.
 *   2. Open a microphone audio stream — the SDK exposes a Flow of 16kHz
 *      mono PCM chunks per its docs; route those directly into `audioBus`.
 *   3. For `captureImage()`, request a single still from the SDK's camera
 *      API and return JPEG bytes.
 *   4. For `playPcm()`, write the PCM to the SDK's audio playback channel
 *      (the open-ear speaker on the glasses).
 *   5. Expose the touchpad event Flow (PROJECT-SPEC.md section 10) by
 *      extending GlassesTransport with a new method once we know what
 *      events the SDK actually surfaces.
 *
 * Resources:
 *   - Meta Wearables Device Access Toolkit setup:
 *     https://wearables.developer.meta.com/docs/setup/
 *   - Sample apps (gated by developer account):
 *     https://github.com/meta-wearables/sdk-android
 *
 * This stub class is the ONLY place that should change when the SDK
 * lands. The rest of the relay app is SDK-agnostic.
 */
class MetaSdkTransport(
    @Suppress("UNUSED_PARAMETER") context: Context,
) : GlassesTransport {

    private val tag = "Transport/Meta"

    override val label = "Meta Wearables SDK (not yet available)"
    override val audioSampleRateHz = 16_000
    override val isRunning = false

    override suspend fun start() {
        Logger.e(tag, "Meta SDK transport is a stub — switch to PHONE transport for now")
        throw NotImplementedError(
            "Meta Wearables Device Access Toolkit is not yet integrated. " +
                "See INSTALLATION-ANDROID.md Step 4 + Step 6, and the comments in " +
                "MetaSdkTransport.kt for what to fill in once SDK access is granted."
        )
    }

    override suspend fun stop() {
        // no-op; never started
    }

    override fun audioFlow(): Flow<ByteArray> = emptyFlow()

    override suspend fun captureImage(): ByteArray? = null

    override suspend fun playPcm(pcm: ByteArray) {
        Logger.w(tag, "playPcm called on stub transport; ignored (${pcm.size} bytes)")
    }
}
