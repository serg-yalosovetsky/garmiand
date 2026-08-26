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

// Remote logging to Grafana Loki. Auth follows the reader-android pattern:
// a build-time token replayed as a header that nginx accepts instead of the
// browser SSO cookie (see LokiSink). Empty lokiUrl disables remote logging.
val lokiUrl: String = providers.gradleProperty("garmiand.lokiUrl").orNull
    ?: providers.environmentVariable("GARMIAND_LOKI_URL").orNull
    ?: ""

val lokiToken: String = providers.gradleProperty("garmiand.lokiToken").orNull
    ?: providers.environmentVariable("GARMIAND_LOKI_TOKEN").orNull
    ?: ""

val lokiTokenHeader: String = providers.gradleProperty("garmiand.lokiTokenHeader").orNull
    ?: providers.environmentVariable("GARMIAND_LOKI_TOKEN_HEADER").orNull
    ?: "X-Reader-Token"

// Тайл-сервер меша: отдаёт то, что роутер уже скачал в свой склад. Средний
// уровень между кешем на телефоне и интернетом — быстрее и без трафика.
// По умолчанию через домен (nginx на VPS проксирует на роутер), а не по
// tailnet-IP: так работает из любой сети, без поднятого Tailscale на телефоне.
// Пусто — уровень выключен, всё идёт из сети как раньше.
val routerTileUrl: String = providers.gradleProperty("garmiand.routerTileUrl").orNull
    ?: providers.environmentVariable("GARMIAND_ROUTER_TILE_URL").orNull
    ?: "https://tiles.ibotz.fun"

// Машинный доступ к /tile/ — этим токеном nginx отличает приложение от человека
// (человек ходит на тот же домен через SSO). Источник истины — секрет
// GARMIAND_TILES_TOKEN в secrets-gateway. Пусто — сервер ответит 401, и уровень
// роутера просто отключится после трёх отказов.
val tilesToken: String = providers.gradleProperty("garmiand.tilesToken").orNull
    ?: providers.environmentVariable("GARMIAND_TILES_TOKEN").orNull
    ?: ""

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
        buildConfigField("String", "LOKI_URL", "\"$lokiUrl\"")
        buildConfigField("String", "LOKI_TOKEN", "\"$lokiToken\"")
        buildConfigField("String", "LOKI_TOKEN_HEADER", "\"$lokiTokenHeader\"")
        buildConfigField("String", "ROUTER_TILE_URL", "\"$routerTileUrl\"")
        buildConfigField("String", "TILES_TOKEN", "\"$tilesToken\"")
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
