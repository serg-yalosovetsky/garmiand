package com.garmiand.osmand

import android.content.Context
import com.garmiand.domain.RoutePackage

/**
 * Точка интеграции с OsmAnd (AIDL/intents/GPX import).
 * В v1 оставляем интерфейс и заглушку, чтобы не смешивать слой OsmAnd и Garmin.
 */
interface OsmAndBridge {
    fun loadActiveRoute(context: Context): RoutePackage?
}

class GpxImportBridge : OsmAndBridge {
    override fun loadActiveRoute(context: Context): RoutePackage? {
        // TODO: Подключить реальный импорт GPX или AIDL OsmAnd API.
        return null
    }
}
