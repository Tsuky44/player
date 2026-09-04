package com.projectplayer.onyx_player_android

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

/// Point d'entrée du plugin : branche le contrat Pigeon, le flux d'événements
/// et la fabrique de vues, puis rend tout à la fermeture.
///
/// [ActivityAware] pour une seule raison : tenir l'écran allumé pendant la
/// lecture demande une fenêtre, et un plugin n'en a pas — il n'a que le
/// `Context` de l'application. Voir `PlayerHost.refreshScreenOn`.
class OnyxPlayerAndroidPlugin : FlutterPlugin, ActivityAware {
    private var host: PlayerHost? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val host = PlayerHost(binding.applicationContext)
        this.host = host

        OnyxPlayerApi.setUp(binding.binaryMessenger, host)

        StatusChangedStreamHandler.register(
            binding.binaryMessenger,
            object : StatusChangedStreamHandler() {
                override fun onListen(p0: Any?, sink: PigeonEventSink<OnyxPlayerStatus>) {
                    host.attachSink(sink)
                }

                override fun onCancel(p0: Any?) {
                    host.attachSink(null)
                }
            },
        )

        binding.platformViewRegistry.registerViewFactory(
            PlayerSurfaceFactory.VIEW_TYPE,
            PlayerSurfaceFactory(host),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        OnyxPlayerApi.setUp(binding.binaryMessenger, null)
        host?.releaseAll()
        host = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        host?.attachActivity(binding.activity)
    }

    /// Une rotation ou un changement de configuration détruit l'activité et en
    /// reconstruit une. Lâcher l'ancienne ici et prendre la nouvelle juste
    /// après est ce qui fait que le drapeau se repose sur la bonne fenêtre.
    override fun onDetachedFromActivityForConfigChanges() {
        host?.attachActivity(null)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        host?.attachActivity(binding.activity)
    }

    override fun onDetachedFromActivity() {
        host?.attachActivity(null)
    }
}
