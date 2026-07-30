# Garmiand — решения, проблемы и runbook

Практический справочник по garmiand: как собирать/деплоить, как устроена доставка
карты, и **полная цепочка «проблема → решение»**, добытая отладкой на живом
железе (fenix 7X + Android S23). Дизайн-обзор проекта — в [`../README.md`](../README.md).

---

## 1. Что это и как течёт карта

```
OsmAnd/GPX ─► Android-компаньон ─┬─ растр-тайлы (OSM | Bing Hybrid)
                                 ├─ квантизация в палитру (1 байт/пиксель)
                                 ├─ мультизум-bundle z13/z15/z17 (GMND, ~160 КБ)
                                 │
                                 ├─(HTTPS)─► backend garmiand.sergnet.pp.ua ─► часы качают через Garmin Connect
                                 └─(BLE fallback)──────────────────────────► часы (медленно, ненадёжно)

Часы (Connect IQ / Monkey C): приём bundle ─► декод активного зума ─► рендер тайлов + оверлей маршрута
```

Ключевые ограничения устройства:
- **RAM часов ~678 КБ.** Весь blob грузится в память целиком → **лимит bundle ~160 КБ** (на 328 КБ был OOM). Не превышать.
- Часы **не ходят в интернет сами** — только через прокси Garmin Connect Mobile, поэтому карту готовит телефон.
- CIQ: watchdog («Code Executed Too Long»), лимит живых таймеров, App.Storage 16 КБ/чанк.

---

## 2. Runbook сборки и деплоя

### 2.1 Watch-приложение (Monkey C)

```powershell
$sdk = "$env:APPDATA\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-9.1.0-...\bin"
& "$sdk\monkeyc.bat" -f monkey.jungle -d fenix7x -o build\garmiand-fenix7x.prg -y developer_key
```

Деплой на часы (MTP через `Shell.Application` COM → `GARMIN/APPS/GARMIAND.PRG`):
- `scratchpad/copy_to_watch.ps1` — разовая заливка.
- `scratchpad/watch_and_deploy.ps1` — ждёт монтирования часов, даёт **20 с устаканиться**, потом шьёт.

> ⚠️ **Не шить сразу, как часы появились в MTP.** Свежесмонтированные часы ещё
> заняты — заливка `.prg` в этот момент роняет часы. Ждать готовности `GARMIN/APPS`
> + ~20 с (это делает `watch_and_deploy.ps1`).

### 2.2 Android-компаньон — ⚠️ ГЛАВНАЯ ГРАБЛЯ: токены

`BACKEND_TOKEN` и `LOKI_TOKEN` **не хранятся в репозитории**. Они приходят из
**env при сборке** (`app/build.gradle.kts`: `gradleProperty ?: environmentVariable`).
Если env не задан — в `BuildConfig` попадает заглушка `dev-token-change-me` (`len=19`).

**Последствия заглушки:**
1. HTTPS-upload на backend → **401** → откат на **BLE**.
2. BLE-ассемблер на часах **стопорится** (`BLE STALL`, `assembler reset after stall`,
   теряет прогресс) → карта **не собирается**.
3. Loki-push без токена → nginx **401** → в Loki **пусто**.

**Правильная сборка + установка (атомарно, одной цепочкой):**

```bash
cd /g/code/garmiand/android
export GARMIAND_BACKEND_TOKEN="$(ssh root@openwrt 'grep -oP "(?<=BACKEND_TOKEN=).*" /opt/garmiand-backend/.env.docker | tr -d "\r\n"')"
export GARMIAND_LOKI_TOKEN="$(ssh root@openwrt 'grep -rhoP "(?<=x_reader_token != .)[a-f0-9]{16,}" /etc/nginx/conf.d/*.conf | head -1 | tr -d "\r\n"')"
./gradlew assembleDebug && adb -s <device> install -r app/build/outputs/apk/debug/app-debug.apk
```

**Проверка, что токен вшит** (после запуска приложения):
```
adb -s <device> logcat -d -s MainActivity | grep 'token='
# ОК:    App started ... token=ijz…kWp (len=40)
# ПЛОХО: App started ... token=dev…-me (len=19)  ← заглушка, пересобрать
```

> ⚠️ **Не запускать приложение кнопкой Run в Android Studio** и не полагаться на
> готовый `app-debug.apk` на диске: Studio и фоновый gradle-демон пересобирают apk
> **без** env-токенов и затирают рабочую сборку. Собирать и ставить нужно **в одной
> команде**, чтобы между сборкой и установкой ничего не влезло.

> Токены **нельзя** класть в `~/.gradle/gradle.properties` или env-файлы (персист
> секрета). Только эфемерный `export` на время сборки.

---

## 3. Цепочка «проблема → решение»

### 3.1 Краши часов при старте / доставке

| Проблема | Симптом (лог) | Решение |
|---|---|---|
| `configureTouchEvents` в `onStart` | краш на старте | вызывать только из `onShow()` (foreground), в `try/catch` |
| Too Many Timers на даблклике START | краш | один переиспользуемый `_btnTimer` в `NavigationDelegate.initialize()`, не `new` на каждое нажатие |
| Watchdog в `BleChunkAssembler.accept` | «Code Executed Too Long» | `persistWipMeta()` один раз вместо 6 записей/чанк |
| Watchdog в `loadWip` (побайтовый цикл) | краш на старте | нативный `ByteArray.addAll` + zero-pad недостающих чанков |
| **OOM при загрузке bundle** | `Out Of Memory` в `TileDecoder.load` | гард `if (nc > 12) return null` + урезать bundle ≤160 КБ (весь blob грузится в RAM, `addAll` пикует ~1.5×) |

### 3.2 Карта не появлялась / рвался синк

