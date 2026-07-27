# Building the Android APK / AAB for Google Play Store

How to take the source in [`android-relay/`](../android-relay/) and
produce a signed Android App Bundle (AAB) that can be uploaded to your
Google Play Console as a private internal-testing release.

> This is a personal app for one user. Public Play Store distribution
> is NOT the goal. Use the **Internal testing track** so only invited
> testers (you + your wife's account) can install.

---

## Prerequisites

- **Android Studio Hedgehog (2023.1) or later** installed on Windows /
  macOS / Linux. Do this once.
- The Android Studio SDK Manager has installed **Android SDK Platform
  35** (Android 15) and **Build-Tools 35.0.0** (`File → Settings →
  Appearance & Behavior → System Settings → Android SDK`).
- A **Google Play Console** account (one-time US$25 fee).
- A **fresh Gmail account** to use as the testing tester is OK; you'll
  need to invite that email under "Internal testing" later.

---

## Step 1 — One-time keystore creation

Every Android app released to Play must be signed by a developer key.
**Losing this key means you can never publish an update.** Back it up.

```powershell
# Run on Windows in PowerShell (Linux/macOS shell equivalent works too).
# Choose a directory OUTSIDE the repo. The keystore must NEVER be
# committed to git.
$keystoreDir = "$env:USERPROFILE\.hithe-android-signing"
New-Item -ItemType Directory -Force $keystoreDir | Out-Null

keytool -genkey -v `
    -keystore "$keystoreDir\release.keystore" `
    -alias hithe-release `
    -keyalg RSA -keysize 2048 `
    -validity 10000 `
    -storetype JKS
```

You'll be prompted for:
- **Keystore password** (use a password manager; write it down too)
- **Key password** (can be the same as the keystore password)
- Your name / organization / country (use real values)

Verify:

```powershell
keytool -list -keystore "$env:USERPROFILE\.hithe-android-signing\release.keystore"
```

**Back up the keystore file** to:
- A second drive
- A password-protected archive on a cloud drive (Dropbox / Google Drive)
- Print the passwords on paper, store in a safe

Do NOT push the keystore to GitHub. The repo's `.gitignore` already
excludes `*.keystore` and `*.jks`.

---

## Step 2 — Configure signing in build.gradle.kts

Create a signing properties file OUTSIDE the repo:

```powershell
$signingProps = "$env:USERPROFILE\.hithe-android-signing\signing.properties"
@"
storeFile=$env:USERPROFILE\.hithe-android-signing\release.keystore
storePassword=YOUR_KEYSTORE_PASSWORD
keyAlias=hithe-release
keyPassword=YOUR_KEY_PASSWORD
"@ | Set-Content -Encoding UTF8 $signingProps
```

(Use forward slashes in `storeFile` if Gradle complains.)

Now edit `android-relay/app/build.gradle.kts` to read from this file.
Add **above** the `android { ... }` block:

```kotlin
val signingPropsFile = file(System.getProperty("user.home") + "/.hithe-android-signing/signing.properties")
val signingProps = java.util.Properties().apply {
    if (signingPropsFile.exists()) {
        signingPropsFile.inputStream().use { load(it) }
    }
}
```

Inside `android { ... }`, add a `signingConfigs` block (before
`buildTypes { ... }`):

```kotlin
signingConfigs {
    create("release") {
        if (signingPropsFile.exists()) {
            storeFile = file(signingProps.getProperty("storeFile"))
            storePassword = signingProps.getProperty("storePassword")
            keyAlias = signingProps.getProperty("keyAlias")
            keyPassword = signingProps.getProperty("keyPassword")
        }
    }
}
```

Then attach the signing config to the release build type:

```kotlin
buildTypes {
    debug { /* unchanged */ }
    release {
        signingConfig = signingConfigs.getByName("release")
        isMinifyEnabled = true
        proguardFiles(
            getDefaultProguardFile("proguard-android-optimize.txt"),
            "proguard-rules.pro"
        )
        buildConfigField("boolean", "DEBUG_VERBOSE", "false")
    }
}
```

If `signingPropsFile.exists()` returns false, the release config will
have null values and the build will fail with a useful error. That's
intentional — it's better than silently producing an unsigned APK.

---

## Step 3 — Build the AAB

From the `android-relay/` directory:

```powershell
cd android-relay
./gradlew :app:bundleRelease
```

On success, the AAB lives at:

```
android-relay/app/build/outputs/bundle/release/app-release.aab
```

Check it's signed:

```powershell
jarsigner -verify -verbose -certs `
  android-relay/app/build/outputs/bundle/release/app-release.aab
```

You should see "jar verified" near the bottom.

For a quick local sideload test (debug APK, NOT for Play Store):

```powershell
./gradlew :app:installDebug    # installs on the USB-connected device
```

---

## Step 4 — Create the Play Console app entry

One-time. Open <https://play.google.com/console>.

1. **Create app** → use these values:
   - App name: `解語 (Vision Companion)`
   - Default language: Traditional Chinese (Taiwan) — or English, your call
   - App or game: **App**
   - Free or paid: **Free**
   - Declarations: confirm content + Play policies
2. Skip the public listing setup for now. You're going private.
3. Side menu → **Testing → Internal testing**.
4. **Create new release**.

---

## Step 5 — Upload the AAB

In the new release:

1. **Upload** → drag in `app-release.aab`. Wait for processing.
2. Play Console will flag any policy issues. Address them. Common ones
   for this app:
   - **Data safety form**: declare that the app collects microphone
     audio, camera images, and approximate device identifiers (only on
     the user's own Tailscale network). State that data is NOT
     transmitted off-device beyond the user's own home server. This is
     literally true.
   - **Permissions declaration**: explain why `RECORD_AUDIO`,
     `CAMERA`, `BLUETOOTH_CONNECT` are needed (audio relay, image
     relay, future glasses pairing).
3. **Release name**: `0.1.0-internal-001` (use a consistent scheme).
4. **Release notes** (50 chars max for internal track): "Initial
   internal build for end-to-end testing."

---

## Step 6 — Add testers

In **Internal testing**:

1. **Testers** tab → **Create email list** → add your wife's Gmail and
   any others (up to 100).
2. **Save**.
3. Copy the **opt-in URL** that appears. Send it to each tester. They
   visit it, click "Become a tester," then can install the app from
   the Play Store on their phone.

The tester sees an "Internal testing" badge in the listing — that's
normal.

---

## Step 7 — Publish the internal release

1. Back to your release draft → **Review release**.
2. **Start rollout to Internal testing**.
3. Wait ~5 minutes for the build to propagate. Then on the tester's
   phone, open Play Store → search "解語" — it appears with the badge.
4. Install.

---

## Step 8 — Future updates

Each new version:

1. Bump `versionCode` (integer, always increasing) and `versionName`
   (semver string) in `app/build.gradle.kts`:
   ```kotlin
   defaultConfig {
       versionCode = 2          // was 1
       versionName = "0.1.1"    // was 0.1.0
   }
   ```
2. Rebuild: `./gradlew :app:bundleRelease`
3. In Play Console → Internal testing → Create new release → upload
   the new AAB → start rollout.
4. Testers get an in-app Play Store notification within a few hours.

---

## Troubleshooting

### "Keystore was tampered with, or password was incorrect"

Wrong password in `signing.properties`. Double-check the values you
typed into `keytool`.

### "Your release is not compliant with the Google Play 64-bit requirement"

CameraX and the other deps are already 64-bit. If you see this, it
means a transitive dep brought in a 32-bit native library. Check
`./gradlew :app:dependencies | grep -i native`.

### Build is slow

Add to `~/.gradle/gradle.properties`:
```
org.gradle.daemon=true
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.configureondemand=true
```

### Tester reports "App not available in your country"

Internal testing track defaults to the country your Play Console
account is registered in. If your wife's account is in a different
country, change country in Play Console → Setup → Pricing &
distribution.

---

## What gets shipped vs. what stays on-device

Just to be crystal clear:

- **The APK/AAB ships:** Kotlin code, Gradle build artifacts, app
  icons, string resources, the WebSocket protocol bytes. Nothing
  personal.
- **The Hermes host stores:** all biometric data
  (`voice_gallery.json`, `face_gallery.json`), all enrolled names,
  all recognition history (`events.jsonl`). Per the locked privacy
  posture (PROJECT-SPEC.md section 7), none of this ever leaves the
  host.
- **The Android app forwards:** raw audio bytes and JPEG images over
  Tailscale-encrypted WebSocket to the Hermes host, then plays back
  TTS PCM it receives. Nothing is persisted on the phone beyond the
  rotating log files (which are local-only, not uploaded).

There is no third-party SDK collecting analytics in this build.
Verified by inspecting `android-relay/app/build.gradle.kts`
dependencies.
