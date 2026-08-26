package com.garmiand.map

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import com.garmiand.util.AppLog
import java.io.File

/**
 * Заранее скачанные тайлы, лежащие на телефоне файлом.
 *
 * Зачем: сеть — самое ненадёжное звено там, где карта и нужна. В горах её нет
 * вовсе, а на краю покрытия [TileQuantizer.fetchTile] висит на таймаутах и
 * отдаёт дыры. Тайл, уже лежащий на диске, читается за миллисекунды и не
 * зависит ни от чего.
 *
 * Склад — каталог `files/tilestore` в приватной памяти приложения: он доступен
 * без разрешений (scoped storage на targetSdk 35 закрывает чужие каталоги
 * наглухо). Базы кладутся туда `adb push` или импортом через файловый пикер.
 *
 * Понимает три раскладки, в которых одна и та же вещь хранится по-разному:
 *
 *   MBTiles          tiles(zoom_level, tile_column, tile_row, tile_data)
 *                    строка в TMS, снизу вверх: row = 2^z - 1 - y
 *   RMaps simple     tiles(x, y, z, s, image) — зум и y прямые (XYZ)
 *   RMaps BigPlanet  та же схема, но зум ИНВЕРТИРОВАН: z_хранимый = 17 - z.
 *                    Так пишет SAS.Planet; приняв его зум за прямой, получишь
 *                    базу, которая на всех запрашиваемых зумах выглядит пустой.
 *
 * Раскладка определяется по схеме и `info.tilenumbering`, а не по расширению
 * файла: `.sqlitedb` носят обе разновидности RMaps.
 */
class LocalTileStore private constructor(
    val name: String,
    private val db: SQLiteDatabase,
    private val kind: Kind,
) {
    enum class Kind { MBTILES, RMAPS, RMAPS_BIGPLANET }

    /** Тайл в координатах XYZ (y сверху вниз) — так же, как их отдают тайл-серверы. */
    fun get(zoom: Int, x: Int, y: Int): ByteArray? {
        return try {
            when (kind) {
                Kind.MBTILES -> query(
                    "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?",
                    zoom, x, (1 shl zoom) - 1 - y,
                )
                Kind.RMAPS -> query(
                    "SELECT image FROM tiles WHERE z=? AND x=? AND y=?", zoom, x, y,
                )
                Kind.RMAPS_BIGPLANET -> query(
                    "SELECT image FROM tiles WHERE z=? AND x=? AND y=?",
                    BIGPLANET_BASE - zoom, x, y,
                )
            }
        } catch (e: SQLiteException) {
            AppLog.w(TAG, "$name: чтение $zoom/$x/$y не удалось: ${e.message}")
            null
        }
    }

    private fun query(sql: String, vararg args: Int): ByteArray? {
        db.rawQuery(sql, args.map { it.toString() }.toTypedArray()).use { c ->
            if (!c.moveToFirst()) return null
            val blob = c.getBlob(0)
            return if (blob == null || blob.isEmpty()) null else blob
        }
    }

    /** Реальные (не хранимые) зумы, которые есть в базе. */
    fun zooms(): List<Int> = try {
        val col = if (kind == Kind.MBTILES) "zoom_level" else "z"
        db.rawQuery("SELECT DISTINCT $col FROM tiles", null).use { c ->
            val out = mutableListOf<Int>()
            while (c.moveToNext()) {
                val z = c.getInt(0)
                out.add(if (kind == Kind.RMAPS_BIGPLANET) BIGPLANET_BASE - z else z)
            }
            out.sorted()
        }
    } catch (e: SQLiteException) {
        AppLog.w(TAG, "$name: список зумов не прочитался: ${e.message}")
        emptyList()
    }

    fun describe(): String = "$name [${kind.name.lowercase()}] зумы ${zooms()}"

    fun close() = runCatching { db.close() }.let { }

    companion object {
        private const val TAG = "LocalTileStore"
        private const val BIGPLANET_BASE = 17

        /** Открыть базу и определить раскладку. null — файл не база тайлов. */
        fun open(file: File): LocalTileStore? {
            val db = try {
                SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY)
            } catch (e: SQLiteException) {
                AppLog.w(TAG, "${file.name}: не открылась: ${e.message}")
                return null
            }
            val kind = detectKind(db, file.name)
            if (kind == null) {
                db.close()
                return null
            }
            return LocalTileStore(file.name, db, kind)
        }

        private fun detectKind(db: SQLiteDatabase, name: String): Kind? {
            val cols = mutableSetOf<String>()
            try {
                db.rawQuery("PRAGMA table_info(tiles)", null).use { c ->
                    val idx = c.getColumnIndex("name")
                    while (c.moveToNext()) cols.add(c.getString(idx))
                }
            } catch (e: SQLiteException) {
                AppLog.w(TAG, "$name: нет таблицы tiles: ${e.message}")
                return null
            }
            if (cols.isEmpty()) return null

            if (cols.containsAll(listOf("zoom_level", "tile_column", "tile_row"))) return Kind.MBTILES
            if (!cols.containsAll(listOf("x", "y", "z"))) {
                AppLog.w(TAG, "$name: незнакомая схема tiles: $cols")
                return null
            }
            // RMaps: BigPlanet или прямая нумерация — решает info.tilenumbering.
            val numbering = try {
                db.rawQuery("SELECT tilenumbering FROM info LIMIT 1", null).use { c ->
                    if (c.moveToFirst()) c.getString(0)?.trim()?.lowercase() ?: "" else ""
                }
            } catch (e: SQLiteException) {
                ""  // нет info или колонки — считаем нумерацию прямой
            }
            return if (numbering.startsWith("bigplanet")) Kind.RMAPS_BIGPLANET else Kind.RMAPS
        }
    }
}

