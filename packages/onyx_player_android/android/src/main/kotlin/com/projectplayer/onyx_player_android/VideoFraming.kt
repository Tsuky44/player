package com.projectplayer.onyx_player_android

import kotlin.math.roundToInt

/// La géométrie du cadrage, sans rien d'Android autour.
///
/// C'est la partie qu'une erreur rend visible immédiatement — une image étirée,
/// des visages allongés — et la seule du cadrage qu'on puisse vérifier sans
/// appareil. Elle est donc séparée de la vue qui l'applique ([VideoFrame]).
internal object VideoFraming {

    /// Le rapport largeur/hauteur **à l'affichage**.
    ///
    /// Les pixels ne sont pas toujours carrés : un DVD anamorphosé stocke une
    /// image plus étroite qu'elle ne doit s'afficher, et l'ignorer allonge les
    /// visages.
    ///
    /// Un décodeur qui ne renseigne pas ce rapport peut annoncer 0 plutôt que
    /// 1. Le prendre au mot donnerait un rapport nul — c'est-à-dire aucun
    /// cadrage du tout, et l'image étirée sur tout l'écran.
    fun aspectOf(width: Int, height: Int, pixelRatio: Float): Float {
        if (width <= 0 || height <= 0) return 0f
        val ratio = if (pixelRatio.isFinite() && pixelRatio > 0f) pixelRatio else 1f
        return width * ratio / height
    }

    /// La taille de l'image dans un cadre de [frameWidth] × [frameHeight].
    ///
    /// [cover] distingue les deux seuls cadrages que le lecteur propose :
    /// « taille adaptative » fait entrer l'image entière dans le cadre, avec
    /// des bandes s'il le faut ; « taille d'origine » la fait couvrir le cadre,
    /// et ce qui dépasse est rogné.
    ///
    /// Tant que le rapport est inconnu — avant la première image — le cadre est
    /// rempli tel quel : c'est du noir, et il n'a pas à sauter quand le
    /// décodeur répond.
    fun sizeFor(
        frameWidth: Int,
        frameHeight: Int,
        aspect: Float,
        cover: Boolean,
    ): Pair<Int, Int> {
        if (frameWidth <= 0 || frameHeight <= 0 || aspect <= 0f) {
            return frameWidth to frameHeight
        }
        val frameAspect = frameWidth.toFloat() / frameHeight
        // Une image plus large que son cadre y entre en fixant sa largeur, et
        // le couvre en fixant sa hauteur. Plus étroite, c'est exactement
        // l'inverse — d'où le seul booléen.
        val boundByWidth = if (cover) aspect < frameAspect else aspect > frameAspect
        return if (boundByWidth) {
            frameWidth to (frameWidth / aspect).roundToInt().coerceAtLeast(1)
        } else {
            (frameHeight * aspect).roundToInt().coerceAtLeast(1) to frameHeight
        }
    }
}
