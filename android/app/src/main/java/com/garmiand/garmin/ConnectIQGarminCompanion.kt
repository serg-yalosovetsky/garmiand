package com.garmiand.garmin

import android.content.Context
import android.util.Log
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.ConnectIQ.IQApplicationInfoListener
import com.garmin.android.connectiq.ConnectIQ.IQMessageStatus
import com.garmin.android.connectiq.ConnectIQ.IQSendMessageListener
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import com.garmiand.protocol.SyncAck
import com.garmiand.protocol.SyncMessage
import com.garmiand.protocol.SyncMessageSerializer
import java.util.concurrent.atomic.AtomicReference

private const val TAG = "ConnectIQCompanion"
private const val WATCH_APP_ID = "71DA4029287A447BBE86B83DC1588647"
private const val SEND_TIMEOUT_MS = 8000L

class ConnectIQGarminCompanion(private val context: Context) : GarminCompanion {

    private var connectIQ: ConnectIQ? = null
    private var connectedDevice: IQDevice? = null
    private var watchApp: IQApp? = null

    fun initialize(onReady: (Boolean) -> Unit) {
        connectIQ = ConnectIQ.getInstance(context, ConnectIQ.IQConnectType.WIRELESS)
        connectIQ!!.initialize(context, false, object : ConnectIQ.ConnectIQListener {
            override fun onInitializeError(errStatus: ConnectIQ.IQSdkErrorStatus) {
                Log.e(TAG, "ConnectIQ init error: $errStatus")
                onReady(false)
            }

            override fun onSdkReady() {
                discoverDevice(onReady)
            }

            override fun onSdkShutDown() {
                Log.d(TAG, "ConnectIQ SDK shut down")
            }
        })
    }

    private fun discoverDevice(onReady: (Boolean) -> Unit) {
        val ciq = connectIQ ?: run { onReady(false); return }
        val known = try { ciq.knownDevices ?: emptyList() } catch (e: Exception) {
            Log.e(TAG, "knownDevices failed: ${e.message}")
            emptyList()
        }
        Log.i(TAG, "knownDevices: ${known.map { "${it.friendlyName}(id=${it.deviceIdentifier}, status=${it.status})" }}")

        val connected = try {
            ciq.getConnectedDevices() ?: emptyList()
        } catch (e: Exception) {
            Log.w(TAG, "getConnectedDevices failed: ${e.message}; falling back to known")
            known
        }
        Log.i(TAG, "connectedDevices: ${connected.map { it.friendlyName }}")

        val device = connected.firstOrNull()
            ?: known.firstOrNull { it.status == IQDevice.IQDeviceStatus.CONNECTED }
            ?: known.firstOrNull()
            ?: run {
                Log.w(TAG, "No Garmin devices visible to Connect IQ. Open Garmin Connect Mobile and ensure the watch is paired and connected.")
                onReady(false)
                return
            }
        connectedDevice = device
        Log.i(TAG, "Selected device: ${device.friendlyName} status=${device.status}")
        ciq.getApplicationInfo(
            WATCH_APP_ID,
            device,
            object : IQApplicationInfoListener {
                override fun onApplicationInfoReceived(app: IQApp) {
                    watchApp = app
                    Log.i(TAG, "Watch app ready on ${device.friendlyName}")
                    onReady(true)
                }

                override fun onApplicationNotInstalled(applicationId: String) {
                    Log.w(TAG, "Watch app $applicationId is NOT installed on ${device.friendlyName}. Sideload .prg to GARMIN/APPS/ on the watch.")
                    onReady(false)
                }
            }
        )
    }

    override fun send(message: SyncMessage): SyncAck {
        val ciq = connectIQ
            ?: return SyncAck(message.sessionId, ok = false, reason = "ConnectIQ not initialized")
        val device = connectedDevice
            ?: return SyncAck(message.sessionId, ok = false, reason = "No device connected")
        val app = watchApp
            ?: return SyncAck(message.sessionId, ok = false, reason = "Watch app not found")

        val payload: Map<String, Any> = SyncMessageSerializer.toMap(message)

        val result = AtomicReference<SyncAck?>(null)

        ciq.sendMessage(device, app, payload, object : IQSendMessageListener {
            override fun onMessageStatus(dev: IQDevice, iqApp: IQApp, status: IQMessageStatus) {
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
        return result.get() ?: SyncAck(message.sessionId, ok = false, reason = "Send timeout")
    }

    fun shutdown() {
        connectIQ?.shutdown(context)
        connectIQ = null
        connectedDevice = null
        watchApp = null
    }
}
