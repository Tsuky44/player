package com.projectplayer.onyx_background_downloads

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/** Ce que dit la notification. [percent] vaut -1 quand la taille est inconnue. */
data class DownloadNotice(val title: String, val text: String, val percent: Int)

/**
 * Garde le processus éveillé pendant un téléchargement hors ligne.
 *
 * Le transfert est du Dart (un `GET Range:` écrit en append, ADR-0010) : il
 * n'a besoin que d'un processus qui continue de tourner. Écran éteint, Android
 * gèle une app sans service de premier plan, puis la sort du réseau quand
 * l'appareil passe en Doze ; un service de premier plan en est exempté. Les
 * verrous processeur et Wi-Fi empêchent le reste : le processeur qui s'endort
 * entre deux paquets, le Wi-Fi qui passe en économie et divise le débit.
 *
 * Android 15 borne les services « synchronisation de données » à six heures
 * par jour : passé ce délai, [onTimeout] arrête le service, et le transfert
 * continue tant que le système laisse vivre le processus.
 */
class DownloadKeepAliveService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification(this, notice)
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Démarrage refusé (quota de six heures épuisé, app déjà en
            // arrière-plan) : le transfert continue tant que le processus vit,
            // sans garantie.
            Log.w(TAG, "Service de téléchargement refusé : $e")
            state = State.STOPPED
            stopSelf()
            return START_NOT_STICKY
        }
        state = State.RUNNING
        holdLocks()
        if (releaseRequested) {
            // `release` est arrivé avant ce premier passage. Arrêter le service
            // avant `startForeground` fait planter l'app sur Android 8 à 11 :
            // l'arrêt attend donc que le service soit au premier plan.
            releaseRequested = false
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        state = State.STOPPED
        wakeLock?.takeIf { it.isHeld }?.release()
        wifiLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        wifiLock = null
        super.onDestroy()
    }

    private fun holdLocks() {
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "onyx:downloads").apply {
                setReferenceCounted(false)
                acquire(LOCK_TIMEOUT_MS)
            }
        }
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
            // Le mode que prend aussi ExoPlayer pendant une lecture en flux.
            @Suppress("DEPRECATION")
            wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "onyx:downloads").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private enum class State { STOPPED, STARTING, RUNNING }

    companion object {
        private const val TAG = "OnyxDownloads"
        private const val CHANNEL_ID = "onyx_downloads"
        private const val NOTIFICATION_ID = 0x0d1

        // La borne d'Android 15 pour ce type de service : un verrou ne survit
        // pas à la raison qui l'a fait prendre.
        private const val LOCK_TIMEOUT_MS = 6L * 60 * 60 * 1000

        // Lus et écrits sur le fil principal seulement : le canal Flutter et
        // les rappels du service y arrivent tous.
        private var state = State.STOPPED
        private var releaseRequested = false
        private var notice = DownloadNotice("", "", -1)

        fun show(context: Context, next: DownloadNotice) {
            notice = next
            releaseRequested = false
            when (state) {
                State.RUNNING -> {
                    // Mettre à jour la notification plutôt que redémarrer le
                    // service : un `startForegroundService` lancé depuis
                    // l'arrière-plan est refusé depuis Android 12.
                    val manager = context.getSystemService(NotificationManager::class.java)
                    manager?.notify(NOTIFICATION_ID, buildNotification(context, next))
                }
                State.STARTING -> Unit // `onStartCommand` lira `notice`.
                State.STOPPED -> {
                    val intent = Intent(context, DownloadKeepAliveService::class.java)
                    try {
                        if (Build.VERSION.SDK_INT >= 26) {
                            context.startForegroundService(intent)
                        } else {
                            context.startService(intent)
                        }
                        state = State.STARTING
                    } catch (e: Exception) {
                        Log.w(TAG, "Service de téléchargement non démarré : $e")
                    }
                }
            }
        }

        fun release(context: Context) {
            when (state) {
                State.STARTING -> releaseRequested = true
                State.RUNNING -> context.stopService(Intent(context, DownloadKeepAliveService::class.java))
                State.STOPPED -> Unit
            }
        }

        private fun buildNotification(context: Context, notice: DownloadNotice): Notification {
            val builder = if (Build.VERSION.SDK_INT >= 26) {
                ensureChannel(context)
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            builder
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(notice.title)
                .setContentText(notice.text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_PROGRESS)
                .setProgress(100, notice.percent.coerceIn(0, 100), notice.percent < 0)
            context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
                builder.setContentIntent(
                    PendingIntent.getActivity(
                        context,
                        0,
                        launch,
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                    ),
                )
            }
            if (Build.VERSION.SDK_INT >= 31) {
                // Sans ça, Android retarde de dix secondes l'affichage d'une
                // notification de service : un épisode court serait fini avant.
                builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }
            return builder.build()
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Téléchargements", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Progression des téléchargements hors ligne"
                    setShowBadge(false)
                },
            )
        }
    }
}
