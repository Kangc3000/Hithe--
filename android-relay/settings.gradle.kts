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

        // Meta Wearables Device Access Toolkit lives in a private GitHub
        // Packages repo. Credentials come from ~/.gradle/gradle.properties
        // (see INSTALLATION-ANDROID.md Step 6). Until access is granted,
        // this block is dormant; the project builds without it because
        // the Meta SDK adapter is currently a stub.
        maven {
            url = uri("https://maven.pkg.github.com/meta-wearables/sdk-android")
            credentials {
                username = providers.gradleProperty("gpr.user").orNull ?: "anonymous"
                password = providers.gradleProperty("gpr.key").orNull ?: ""
            }
        }
    }
}

rootProject.name = "VisionCompanionRelay"
include(":app")
