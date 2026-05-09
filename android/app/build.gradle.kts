import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val backendUrl: String = providers.gradleProperty("garmiand.backendUrl").orNull
    ?: providers.environmentVariable("GARMIAND_BACKEND_URL").orNull
    ?: ""

val backendToken: String = providers.gradleProperty("garmiand.backendToken").orNull
    ?: providers.environmentVariable("GARMIAND_BACKEND_TOKEN").orNull
    ?: "dev-token-change-me"

android {
    namespace = "com.garmiand"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.garmiand"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"

        buildConfigField("String", "BACKEND_URL", "\"$backendUrl\"")
        buildConfigField("String", "BACKEND_TOKEN", "\"$backendToken\"")
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
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
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.garmin.connectiq:ciq-companion-app-sdk:2.4.0@aar")
}
