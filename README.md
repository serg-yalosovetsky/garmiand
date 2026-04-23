# OsmAnd → Garmin (Connect IQ) MVP

## Цель проекта (v1)

Передавать с телефона на Garmin-часы:
- маршрут (трек),
- ключевые пометки (start/finish/waypoints),
- базовую навигацию с контролем отклонения от маршрута.

> В v1 **не** пытаемся сделать «полноценный OsmAnd на часах» или пиксельно-идентичную карту.

## Ключевая идея архитектуры

Один Android APK:
1. **OsmAnd Bridge** (импорт GPX / интеграция через API/AIDL),
2. **Processor** (нормализация маршрута, чанки, пакет синхронизации),
3. **Garmin Companion** (передача данных в Connect IQ app и обработка ACK/Retry),
4. **Phone UI** (выбор маршрута, отправка, статус синка).

Плюс отдельный **Garmin Watch App**:
- приём и локальное хранение пакета,
- отрисовка маршрута/пометок,
- off-route логика,
- fallback-режим без тайлов.

## Режимы карты

1. **Надёжный режим (для v1):**
   - маршрут + пометки поверх стандартной карты часов.
2. **Тяжёлый режим (v2+):**
   - ограниченный набор тайлов/снимков только вокруг маршрута (corridor-only),
   - строгие лимиты по размеру и памяти,
   - graceful fallback при нехватке памяти.

## Протокол синхронизации (через чанки)

Типы сообщений:
- `sync_start`
- `route_meta`
- `route_chunk`
- `marker_chunk`
- `tile_chunk`
- `sync_finish`
- `ack`
- `error`

Минимальный формат:

```json
{
  "sessionId": "uuid",
  "kind": "route_chunk",
  "routeId": "route-123",
  "chunkIndex": 0,
  "chunkCount": 12,
  "payload": {}
}
```

Принципы:
- маленькие чанки,
- подтверждение каждого чанка,
- retry по таймауту,
- возможность resume оборванной передачи.

## Структура репозитория

```text
android/
  app/
    osmand/
    garmin/
    domain/
    data/
    ui/
garmin/
  source/
  resources/
docs/
  architecture.md
  protocol.md
  milestones.md
```

## Пошаговый roadmap

### Sprint 1 — transport baseline
- поднять watch app и android app,
- сделать `ping/pong` по каналу phone ↔ watch,
- показать статус соединения.

### Sprint 2 — минимальная навигация
- отправка одного marker,
- отправка короткого route (10 точек),
- отрисовка polyline/marker на часах.

### Sprint 3 — GPX import
- импорт GPX в Android,
- преобразование в `RoutePackage`,
- отправка чанками.

### Sprint 4 — on-watch guidance
- расчёт ближайшего сегмента,
- off-route detection,
- vibration alert.

### Sprint 5 — markers & lifecycle
- дополнительные пометки,
- выбор активного пакета,
- удаление старых пакетов.

### Sprint 6 — map-like mode (опционально)
- corridor bbox,
- ограниченные тайлы,
- fallback в breadcrumb-only при проблемах.

## Definition of Done для MVP

MVP считается готовым, если:
1. Пользователь может взять маршрут из OsmAnd (или импортировать GPX).
2. Маршрут и пометки успешно уходят на часы с подтверждением доставки.
3. Часы показывают трек, текущую позицию и next waypoint.
4. При заметном отклонении срабатывает предупреждение.
5. При сбое карты приложение продолжает работать в режиме breadcrumb/polyline.

## Анти-цели v1

- полный форк OsmAnd,
- routing engine на часах,
- «1:1 интерфейс OsmAnd на Garmin»,
- большие офлайн-карты без жёстких лимитов.


## Реализация v1 в этом репозитории

Добавлен рабочий прототип `app_v1`:
- импорт GPX (`app_v1/gpx_import.py`),
- сборка и chunk-синхронизация (`app_v1/protocol.py`),
- phone companion-логика (`app_v1/phone.py`),
- watch-side прием, сохранение и off-route проверка (`app_v1/watch.py`),
- CLI-демо (`main.py`).

### Быстрый запуск

```bash
python main.py tests/data/sample.gpx --lat 50.4501 --lon 30.5234
```

### Тесты

```bash
pytest -q
```

## Боевой каркас Android + Connect IQ

По запросу добавлен отдельный каркас **реального проекта**:
- Android/Kotlin модуль в `android/`;
- Connect IQ (Monkey C) watch-app в `garmin/`;
- описание состава и следующих шагов в `docs/boilerplate.md`.

Это уже не просто Python-прототип, а база под реальную реализацию mobile + watch.

## Единый формат phone-message envelope

Добавлен единый формат payload для Android Companion и Monkey C receiver:
- спецификация: `docs/phone_message_envelope.md`;
- Android константы: `android/.../protocol/PhoneMessageEnvelope.kt`;
- watch receiver: `garmin/source/GarmiandApp.mc`.

## CI/CD (GitHub Actions)

Добавлен workflow `.github/workflows/build-release.yml`, который:
1. запускает Python тесты;
2. собирает release APK через Gradle;
3. собирает Garmin PRG через Connect IQ SDK (`monkeybrains.jar`).