| Проблема | Симптом | Решение |
|---|---|---|
| «offline mode → skip GET» | нет blob → нет карты | убрать offline-skip: предложенный `tile_session` всегда качать |
| Watch-логи рвали синк | `sync_finish FAILURE_DURING_TRANSFER` | не слать лог каждую секунду; писать в буфер, слать **по запросу** (`get_logs`), гейт на `_lastRxMs` (полу-дуплекс BLE) |
| Пустая карта после оптимизации панорамы | чёрный экран поверх карты | композит-слой создавать **без `:palette`** — палитровый render-target на fenix рисует пусто |

### 3.3 Bing Hybrid («карта с названиями»)

| Проблема | Симптом | Решение |
|---|---|---|
| OSM-подписи нечитаемы | мелко/каша после downscale+квантизации | источник **Bing Hybrid** (спутник + дороги + подписи, `it=A,G,L`) из SAS.Planet `Bing_Sat_BE_H.zmp` |
| Bing использует quadkey, не z/x/y | — | `buildTileUrl`: `{q}`→Bing quadkey, `{s}`→сервер 1..3; классический `%d/%d/%d` тоже поддержан |
| **Все Bing-тайлы падают по HTTPS** | `Hostname ak.dynamic.t1.tiles.virtualearth.net not verified` (cert `CN=a248.e.akamai.net`, нет `virtualearth.net` в SAN) → `0 tiles` → send FAILED → старая карта | ходить на Bing по **http** (как SAS.Planet); cleartext **точечно** для `virtualearth.net` в `res/xml/network_security_config.xml`. TLS-верификацию нигде не отключать |

### 3.4 Токены сборки (см. §2.2)

| Проблема | Симптом | Решение |
|---|---|---|
| Заглушка вместо токена | `token=dev…-me (len=19)`; HTTPS 401→BLE-стопор; Loki пусто | собирать с env-токенами из узла |
| Studio затирает apk без токенов | ночью токен «обнулился» сам | атомарная сборка+установка; не жать Run в Studio |
| `~/.gradle/gradle.properties` для токенов | классификатор блокирует (персист секрета) | только эфемерный env |

### 3.5 Сеть / инфраструктура

| Проблема | Симптом | Решение |
|---|---|---|
| ssh к узлу висит | таймаут `ssh root@100.126.187.74` (голый IPv4 :22) | ходить по **`ssh root@openwrt`** (Tailscale MagicDNS) |
| memory/Loki отваливались | `rx 0` на узле VPS | WARP ⇄ Tailscale конфликт — в Split Tunnel исключить публичный IP VPS |
| Backend не перечитывает `--env-file` | старый токен | `docker rm` + `docker run`, не `restart`; `PUBLIC_URL` для правильного downloadUrl |

---

## 4. Наблюдаемость (Loki)

Логи телефона **и** часов (форвардятся телефоном) уходят в Grafana Loki
`loki.sergnet.pp.ua`. Читать напрямую с узла (SSO обходится только для push):

```bash
# последние строки garmiand
ssh root@openwrt 'curl -s -G "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode "query={app=\"garmiand\"}" --data-urlencode "since=15m" --data-urlencode "limit=50"'

# только watch-логи
ssh root@openwrt 'curl -s -G ... --data-urlencode "query={app=\"garmiand\"} |= \"Watch:\""'
```

Дамп буфера логов **с часов** по запросу (часы копят и стримят по требованию):
```bash
adb -s <device> shell am broadcast -a com.garmiand.GET_WATCH_LOGS -p com.garmiand
```
Телефон запрашивает лог у часов → `watch_log`-сообщения → `AppLog.i("Watch", …)` → Loki
(и в logcat под тегом `Watch`).

Здоровая цепочка отправки в логах:
`Bundle ready … mode=HTTPS` → `MapBundleUploader: uploaded …B → <id>` →
`tile_session bundleId=… ack ok=true` → `ack tile_session status=SUCCESS` →
(на часах) `load: blob …B` → `hdr: tiles=…` → `z15 …t ok`.

---

## 5. Быстрые факты

- **Устройства adb:** S23 = `adb-R5CX8148GRX-69o9Ll._adb-tls-connect._tcp` (192.168.1.193),
  подключён к часам. Часто засыпает → `adb mdns services` для переобнаружения (mDNS
  иногда режется — тогда `adb connect <ip:port>` с экрана «Отладка по Wi-Fi»).
- **Часы:** fenix 7X Sapphire Solar, part `006-B3907-00`, device id `fenix7x`, CIQ SDK 9.1.0.
- **Backend:** `https://garmiand.sergnet.pp.ua` (Docker на узле openwrt за nginx+ACME,
  публично через Cloudflare; токен/UUID-авторизация, без SSO). `POST /sessions` без
  токена → 401 (проверка живости).
- **Узел:** `ssh root@openwrt` (не голый IPv4). Backend-конфиг: `/opt/garmiand-backend/.env.docker`.
- **Источники карт:** переключатель в UI телефона (`MapSourcePrefs`, дефолт Bing),
  применяется и к ручной отправке, и к авто-докачке (`MapRequestResponder`).
  SAS.Planet карты: `codeberg.org/sasgis/maps.git`.

---

## 6. Открытые задачи

- Навсегда убрать затирание токенов из Android Studio (env в Run-config либо сборочный
  скрипт-обёртка). Сейчас — только атомарная CLI-сборка.
- Оценить читаемость подписей Bing на z17 (128px); при необходимости поднять
  `outputSize`/сменить палитру под спутник.
- **Security:** backend-токен утёк в git-историю — запланирована ротация (не сделана,
  чтобы не рассинхронить backend). При ротации: BWS + `/opt/garmiand-backend/.env.docker`
  + пересборка APK.
- Путь A (векторный `mkgmap` `.img` backend) — отложен.
