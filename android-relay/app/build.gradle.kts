plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.kangatnewyork.visioncompanion.relay"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.kangatnewyork.visioncompanion.relay"
        minSdk = 29           // Android 10 — locked by D-001 / spec section 2
        targetSdk = 35        // Android 15
        versionCode = 1
        versionName = "0.1.0"

        // Most of these are belt-and-suspenders defaults. The interesting
        // build configs (Hermes host, port) are runtime settings, NOT
        // baked into the APK.
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            // Keep debug logs at VERBOSE so the field-debugging flow has
            // everything available without a rebuild. The Logger class
            // honours a runtime level set in Settings.
            buildConfigField("boolean", "DEBUG_VERBOSE", "true")
        }
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            buildConfigField("boolean", "DEBUG_VERBOSE", "false")
        }
    }

    buildFeatures {
        buildConfig = true
        viewBinding = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // AndroidX core
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-ktx:1.9.0")
    implementation("androidx.lifecycle:lifecycle-service:2.8.2")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.2")

    // UI (basic Material widgets for the settings screen — no Compose to
    // keep the binary lean).
    implementation("com.google.android.material:material:1.12.0")

    // CameraX for image capture. Modern API; deals with quirks for us.
    implementation("androidx.camera:camera-core:1.3.4")
    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    implementation("androidx.camera:camera-view:1.3.4")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0")

    // WebSocket: OkHttp's WebSocket support is reliable, async, and works
    // well with Tailscale-routed connections.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // JSON. Built-in org.json is fine for our tiny event schema; no need
    // for kotlinx.serialization or Moshi here.

    // Meta Wearables Device Access Toolkit (commented out until SDK access
    // is granted; uncomment when ready). Until then MetaSdkTransport.kt
    // contains a documented stub. Coordinates verified 2026-06 from
    // github.com/facebook/meta-wearables-dat-android (current version 0.8.0).
    // mwdat-mockdevice lets you develop against a simulated device with no
    // physical glasses.
    // implementation("com.meta.wearable:mwdat-core:0.8.0")
    // implementation("com.meta.wearable:mwdat-camera:0.8.0")
    // implementation("com.meta.wearable:mwdat-mockdevice:0.8.0")
}
