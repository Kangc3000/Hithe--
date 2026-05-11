# Setting up the Ray-Ban Meta glasses with the App

This guide gets the **glasses → phone → Hermes host** audio/video path
wired up. The Hermes host setup is a separate document
([SETUP-HERMES-AGENT.md](SETUP-HERMES-AGENT.md)).

The full step-by-step walkthrough lives in
[INSTALLATION-ANDROID.md](../INSTALLATION-ANDROID.md). This document
focuses just on the glasses pairing + Meta SDK plumbing.

---

## What you'll have at the end

- Glasses paired with the Galaxy S25, in Developer Mode
- Meta Wearables Device Access Toolkit dependency unlocked in the app
- App's "Glasses transport" setting flipped from PHONE to META
- A working audio loop: speak near the glasses → phone forwards to
  Hermes → name spoken back through the **glasses' speakers**

---

## Phase A — Pair and update the glasses (no code changes)

These steps don't require the app yet; do them first because the Meta
SDK access application in Step 3 takes hours-to-days to be approved.

### A1. Update the glasses firmware to v20 or later

Required by the Wearables Device Access Toolkit (Gen 1). For Gen 2,
the firmware floor will be confirmed when Meta publishes Gen 2 support.

1. Install the **Meta AI** app on the S25 from the Play Store (must
   be v254 or later — check inside the app).
2. Sign in with the Meta account that owns the glasses.
3. Open Meta AI → tap the glasses icon at the bottom → select your
   glasses → gear icon → **Device settings** → **General** → **About**.
4. Confirm **Software version** is v20 or later.
5. If older: put the glasses on the charging case **with the lid
   open** next to the S25 for ~1 hour. Updates download in the
   background.

### A2. Enable Developer Mode

1. Meta AI app → Devices → tap glasses → gear icon → scroll to **App
   version** at the bottom of the page.
2. **Tap the version number 5 times in quick succession** (within a
   couple of seconds).
3. A new **Developer Mode** toggle appears. Enable it.
4. Restart the Meta AI app.

If the toggle doesn't appear: the Meta AI app is below v254. Update
and retry.

### A3. Apply for the Wearables Device Access Toolkit (start this NOW)

This is the long-pole step.

1. Open <https://developers.meta.com/wearables/> in a browser.
2. Sign in with the Meta account that owns the glasses (or a
   developer account linked to it).
3. Apply for **Wearables Device Access Toolkit Public Preview** access.
4. Wait. Approval is typically same-day to a few days. While waiting,
   move on to Phase B.

### A4. Create a GitHub personal access token (in parallel with A3)

The toolkit is hosted on Meta's private GitHub Packages repo, which
needs Gradle to authenticate.

1. GitHub → Settings → Developer settings → **Personal access tokens
   (classic)** → Generate new token (classic).
2. Token name: `Vision Companion - Wearables SDK`.
3. Scope: only `read:packages`.
4. Expiration: 1 year.
5. Copy the token. Save it in a password manager.

---

## Phase B — Wire the token into your Gradle config

This file lives OUTSIDE the repo so it's never committed.

```powershell
# On Windows:
notepad $env:USERPROFILE\.gradle\gradle.properties
```

Add (or merge with existing contents):

```properties
gpr.user=YOUR_GITHUB_USERNAME
gpr.key=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

The `settings.gradle.kts` in `android-relay/` already references these
properties (look for `maven.pkg.github.com/meta-wearables`).

---

## Phase C — Use the app in dev mode until Meta access lands

You don't have to wait. The app works **fully** without the Meta SDK —
it uses the phone's own microphone and back camera. Build and
sideload now per [BUILDING-APK.md](BUILDING-APK.md), then come back
here when Phase A3 is approved.

---

## Phase D — Once Meta access is granted

You'll get an email from Meta. Now wire it in.

### D1. Uncomment the Meta dependency

Edit `android-relay/app/build.gradle.kts`:

```kotlin
dependencies {
    // ...existing lines...

    // Uncomment this (replace version with whatever Meta's docs say
    // is current):
    implementation("com.meta.wearables:device-access-toolkit:0.1.0")
}
```

Then sync Gradle. The dependency should resolve via the GitHub
Packages credentials you added in Phase B.

### D2. Fill in MetaSdkTransport.kt

Open
`android-relay/app/src/main/kotlin/com/kangatnewyork/visioncompanion/relay/transport/MetaSdkTransport.kt`.

The stub has comments describing each method's contract. Replace the
`NotImplementedError` body with real Meta SDK calls:

```kotlin
override suspend fun start() {
    // 1. Acquire the SDK's wearables client.
    //    val client = MetaWearablesClient.connect(context, deviceId = ...)
    // 2. Subscribe to the audio stream:
    //    client.audioStream(format = AudioFormat.PCM_16K_MONO_INT16)
    //        .collect { chunk -> audioBus.emit(chunk.bytes) }
    // 3. Cache the client for captureImage() and playPcm().
}

