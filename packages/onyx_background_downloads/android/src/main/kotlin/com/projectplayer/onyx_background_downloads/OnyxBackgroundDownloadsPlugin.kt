package com.projectplayer.onyx_background_downloads

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Le canal `onyx/background_downloads` côté Android : démarre, met à jour et
 * arrête [DownloadKeepAliveService].
 *
 * Le premier téléchargement demande aussi la permission des notifications
 * (Android 13+), une seule fois par processus : c'est le moment où l'on
 * comprend pourquoi l'app la demande. Refusée, rien ne change au transfert.
 */
class OnyxBackgroundDownloadsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private var askedForNotifications = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "onyx/background_downloads")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "keepAlive" -> {
                askForNotificationsOnce()
                DownloadKeepAliveService.show(
                    context,
                    DownloadNotice(
                        title = call.argument<String>("title") ?: "",
                        text = call.argument<String>("text") ?: "",
                        percent = call.argument<Int>("percent") ?: -1,
                    ),
                )
                result.success(null)
            }
            "release" -> {
                DownloadKeepAliveService.release(context)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun askForNotificationsOnce() {
        if (askedForNotifications || Build.VERSION.SDK_INT < 33) return
        val current = activity ?: return
        if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        askedForNotifications = true
        current.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATIONS_REQUEST)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    private companion object {
        const val NOTIFICATIONS_REQUEST = 0x0d17
    }
}
