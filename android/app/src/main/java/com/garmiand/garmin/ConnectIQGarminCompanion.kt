package com.garmiand.garmin

import android.content.Context
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.ConnectIQ.IQApplicationInfoListener
import com.garmin.android.connectiq.ConnectIQ.IQMessageStatus
import com.garmin.android.connectiq.ConnectIQ.IQSendMessageListener
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import com.garmiand.protocol.SyncAck
import com.garmiand.protocol.SyncMessage
import com.garmiand.protocol.SyncMessageSerializer
import com.garmiand.util.AppLog
import java.util.concurrent.atomic.AtomicReference

private const val TAG = "ConnectIQCompanion"
private const val WATCH_APP_ID = "71DA4029287A447BBE86B83DC1588647"
private const val SEND_TIMEOUT_MS = 60000L

class ConnectIQGarminCompanion(private val context: Context) : GarminCompanion {

    private var connectIQ: ConnectIQ? = null
    private var connectedDevice: IQDevice? = null
    private var watchApp: IQApp? = null
    @Volatile private var watchMessageListener: ((Map<*, *>) -> Unit)? = null

    fun initialize(onReady: (Boolean) -> Unit) {
        connectIQ = ConnectIQ.getInstance(context, ConnectIQ.IQConnectType.WIRELESS)
        connectIQ!!.initialize(context, false, object : ConnectIQ.ConnectIQListener {
            override fun onInitializeError(errStatus: ConnectIQ.IQSdkErrorStatus) {
                AppLog.e(TAG, "ConnectIQ init error: $errStatus")
                onReady(false)
            }

            override fun onSdkReady() {
                discoverDevice(onReady)
            }

            override fun onSdkShutDown() {
                AppLog.d(TAG, "ConnectIQ SDK shut down")
            }
        })
    }

    private fun discoverDevice(onReady: (Boolean) -> Unit) {
        val ciq = connectIQ ?: run { onReady(false); return }
        val known = try { ciq.knownDevices ?: emptyList() } catch (e: Exception) {
            AppLog.e(TAG, "knownDevices failed", e)
            emptyList()
        }
        AppLog.i(TAG, "knownDevices: ${known.map { "${it.friendlyName}(id=${it.deviceIdentifier}, status=${it.status})" }}")

        val connected = try {
            ciq.getConnectedDevices() ?: emptyList()
        } catch (e: Exception) {
            AppLog.w(TAG, "getConnectedDevices failed: ${e.message}; falling back to known")
            known
        }
        AppLog.i(TAG, "connectedDevices: ${connected.map { it.friendlyName }}")

        val device = connected.firstOrNull()
            ?: known.firstOrNull { it.status == IQDevice.IQDeviceStatus.CONNECTED }
            ?: known.firstOrNull()
            ?: run {
                AppLog.w(TAG, "No Garmin devices visible. Ensure Garmin Connect Mobile is open and watch is paired+connected.")
                onReady(false)
                return
            }
        connectedDevice = device
        AppLog.i(TAG, "Selected device: ${device.friendlyName} status=${device.status}")
        ciq.getApplicationInfo(
            WATCH_APP_ID,
            device,
            object : IQApplicationInfoListener {
                override fun onApplicationInfoReceived(app: IQApp) {
                    watchApp = app
                    AppLog.i(TAG, "Watch app ready on ${device.friendlyName}")
                    // Register for messages the watch sends to us (ble_wip_report, etc.)
                    try {
                        ciq.registerForAppEvents(device, app) { _, _, messages, _ ->
                            val msg = messages.firstOrNull()
                            if (msg is Map<*, *>) {
                                AppLog.d(TAG, "watch→phone msg kind=${(msg as Map<*, *>)["kind"]}")
                                watchMessageListener?.invoke(msg)
                            }
                        }
                    } catch (e: Exception) {
                        AppLog.w(TAG, "registerForAppEvents failed: ${e.message}")
                    }
                    onReady(true)
                }

                override fun onApplicationNotInstalled(applicationId: String) {
                    AppLog.w(TAG, "Watch app $applicationId NOT installed on ${device.friendlyName}.")
                    onReady(false)
                }
            }
        )
    }

    override fun setWatchMessageListener(listener: ((Map<*, *>) -> Unit)?) {
        watchMessageListener = listener
    }

    override fun send(message: SyncMessage): SyncAck {
        val ciq = connectIQ
            ?: return SyncAck(message.sessionId, ok = false, reason = "ConnectIQ not initialized")
        val device = connectedDevice
            ?: return SyncAck(message.sessionId, ok = false, reason = "No device connected")
        val app = watchApp
            ?: return SyncAck(message.sessionId, ok = false, reason = "Watch app not found")

        val payload: Map<String, Any> = SyncMessageSerializer.toMap(message)
        val kind = payload["kind"] ?: message::class.simpleName
        AppLog.i(TAG, "send -> $kind keys=${payload.keys}")

        val result = AtomicReference<SyncAck?>(null)

        ciq.sendMessage(device, app, payload, object : IQSendMessageListener {
            override fun onMessageStatus(dev: IQDevice, iqApp: IQApp, status: IQMessageStatus) {
                AppLog.i(TAG, "ack $kind status=$status")
                result.set(
                    SyncAck(
                        sessionId = message.sessionId,
                        ok = status == IQMessageStatus.SUCCESS,
                        reason = if (status != IQMessageStatus.SUCCESS) "IQ status $status" else null,
                    )
                )
            }
        })

        val deadline = System.currentTimeMillis() + SEND_TIMEOUT_MS
        while (result.get() == null && System.currentTimeMillis() < deadline) {
            Thread.sleep(50)
        }
        val ack = result.get() ?: SyncAck(message.sessionId, ok = false, reason = "Send timeout")
        if (!ack.ok) AppLog.w(TAG, "send $kind failed: ${ack.reason}")
        return ack
    }

    fun shutdown() {
        connectIQ?.shutdown(context)
        connectIQ = null
        connectedDevice = null
        watchApp = null
    }
}
