package com.garmiand.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.garmiand.garmin.GarminLink
import com.garmiand.util.AppLog

private const val TAG = "GarminLinkService"

/**
 * Foreground-сервис, который держит связь с часами (GarminLink) живой при
 * закрытой Activity и выключенном экране — иначе система убивает процесс и
 * авто-докачка карты (map_request с часов) перестаёт работать в кармане.
 *
 * Тип dataSync: мы синхронизируем карты на устройство; у connectedDevice на
 * targetSdk 35 есть runtime-требования к BT-разрешениям, которые нам не нужны —
 * транспорт идёт через Garmin Connect Mobile.
 */
class GarminLinkService : Service() {

    override fun onCreate() {
        super.onCreate()
        val channel = NotificationChannel(
            CHANNEL_ID, "Связь с часами", NotificationManager.IMPORTANCE_LOW
        )
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIF_ID, buildNotification("Подключаюсь к часам..."))
        GarminLink.ensureConnected(this) { ready ->
            updateNotification(
                if (ready) "Авто-карта активна (часы на связи)"
                else "Часы недоступны — открой Garmin Connect"
            )
        }
        AppLog.i(TAG, "GarminLinkService started")
        return START_STICKY
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotification(text))
    }

    private fun buildNotification(text: String): Notification {
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, GarminLinkService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Garmiand")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Стоп", stopIntent)
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val CHANNEL_ID = "garmiand_link"
        private const val NOTIF_ID = 2001
        const val ACTION_STOP = "com.garmiand.STOP_LINK"

        fun start(context: Context) {
            context.startForegroundService(Intent(context, GarminLinkService::class.java))
        }
    }
}
