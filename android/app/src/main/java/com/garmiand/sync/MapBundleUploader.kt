package com.garmiand.sync

import com.garmiand.util.AppLog
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

private const val TAG = "MapBundleUploader"
private const val UPLOAD_TIMEOUT_MS = 30_000

data class UploadResult(
    val bundleId: String,
    val downloadUrl: String,
    val expiresAt: String?,
    val size: Int,
)

class MapBundleUploadError(message: String, cause: Throwable? = null) : Exception(message, cause)

class MapBundleUploader(
    private val backendUrl: String,
    private val backendToken: String,
) {
    /**
     * Upload [bundle] to `${backendUrl}/sessions`. Blocks the calling thread —
     * call from a background worker. Throws [MapBundleUploadError] on any
     * non-2xx or network error so callers can fall back to BLE direct.
     */
    fun upload(bundle: ByteArray): UploadResult {
        if (backendUrl.isBlank()) {
            throw MapBundleUploadError("BACKEND_URL is empty (set via gradle.properties)")
        }
        val url = URL("${backendUrl.trimEnd('/')}/sessions")
        val conn = (url.openConnection() as HttpURLConnection).apply {
            connectTimeout = UPLOAD_TIMEOUT_MS
            readTimeout = UPLOAD_TIMEOUT_MS
            requestMethod = "POST"
            doOutput = true
            doInput = true
            setRequestProperty("Content-Type", "application/octet-stream")
            setRequestProperty("Authorization", "Bearer $backendToken")
            setFixedLengthStreamingMode(bundle.size)
        }
        return try {
            conn.outputStream.use { it.write(bundle) }
            val code = conn.responseCode
            val body = (if (code in 200..299) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use { it.readText() }
                .orEmpty()
            if (code !in 200..299) {
                throw MapBundleUploadError("upload failed: HTTP $code body=$body")
            }
            val json = JSONObject(body)
            val result = UploadResult(
                bundleId = json.getString("sessionId"),
                downloadUrl = json.getString("downloadUrl"),
                expiresAt = json.optString("expiresAt").ifEmpty { null },
                size = json.optInt("size", bundle.size),
            )
            AppLog.i(TAG, "uploaded ${result.size}B → ${result.bundleId}")
            result
        } catch (e: MapBundleUploadError) {
            throw e
        } catch (e: Exception) {
            throw MapBundleUploadError("upload error: ${e.message}", e)
        } finally {
            conn.disconnect()
        }
    }
}