/**
 * Все базы склада разом: спрашиваются по очереди, побеждает первая, где тайл есть.
 *
 * Порядок — по имени файла, так что приоритет задаётся именованием (`00-`, `10-`).
 * Это нужно, когда поверх общего покрытия лежит детальная карта на малый район:
 * держать их отдельными файлами, а не сливать в один, — единственный способ не
 * получить шов между разными источниками снимков.
 */
class TileStoreRegistry private constructor(private val stores: List<LocalTileStore>) {

    fun get(zoom: Int, x: Int, y: Int): ByteArray? {
        for (store in stores) {
            store.get(zoom, x, y)?.let { return it }
        }
        return null
    }

    val isEmpty: Boolean get() = stores.isEmpty()
    val size: Int get() = stores.size

    fun describe(): String =
        if (stores.isEmpty()) "склад пуст"
        else stores.joinToString("; ") { it.describe() }

    fun close() = stores.forEach { it.close() }

    companion object {
        private const val TAG = "TileStoreRegistry"
        const val DIR_NAME = "tilestore"

        /** Каталог склада. Создаётся при первом обращении. */
        fun storeDir(context: Context): File =
            File(context.getExternalFilesDir(null) ?: context.filesDir, DIR_NAME)
                .apply { mkdirs() }

        /**
         * Открыть все базы из каталога склада. Пустой реестр — не ошибка:
         * значит склада нет и всё пойдёт из сети, как раньше.
         */
        fun open(context: Context): TileStoreRegistry {
            val dir = storeDir(context)
            val files = dir.listFiles()
                ?.filter { it.isFile && it.length() > 0 }
                ?.filter { f ->
                    val n = f.name.lowercase()
                    n.endsWith(".sqlitedb") || n.endsWith(".mbtiles") || n.endsWith(".db")
                }
                ?.sortedBy { it.name }
                ?: emptyList()

            val opened = files.mapNotNull { LocalTileStore.open(it) }
            if (opened.isNotEmpty()) {
                AppLog.i(TAG, "склад: ${opened.size} баз — ${opened.joinToString { it.describe() }}")
            }
            return TileStoreRegistry(opened)
        }
    }
}
