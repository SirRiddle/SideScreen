plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val appVersion = rootProject.file("../VERSION").readText().trim()
val versionParts = appVersion.split(".")
val computedVersionCode = versionParts[0].toInt() * 10000 + versionParts[1].toInt() * 100 + versionParts[2].toInt()

android {
    namespace = "com.sidescreen.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.sidescreen.app"
        minSdk = 26
        targetSdk = 36
        versionCode = computedVersionCode
        versionName = appVersion
    }

    // Release signing (fork key, scripts/setup_android_release_key.sh): read from env vars,
    // set from GitHub secrets in CI or exported locally. Without them release builds fall back
    // to the debug key so `./gradlew assembleRelease` works on a fresh checkout — but such an
    // APK cannot update an installed release (different signature).
    val releaseKeystore = System.getenv("SIDESCREEN_KEYSTORE_PATH")?.let { File(it) }?.takeIf { it.exists() }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = System.getenv("SIDESCREEN_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("SIDESCREEN_KEY_ALIAS") ?: "sidescreen"
                keyPassword = System.getenv("SIDESCREEN_KEY_PASSWORD") ?: System.getenv("SIDESCREEN_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // R8: shrink + obfuscate (upstream #86). Debug builds never run it, so
            // verify a release APK on a device after dependency changes.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig =
                if (releaseKeystore != null) {
                    signingConfigs.getByName("release")
                } else {
                    logger.warn("SIDESCREEN_KEYSTORE_PATH not set: release APK signed with the debug key.")
                    signingConfigs.getByName("debug")
                }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = "11"
    }

    buildFeatures {
        viewBinding = true
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")

    // Wireless mode (0.8.0)
    implementation("androidx.camera:camera-core:1.4.2")
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.camera:camera-view:1.4.2")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")

    testImplementation("junit:junit:4.13.2")
}
