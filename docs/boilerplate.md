# Боевой каркас v1: Android + Connect IQ

## Что добавлено

### Android (Kotlin)
- `android/` Gradle-проект с модулем `app`.
- Доменные модели маршрута: `domain/RouteModels.kt`.
- Протокол обмена и chunk encoder: `protocol/SyncProtocol.kt`, `protocol/JsonRouteChunkEncoder.kt`.
- Слой интеграции OsmAnd (интерфейс + заглушка): `osmand/OsmAndBridge.kt`.
- Слой Garmin Companion (интерфейс + заглушка): `garmin/GarminCompanion.kt`.
- Оркестратор синхронизации: `sync/RouteSyncOrchestrator.kt`.
- `MainActivity` c демонстрацией сквозного sync-пайплайна.

### Garmin Watch App (Monkey C)
- `garmin/manifest.xml` (fenix7, Communications + Positioning permissions).
- `source/GarmiandApp.mc`: прием phone messages и хранение sync state.
- `source/NavigationView.mc`: экран статуса синхронизации.
- `source/NavigationDelegate.mc`: delegate-заготовка.
- `resources/strings.xml`.

## Что дальше (чтобы довести до прод-готовности)
1. Подключить реальный Connect IQ Mobile SDK transport в Android `GarminCompanion`.
2. Реализовать импорт из OsmAnd (AIDL/intents/GPX) в `OsmAndBridge`.
3. Добавить ACK/Retry + resume в sync orchestrator.
4. На часах заменить статусный экран на MapTrackView + polyline/markers.
5. Добавить персистентное хранение route package на часах (Storage API) с лимитами чанков.