override suspend fun captureImage(): ByteArray? {
    // 1. Request a single still.
    //    return client.capturePhoto(jpegQuality = 85)
}

override suspend fun playPcm(pcm: ByteArray) {
    // 1. Stream the PCM to the glasses' open-ear speakers.
    //    client.playAudio(pcm, format = AudioFormat.PCM_22K_MONO_INT16)
}
```

The exact API names depend on Meta's current SDK version — read their
documentation at <https://wearables.developer.meta.com/docs/> and
adapt.

### D3. Verify and rebuild

```powershell
cd android-relay
./gradlew --refresh-dependencies :app:bundleRelease
```

If the build succeeds, push a new AAB to Play Console internal testing
(see [BUILDING-APK.md](BUILDING-APK.md) Step 8).

### D4. Switch the app to Meta transport

On the S25 (after installing the new build):

1. Open Vision Companion Relay app.
2. **Glasses transport** → select **Meta Wearables SDK**.
3. Tap **Start relay**.
4. Speak; you should hear your name through the **glasses' speakers**
   (not the phone speaker) within ~2 seconds.

If you hear the name through the phone instead, the transport setting
didn't switch — double-check it.

---

## Troubleshooting

### "Meta Wearables Inspector says it can't find my glasses"

- Confirm firmware ≥ v20 (Phase A1).
- Confirm Developer Mode is on (Phase A2). If you don't see the
  toggle, your Meta AI app is below v254.
- Re-pair: Meta AI app → Devices → Forget → re-pair.

### "Gradle build fails: could not authenticate to maven.pkg.github.com"

- The `gpr.user` / `gpr.key` properties in
  `~/.gradle/gradle.properties` are missing or wrong.
- The PAT must have `read:packages` scope and not be expired.
- Test with `curl` to confirm: `curl -u $USER:$TOKEN https://maven.pkg.github.com/meta-wearables/sdk-android` should return JSON, not 401.

### "App audio still comes out of the phone speaker after switching to Meta transport"

- The phone might still be the active audio output for the OS. Check
  Android's audio routing (drag down the status bar, look at the
  output device chip).
- Some Meta SDK builds require an explicit "route audio to glasses"
  call. Read the Meta docs you have access to.
- As a last resort, log the AudioFormat used by the SDK and confirm
  it matches what `playPcm` produces.

### "I want to test face-id specifically"

- In the app, set **Image FPS** to **1** (or higher). At 0 the app
  doesn't upload images at all.
- On the Hermes host, watch `tail -f
  ~/.hermes/voice-companion/events.jsonl | grep face_identified`.
- If the camera frame is blank, the glasses may not have granted
  camera access. Re-pair and re-grant.

---

## Where this all leaves you

Once Phase D is complete:

- Your wife wears the glasses.
- Someone she knows speaks.
- Within ~2 seconds she hears their name through the open-ear glasses
  speakers in the appropriate language.

That's the Phase 1 "done" criteria from CLAUDE.md.

For face-id (Phase 2): she looks at the person; the system identifies
them visually plus a rough distance.

For scene description (Phase 3): she taps the glasses' touchpad; the
system describes what's in front of her. Phase 3 is not yet
implemented — see PROJECT-SPEC.md section 6 for the phase plan.
