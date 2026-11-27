package com.winterhub.winter_chat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/// Служба «Winter Chat на связи»: пока она работает, Android не усыпляет приложение,
/// и уведомления о сообщениях приходят сразу. Само соединение держит приложение (Dart).
class KeepAliveService : Service() {
    companion object {
        private const val CHANNEL = "keepalive"
        private const val ID = 7301

        fun start(c: Context) {
            val i = Intent(c, KeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i) else c.startService(i)
        }

        fun stop(c: Context) {
            c.stopService(Intent(c, KeepAliveService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
            val ch = NotificationChannel(CHANNEL, "Winter Chat на связи", NotificationManager.IMPORTANCE_MIN)
            ch.description = "Чтобы сообщения приходили сразу. Это уведомление можно скрыть в настройках канала."
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val open = PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        val n = b.setContentTitle("Winter Chat на связи")
            .setContentText("Сообщения придут сразу")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setContentIntent(open)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
            } else {
                startForeground(ID, n)
            }
        } catch (e: Exception) {
            // Система не разрешила (например, приложение уже в фоне) — обойдёмся проверкой раз в 15 минут.
            stopSelf()
        }
        // Если систему всё-таки заставили закрыть приложение — не воскрешать пустую службу.
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Приложение смахнули из недавних: Dart-часть закрылась, держать службу незачем.
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }
}
