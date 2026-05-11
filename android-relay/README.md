# Android Relay App — Vision Companion (解語)

Galaxy S25 relay app that streams audio + image frames from the Ray-Ban
Meta glasses (or the phone's own mic + camera in dev mode) to the Hermes
host's `relay_server.py` over Tailscale-routed WebSocket, and plays back
the TTS audio it receives.

This directory is a fully-formed Android Studio project. Open it with
**Android Studio Hedgehog (2023.1) or later**.

> **Read [INSTALLATION-ANDROID.md](../INSTALLATION-ANDROID.md) first.** It
> covers the prerequisite Meta SDK access flow, firmware floor, etc.

## Status of the Meta SDK integration

The Meta Wearables Device Access Toolkit dependency is **commented out**
in `app/build.gradle.kts` and `MetaSdkTransport.kt` is a documented
**stub**. Until SDK access is granted (typically same-day to a few days
after applying at <https://developers.meta.com/wearables/>), the app
runs entirely on the phone's hardware:

- audio uplink: phone microphone
- image uplink: phone back camera (CameraX)
- TTS playback: phone speaker

This lets the entire end-to-end pipeline (phone → Hermes → phone) be
tested without the glasses, which is what we use for development. Once
Meta SDK access is granted, the only file that needs editing is
`transport/MetaSdkTransport.kt`. Comments inside that file enumerate
what to implement.

## Build

From the project root:

```bash
# Sync dependencies (Android Studio does this automatically when the
# project opens, but the CLI form helps in CI):
./gradlew --refresh-dependencies

# Debug APK (sideloads work):
./gradlew :app:assembleDebug

# Install on a connected USB-C device with developer mode + USB debugging:
./gradlew :app:installDebug
```

The Gradle wrapper jar (`gradle/wrapper/gradle-wrapper.jar`) is binary
and not committed to the repo. Run `gradle wrapper --gradle-version 8.5`
once after opening the project, or let Android Studio generate it for
you (it does this on first open).

## First-run configuration on the phone

1. Open the app. It asks for permissions (mic, camera, notifications,
   bluetooth). Grant all of them.
2. Fill in:
   - **Hermes host** — tailnet hostname like `hermes-host`, or the
     `100.x.y.z` IP from `tailscale status`
   - **Port** — defaults to 8765
   - **Image FPS** — start at 0 (audio-only). Bump to 1 or 2 once
     face-id is wanted.
   - **Glasses transport** — leave as "Phone mic + camera (dev)" until
     Meta SDK is integrated.
3. Tap **Test connection**. Within 5 seconds the status row should read
   "Connected to host:port". If it errors out, check
   `tailscale status` on both ends.
4. Tap **Start relay**. The notification appears and stays. Speak; the
   relay log on the Hermes host should show a `speaker_identified`
   event within ~2 seconds.

## Where the logs live

- Logcat: filter for tag prefix `VC/`
- File: `/Android/data/com.kangatnewyork.visioncompanion.relay/files/logs/relay-YYYY-MM-DD.log`
  - Pull via USB/MTP, or use **Open log folder** in the app to view
  - Rotated daily, kept for 14 days

Adjust verbosity at runtime in **Settings → Log level**. DEBUG and
VERBOSE add per-chunk RMS + frame size to the file (helpful for
debugging "is data flowing?" but noisy).

## Project layout

```
app/src/main/
├── AndroidManifest.xml
├── kotlin/com/kangatnewyork/visioncompanion/relay/
│   ├── MainActivity.kt            settings UI, start/stop, test-connection
│   ├── RelayService.kt            foreground service tying everything together
│   ├── Settings.kt                SharedPreferences-backed
│   ├── Logger.kt                  Logcat + rotating file logger
│   ├── net/
│   │   ├── FrameProtocol.kt       wire-format constants (must match relay_server.py)
│   │   └── RelayClient.kt         OkHttp WebSocket client
│   ├── transport/
│   │   ├── GlassesTransport.kt    PROJECT-SPEC §10 adapter interface
│   │   ├── PhoneMicTransport.kt   dev impl using phone mic + speaker
│   │   └── MetaSdkTransport.kt    STUB — fill in once SDK access granted
│   └── image/
│       └── ImageCaptureHelper.kt  CameraX single-shot JPEG
└── res/
    ├── layout/activity_main.xml
    ├── values/strings.xml         English
    └── values-zh-rTW/strings.xml  Traditional Chinese
```

## Wire format

The app and the Hermes relay agree on this protocol. Changes here
require matching edits in `openclaw-skills/relay/relay_server.py`.

| Direction | Frame | Tag | Payload |
|-----------|-------|-----|---------|
| → Hermes | binary | 0x01 | raw PCM, 16kHz mono int16 LE |
| → Hermes | binary | 0x02 | JPEG bytes |
| → Hermes | text | -    | JSON: `{"type":"ping"\|"hello"\|"shutdown", ...}` |
| ← Hermes | binary | 0x03 | TTS PCM, 22050Hz mono int16 LE |
| ← Hermes | text | -    | JSON event line (recognition/status) |
