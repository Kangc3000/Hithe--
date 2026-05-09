# Installation Guide — Android + Ray-Ban Meta Gen 1

End-to-end setup walkthrough. Follow steps in order; later steps depend
on earlier ones.

> **Read `PROJECT-SPEC.md` first.** This guide assumes you've decided to
> proceed with the locked architecture.

---

## What you'll have when this is done

- Ray-Ban Meta Gen 1 paired with the Galaxy S25 in **Developer Mode**
- An Android relay app installed on the S25 that streams audio from the
  glasses to your Hermes Ubuntu host over Tailscale
- The Hermes host running the voice-id daemon as a systemd service
- The voice-id Hermes skill registered and callable from chat
- Yourself enrolled in the voice gallery as the first test user
- A documented smoke test that proves the end-to-end path works

Total time: 2-4 hours, depending on whether you've done Android
development before. The Meta SDK signup can take a few hours of
asynchronous waiting, so start step 4 early.

---

## Hardware checklist

Before you start, confirm you have:

- [x] Ray-Ban Meta Gen 1 (already owned)
- [x] Samsung Galaxy S25 (Android 15+)
- [x] Ubuntu 26.04 host with Hermes Agent installed
- [x] Tailscale running on both Galaxy S25 and Ubuntu host
- [x] A USB-C cable for installing the relay app on the S25
  (until you publish to internal track)
- [x] Working WiFi at home for both devices
- [x] Ophthalmologist letter ready if you'll later request ADA
  accommodation for classroom use (optional now, eventual prereq)

---

## Step 1 — Update the Ray-Ban Meta firmware

The Wearables Device Access Toolkit requires Ray-Ban Meta firmware **v20
or later** for **Gen 1**. Gen 2 firmware floor will be confirmed when
Meta publishes Gen 2 toolkit support; the steps below describe the
Gen 1 flow but are expected to apply to Gen 2 with the version number
substituted appropriately.

1. Open the **Meta AI** app on the S25 (install from Play Store if
   missing — needs version **v254 or later**).
2. Sign in to the Meta account that owns your wife's glasses.
3. Tap the glasses icon at the bottom of the app.
4. Select her glasses.
5. Tap the gear icon to open **Device settings**.
6. Tap **General** → **About**.
7. Confirm **Software version is v20 or later**. If older, leave the
   glasses on the charging case for an hour with the case lid open
   while next to the S25 — firmware updates download automatically when
   the glasses are idle.

### Verify v20+ before proceeding

If the version is below v20 after waiting, force an update:
- Open Meta AI app → Devices → tap glasses → gear → check for updates
- If still stuck, factory reset the case (hold pairing button 15s) and
  re-pair. Updates download fresh on first pair.

---

## Step 2 — Enable Developer Mode on the glasses

1. Open Meta AI app → **Devices** → tap her Ray-Ban Meta.
2. Tap the gear icon (top-right) to open **Device settings**.
3. Scroll down and tap **App version** (the small line showing the app
   version number, like "v254.0.0").
4. **Tap that version number five times in quick succession.**
5. A new toggle appears: **Developer Mode**. Enable it.
6. Restart the Meta AI app.

If the toggle doesn't appear, you're below app v254 — update from Play
Store and try again.

---

## Step 3 — Set up Android Studio on your dev machine

You need Android Studio (any recent version, Hedgehog or later) on the
machine where you'll build the relay app. This can be your Mac mini,
your DGX Spark, or a separate laptop — does not have to be the Hermes
host.

1. Download Android Studio from <https://developer.android.com/studio>
2. Install with default options
3. Open Android Studio → SDK Manager → install:
   - Android SDK Platform 35 (Android 15)
   - Android SDK Build-Tools 35.0.0
   - Android SDK Command-line Tools (latest)

Skip the new project wizard for now — you'll clone the relay-app
template in step 5.

---

## Step 4 — Get Wearables Device Access Toolkit access (start early)

This is the step with asynchronous wait time. Start it before the
others.

1. Go to <https://developers.meta.com/wearables/>
2. Sign in with the Meta account that owns the glasses (or a developer
   account linked to it).
3. Apply for the **Wearables Device Access Toolkit Public Preview**.
4. While waiting, generate a **GitHub Personal Access Token (classic)**
   with the `read:packages` scope:
   - GitHub → Settings → Developer settings → Personal access tokens
     → Tokens (classic) → Generate new token (classic)
   - Name it "Vision Companion - Wearables SDK"
   - Scopes: check `read:packages` only
   - Expiration: 1 year
   - Save the token somewhere safe — you'll need it for Gradle config
     in step 6

Approval is typically same-day to a few days. While waiting, continue
to step 5.

---

## Step 5 — Clone or scaffold the Android relay app

The Android relay app is **not yet written** as of 2026-05-09. When
it is, this step will say:

