pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()

        // Meta Wearables Device Access Toolkit (MWDAT) is published to Meta's
        // GitHub Packages repo. Credentials come from ~/.gradle/gradle.properties
        // (gpr.user = GitHub username, gpr.key = a PAT with read:packages).
        // Until access is granted this block is dormant; the project builds
        // without it because the Meta SDK adapter is currently a stub.
        // Verified 2026-06: repo facebook/meta-wearables-dat-android, artifacts
        // under com.meta.wearable (mwdat-core/-camera/-display/-mockdevice),
        // current version 0.8.0.
        maven {
            url = uri("https://maven.pkg.github.com/facebook/meta-wearables-dat-android")
            credentials {
                username = providers.gradleProperty("gpr.user").orNull ?: "anonymous"
                password = providers.gradleProperty("gpr.key").orNull ?: ""
            }
        }
    }
}

rootProject.name = "VisionCompanionRelay"
include(":app")
