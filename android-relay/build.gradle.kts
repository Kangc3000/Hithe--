// Top-level build file. Plugins are declared here without applying them so
// subprojects can pick what they need. Versions in one place.

plugins {
    // AGP 8.6.0 (min Gradle 8.7) — required by androidx.core 1.16.0, which the
    // Meta Wearables SDK pulls in transitively. Also supports compileSdk 35.
    id("com.android.application") version "8.6.0" apply false
    // Kotlin 2.2.0 — the Meta SDK's .kotlin_module metadata is binary version
    // 2.2.0, which a 1.9.x compiler refuses to read. Bumped to match.
    id("org.jetbrains.kotlin.android") version "2.2.0" apply false
}
