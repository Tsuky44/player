package com.projectplayer.onyx_player_android

import io.flutter.embedding.engine.plugins.FlutterPlugin

/// Point d'entrée du plugin : branche le contrat Pigeon, le flux d'événements
/// et la fabrique de vues, puis rend tout à la fermeture.
class OnyxPlayerAndroidPlugin : FlutterPlugin {
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
}