```bash
git clone https://github.com/<your-username>/vision-companion-android.git
cd vision-companion-android
```

For now, scaffold a new Empty Activity project in Android Studio:

- New Project → Empty Views Activity
- Name: `VisionCompanionRelay`
- Package: `com.kangatnewyork.visioncompanion.relay`
- Language: Kotlin
- Min SDK: API 29 (Android 10)
- Build configuration language: Kotlin DSL (`build.gradle.kts`)

The relay app will eventually need:
- Dependencies on Meta's Wearables Device Access Toolkit (added in
  step 6)
- Foreground service for the audio streaming pipeline
- Permissions: `INTERNET`, `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`,
  `RECORD_AUDIO`, `FOREGROUND_SERVICE`
- A Tailscale-aware HTTP/WebSocket client for the home-server hop

The full relay app is the next major build deliverable after Phase 1
runs end-to-end on the Hermes host alone.

---

## Step 6 — Add the Wearables SDK to the relay app's Gradle config

Once Meta approves your developer access, add the Android SDK to your
Gradle config.

In `~/.gradle/gradle.properties`, add:

```properties
gpr.user=<your_github_username>
gpr.key=<the_personal_access_token_from_step_4>
```

**Never commit these to git.** The `~/.gradle/gradle.properties` lives
outside the project for this reason.

In your project's `settings.gradle.kts`:

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://maven.pkg.github.com/meta-wearables/sdk-android")
            credentials {
                username = providers.gradleProperty("gpr.user").get()
                password = providers.gradleProperty("gpr.key").get()
            }
        }
    }
}
```

In your app module's `build.gradle.kts`:

```kotlin
dependencies {
    implementation("com.meta.wearables:device-access-toolkit:0.1.0")
    // ...other deps
}
```

Verify the dependency resolves by running `./gradlew --refresh-dependencies build`
from the project root.

> The exact package name and version may have changed since this
> document was written — check Meta's official setup page at
> <https://wearables.developer.meta.com/docs/setup/> for current values.

---

## Step 7 — Set up the Hermes host (Phase 1 backend)

This step installs the voice-id daemon, skill, and dependencies on
your Ubuntu Hermes box. It's idempotent — safe to re-run.

On the Ubuntu host (run as your normal user, NOT root):

```bash
# Get the project files
cd ~
git clone https://github.com/<you>/vision-companion.git
cd vision-companion/hermes-skill/voice-id

# Run the installer
chmod +x install-on-hermes.sh
./install-on-hermes.sh
```

The installer (see the script for details):
- Installs apt prerequisites (audio, Python venv, ffmpeg)
- Creates `~/.hermes/voice-companion/` directory layout
- Sets up Python 3.11+ venv with SpeechBrain, faster-whisper, etc.
- Downloads Piper TTS and the bilingual voice models (~60MB total)
- Installs the `voice-id` SKILL.md into `~/.hermes/skills/`
- Installs and enables the systemd user service

When it completes, you'll see a "Next steps" message.

---

## Step 8 — Enroll yourself

Before testing the full pipeline, enroll yourself as the first voice.

```bash
cd ~/.hermes/voice-companion/scripts
source .venv/bin/activate

python enroll.py --record --consent-confirmed \
    --name-en "Kang" --name-zh "康" \
    --notes "primary user / spouse"
```

The script will record three 8-second samples. Speak naturally — talk
about your day, read a paragraph from a book, anything that's *your*
voice in *your* normal speaking patterns. Don't whisper or shout.

Verify the gallery:

```bash
python enroll.py --list
```

You should see Kang / 康 listed with 3 samples.

---

## Step 9 — Smoke test (Hermes host only)

Before involving the glasses or the phone, verify the daemon pipeline
works on the Hermes box's local microphone and speakers.

```bash
# In one terminal — test TTS in isolation
echo '{"event":"speaker_identified","name_en":"Kang","name_zh":"康"}' \
    | python tts_announce.py --last-input-lang zh
# You should hear "康" through the host's speakers.

