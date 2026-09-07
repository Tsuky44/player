package com.projectplayer.onyx_player_android

import android.content.Context
import android.view.View
import android.view.ViewGroup

/// Le cadre qui donne sa taille à la `SurfaceView`.
///
/// **Pourquoi pas un `BoxFit` côté Flutter.** Une `SurfaceView` est une couche
/// du système, pas un pixel de la scène : la mettre à l'échelle depuis un
/// widget parent n'a aucun effet. Le cadrage se décide donc ici.
///
/// **Pourquoi pas l'`AspectRatioFrameLayout` de media3.** Celui-ci se
/// redimensionne *lui-même* et demande une passe de layout à son parent. Dans
/// une vue de plateforme, le parent est Flutter : il réimpose la taille de la
/// vue à chaque image affichée. Le cadre revenait plein écran, et l'image avec
/// lui — étirée, insensible au pincement comme au réglage.
///
/// Ici le cadre garde toujours la taille qu'on lui donne et ne dimensionne que
/// son enfant. Rien à négocier avec le parent, et le calcul est refait à chaque
/// `onLayout` — donc à chaque fois que Flutter repose la vue — plus
/// immédiatement quand le cadrage change, sans attendre une passe de layout qui
/// pourrait ne jamais venir.
internal class VideoFrame(context: Context) : ViewGroup(context) {

    /// Rapport largeur/hauteur à l'affichage, ou 0 tant qu'il est inconnu.
    private var aspect: Float = 0f

    /// Le cadrage demandé — voir [VideoFraming.sizeFor].
    private var fit: OnyxVideoFit = OnyxVideoFit.CONTAIN

    fun setVideoAspect(next: Float) {
        if (next == aspect) return
        aspect = next
        applyNow()
    }

    fun setFit(next: OnyxVideoFit) {
        if (next == fit) return
        fit = next
        applyNow()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        // Le cadre prend exactement la place qu'on lui donne : c'est celle de
        // la vue de plateforme, que Flutter fixe. Seul l'enfant bouge.
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = MeasureSpec.getSize(heightMeasureSpec)
        setMeasuredDimension(width, height)
        measureSurface(width, height)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        layoutSurface(r - l, b - t)
    }

    /// Applique le cadrage sur-le-champ.
    ///
    /// Un `requestLayout()` seul suffirait dans une hiérarchie ordinaire ; dans
    /// une vue de plateforme il dépend d'une passe que Flutter pilote. Poser
    /// nous-mêmes l'enfant rend le pincement instantané et ne coûte rien : la
    /// passe suivante recalcule la même chose.
    private fun applyNow() {
        if (width <= 0 || height <= 0) {
            // Pas encore mesuré : le premier layout fera le calcul.
            requestLayout()
            return
        }
        measureSurface(width, height)
        layoutSurface(width, height)
        invalidate()
    }

    private fun measureSurface(frameWidth: Int, frameHeight: Int) {
        val surface = surface() ?: return
        val (width, height) = VideoFraming.sizeFor(frameWidth, frameHeight, aspect, fit)
        surface.measure(
            MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY),
        )
    }

    private fun layoutSurface(frameWidth: Int, frameHeight: Int) {
        val surface = surface() ?: return
        val (width, height) = VideoFraming.sizeFor(frameWidth, frameHeight, aspect, fit)
        // Centré : les bandes de la taille adaptative sont égales, et la taille
        // d'origine rogne autant des deux côtés.
        val left = (frameWidth - width) / 2
        val top = (frameHeight - height) / 2
        surface.layout(left, top, left + width, top + height)
    }

    private fun surface(): View? = if (childCount > 0) getChildAt(0) else null
}
