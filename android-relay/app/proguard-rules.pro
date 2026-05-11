# ProGuard / R8 rules for the release build.

# Keep our own classes accessible by name for debugging stack traces.
-keep class com.kangatnewyork.visioncompanion.relay.** { *; }

# OkHttp's optional dependencies that the analyzer can't see at build time.
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