# In another terminal — start the daemon
systemctl --user start voice-id-daemon
systemctl --user status voice-id-daemon
tail -f ~/.hermes/voice-companion/daemon.log
```

Now talk to the host's microphone. Within a few seconds, your name
should be announced through the speakers, in either zh or en depending
on `language_mode` in `config.yaml`.

If something doesn't work, see the **Troubleshooting** section below.

---

## Step 10 — Verify Hermes sees the skill

```bash
hermes skills list | grep voice-id
hermes chat -q "Use voice-id to list enrolled people"
```

You should get back a Hermes response listing yourself. If Hermes can't
find the skill, check:

```bash
ls -la ~/.hermes/skills/voice-id/
```

The directory should contain `SKILL.md`. If missing, re-run the
installer (step 7).

---

## Step 11 — Pair the Galaxy S25 with the glasses

Already done if she's been wearing them. To verify Developer Mode is
recognized, install Meta's "Wearables Inspector" app from
<https://wearables.developer.meta.com/docs/getting-started-toolkit/> and
run it. It should detect the glasses and show their device ID.

---

## Step 12 — (Future) Build and install the Android relay app

This step depends on the relay app source code, which is the next
major deliverable. When it's ready:

```bash
cd vision-companion-android
./gradlew installDebug
```

You'll need:
- USB-C debugging enabled on the S25 (Settings → Developer options
  → USB debugging — enable Developer options by tapping Build number
  7 times in About phone)
- The S25 connected to your dev machine via USB-C, with the "Allow USB
  debugging?" prompt accepted on the phone
- Tailscale running on both the S25 and the Hermes host
- The relay app configured with the Tailscale IP of the Hermes host
  (set in the app's first-run config screen)

---

## Step 13 — End-to-end smoke test (with glasses)

Once the relay app is installed and configured:

1. Make sure Tailscale is connected on both phone and host.
2. Open the relay app on the S25 → Connect to glasses.
3. Have the glasses on; speak something.
4. Within ~2 seconds, you should hear your name through the **glasses'
   speakers** (not the phone or host).
5. Check `~/.hermes/voice-companion/daemon.log` to see the event was
   logged.
6. Check `~/.hermes/voice-companion/events.jsonl` for the event line.

If you hear yourself announced, Phase 1 is complete.

---

## Troubleshooting

### Daemon won't start (systemctl status shows "failed")

```bash
journalctl --user -u voice-id-daemon -n 50
```

Common causes:
- Piper binary not on PATH → reinstall via the installer script
- Voice model files missing → check
  `ls ~/.local/share/piper/voices/` should show 4 files
- Python venv broken → delete `~/.hermes/voice-companion/scripts/.venv`
  and re-run installer

### TTS speaks but voice sounds wrong language

Edit `~/.hermes/voice-companion/config.yaml`:
- Set `language_mode: preferred_zh` to force Chinese
- Set `language_mode: preferred_en` to force English
- Restart: `systemctl --user restart voice-id-daemon`

### Voice ID never matches (always "unknown speaker")

- Run `python enroll.py --list` to confirm gallery is populated
- Lower `similarity_threshold` from 0.65 to 0.60 in config.yaml
- Re-enroll with cleaner samples (no background noise, normal volume)

### Voice ID matches the wrong person

- Raise `similarity_threshold` from 0.65 to 0.70
- Re-enroll the misidentified person with more diverse samples

### Audio output works on host but not glasses

This is expected — the glasses can't hear the host's microphone or
speak through the host's speakers. The Android relay app (step 12)
is what bridges them. Until that's built, you can only test on the
host's local audio devices.

### Glasses won't enter Developer Mode

- Confirm Meta AI app version ≥ 254
- Confirm glasses firmware ≥ v20
- Tap version number rapidly (within ~2 seconds total)
- Restart Meta AI app and try again

### Tailscale path between S25 and Hermes host is slow

- Confirm both are on the same tailnet (`tailscale status` on host)
- If MagicDNS is enabled, use the hostname (`hermes-host`) rather than
  IP in the relay app config
- Test bandwidth: `tailscale ping hermes-host` from the phone

### OpenAI API errors (Phase 3 onward)

- Verify `OPENAI_API_KEY` is set in `~/.hermes/.env`
- Check current rate limits on platform.openai.com
- Confirm `classroom_mode: false` in config.yaml — when true, all
  cloud calls are blocked by design

---

## Maintenance

- **Weekly:** check `~/.hermes/voice-companion/daemon.log` for
  recurring errors
- **Monthly:** review `~/.hermes/voice-companion/events.jsonl`,
  consider tuning thresholds based on observed accuracy
- **When firmware updates:** Meta sometimes changes the SDK with major
  firmware updates — re-test end-to-end after any v21+, v22+, etc.
- **When OpenAI deprecates models:** swap `openai_model` in config.yaml
  to the new model ID; restart the daemon

---

## Where to go next

Phase 1 working end-to-end is the milestone. After that, in order:

1. **Phase 2: Face ID** — Add visual identification of enrolled people.
   See `docs/IMPLEMENTATION-GUIDE.md` for the contract; new daemon
   under `~/.hermes/voice-companion/scripts/face_id.py`.
2. **Phase 3: Scene description** — Add OpenAI gpt-5-mini cloud calls
   for on-demand scene/menu/sign description.
3. **Phase 4: Traffic awareness** — On-device YOLO11n on the S25 for
   low-latency object detection. See safety caveats in `PROJECT-SPEC.md`.

For classroom deployment, see `docs/CLASSROOM-CONSIDERATIONS.md` —
it's a separate process that runs in parallel with phases 2-4.
