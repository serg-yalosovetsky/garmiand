package com.garmiand.util

import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList

object AppLog {

    private const val MAX_LINES = 500
    private val timeFmt = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    private val buffer = ArrayDeque<String>()
    private val listeners = CopyOnWriteArrayList<(String) -> Unit>()

    fun addListener(l: (String) -> Unit) {
        listeners.add(l)
        synchronized(buffer) {
            buffer.forEach { line -> l(line) }
        }
    }

    fun removeListener(l: (String) -> Unit) {
        listeners.remove(l)
    }

    fun snapshot(): String = synchronized(buffer) { buffer.joinToString("\n") }

    fun clear() {
        synchronized(buffer) { buffer.clear() }
        listeners.forEach { it("__CLEAR__") }
    }

    fun i(tag: String, msg: String) { append("I", tag, msg); Log.i(tag, msg) }
    fun w(tag: String, msg: String) { append("W", tag, msg); Log.w(tag, msg) }
    fun e(tag: String, msg: String, t: Throwable? = null) {
        append("E", tag, msg + (t?.let { " :: ${it.message}" } ?: ""))
        if (t != null) Log.e(tag, msg, t) else Log.e(tag, msg)
    }
    fun d(tag: String, msg: String) { append("D", tag, msg); Log.d(tag, msg) }

    private fun append(level: String, tag: String, msg: String) {
        val line = "${timeFmt.format(Date())} $level/$tag: $msg"
        synchronized(buffer) {
            buffer.addLast(line)
            while (buffer.size > MAX_LINES) buffer.removeFirst()
        }
        listeners.forEach { it(line) }
    }
}
