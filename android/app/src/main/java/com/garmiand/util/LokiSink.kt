package com.garmiand.util

import android.os.Build
import com.garmiand.BuildConfig
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Ships [AppLog] lines to Grafana Loki so logs are visible in the user's own
 * dashboard without a cable.
 *
 * Auth follows the reader-android pattern: a build-time token
 * ([BuildConfig.LOKI_TOKEN]) replayed as [BuildConfig.LOKI_TOKEN_HEADER]
 * (default `X-Reader-Token`), which nginx in front of Loki accepts instead of
 * the browser SSO cookie. Redirects are NOT followed, so a 302 to the SSO host
 * (missing/rotated token) is reported to Logcat instead of silently "working".
 *
 * Fire-and-forget: one daemon thread batches lines and POSTs at most once per
 * [FLUSH_MS]. Disabled (no-op) when [BuildConfig.LOKI_URL] is blank. Never feeds
 * back into [AppLog] — its own diagnostics go straight to Logcat to avoid a loop.
 */
object LokiSink {
    private const val FLUSH_MS = 3000L
    private const val MAX_BATCH = 200
    private const val MAX_QUEUE = 2000
    private const val TAG = "LokiSink"

    private data class Entry(val tsNanos: Long, val level: String, val line: String)

    private val enabled = BuildConfig.LOKI_URL.isNotBlank()
    private val queue = LinkedBlockingQueue<Entry>(MAX_QUEUE)
    private val device = "${Build.MANUFACTURER}-${Build.MODEL}".replace(" ", "_")

    @Volatile
    private var started = false

    /** Queue one log line. Non-blocking; drops the oldest entry when full. */
    fun enqueue(level: String, msTime: Long, line: String) {
        if (!enabled) return
        ensureStarted()
        val e = Entry(msTime * 1_000_000L, level, line)
        if (!queue.offer(e)) {
            queue.poll()
            queue.offer(e)
        }
    }

    @Synchronized
    private fun ensureStarted() {
        if (started) return
        started = true
        Thread({ loop() }, "loki-sink").apply { isDaemon = true }.start()
    }

    private fun loop() {
        val batch = ArrayList<Entry>(MAX_BATCH)
        while (true) {
            try {
                val first = queue.poll(FLUSH_MS, TimeUnit.MILLISECONDS) ?: continue
                batch.clear()
                batch.add(first)
                queue.drainTo(batch, MAX_BATCH - 1)
                push(batch)
            } catch (e: InterruptedException) {
                return
            } catch (e: Exception) {
                android.util.Log.w(TAG, "loki flush error: ${e.message}")
            }
        }
    }

    private fun push(entries: List<Entry>) {
        // One stream per level keeps Loki label cardinality tiny.
        val streams = JSONArray()
        for ((level, list) in entries.sortedBy { it.tsNanos }.groupBy { it.level }) {
            val values = JSONArray()
            for (e in list) {
                values.put(JSONArray().put(e.tsNanos.toString()).put(e.line))
            }
            val labels = JSONObject()
                .put("app", "garmiand")
                .put("device", device)
                .put("level", level)
            streams.put(JSONObject().put("stream", labels).put("values", values))
        }
        val body = JSONObject().put("streams", streams).toString().toByteArray()

        val url = URL(BuildConfig.LOKI_URL.trimEnd('/') + "/loki/api/v1/push")
        val conn = (url.openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = false
            connectTimeout = 10_000
            readTimeout = 10_000
            requestMethod = "POST"
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
            if (BuildConfig.LOKI_TOKEN.isNotBlank()) {
                setRequestProperty(BuildConfig.LOKI_TOKEN_HEADER, BuildConfig.LOKI_TOKEN)
            }
            setFixedLengthStreamingMode(body.size)
        }
        try {
            conn.outputStream.use { it.write(body) }
            val code = conn.responseCode
            if (code in 200..299) return
            if (code == 302 || code == 401 || code == 403) {
                android.util.Log.w(TAG, "loki auth rejected HTTP $code (header ${BuildConfig.LOKI_TOKEN_HEADER}); check nginx token bypass")
            } else {
                val err = conn.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty().take(200)
                android.util.Log.w(TAG, "loki push HTTP $code $err")
            }
        } finally {
            conn.disconnect()
        }
    }
}
