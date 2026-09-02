package com.projectplayer.onyx_player_android

import android.content.Context
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/// La raison d'être du plugin : une vraie [SurfaceView].
///
/// C'est ce qui distingue ce chemin de celui de mpv. MediaCodec écrit
/// directement dans la Surface, et le plan vidéo du contrôleur d'affichage la
/// compose avec le reste — l'image ne traverse ni le GPU ni la scène Flutter.
/// C'est l'architecture d'Emby, et la seule qui tienne le 4K sur une boîte de
/// salon.
///
/// La contrepartie tient en une phrase, et elle est structurante : **une
/// SurfaceView est une couche du système, pas un pixel Flutter.** Flutter ne
/// peut ni la mettre à l'échelle, ni la clipper en arrondi, ni lui donner une
/// ombre. Tout ce qui, côté Dart, transformait le widget vidéo est sans effet
/// ici — voir l'ADR sur le portage.
internal class PlayerSurface(
    context: Context,
    private val host: PlayerHost,
    private val playerId: Long,
) : PlatformView {

    private val surfaceView = SurfaceView(context)

    private val container = FrameLayout(context).apply {
        addView(
            surfaceView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    init {
        // Le lecteur existe déjà : la vue s'y rattache, elle ne le crée pas.
        // C'est ce qui laisse Flutter reconstruire la vue sans interrompre la
        // lecture, et ce qui permet d'ouvrir un média avant le premier rendu.
        host.playerFor(playerId)?.attachSurface(surfaceView)
    }

    override fun getView(): View = container

    override fun dispose() {
        // La Surface disparaît avec la vue ; laisser ExoPlayer écrire dedans
        // ensuite est un rendu vers une cible morte. Le lecteur, lui, survit —
        // il n'appartient pas à la vue.
        host.playerFor(playerId)?.detachSurface()
    }
}

internal class PlayerSurfaceFactory(
    private val host: PlayerHost,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as? Map<*, *>
        val playerId = (params?.get(PLAYER_ID_KEY) as? Number)?.toLong()
            ?: error("$VIEW_TYPE créée sans $PLAYER_ID_KEY")
        return PlayerSurface(context, host, playerId)
    }

    companion object {
        /// Doit correspondre au `viewType` du widget Dart. La constante est ici
        /// et n'est écrite qu'une fois de l'autre côté.
        const val VIEW_TYPE = "onyx_player_android/surface"
        const val PLAYER_ID_KEY = "playerId"
    }
}
