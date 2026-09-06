package com.projectplayer.onyx_player_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/// Ce que « taille adaptative » et « taille d'origine » veulent dire, en
/// chiffres.
///
/// Le reste du cadrage — la vue, la SurfaceView, la vue de plateforme — ne se
/// vérifie qu'un téléphone en main. La géométrie, elle, se vérifie ici, et
/// c'est là que vivaient les deux défauts qui rendaient l'image étirée : un
/// rapport de pixels que le décodeur n'annonce pas, et un rapport d'image
/// jamais appliqué.
class VideoFramingTest {

    // Un téléphone tenu à l'horizontale, en pixels.
    private val screenWidth = 2400
    private val screenHeight = 1080

    @Test
    fun `un rapport de pixels absent vaut des pixels carres`() {
        // Certains décodeurs annoncent 0 plutôt que 1. Le prendre au mot
        // donnait un rapport nul, donc aucun cadrage : l'image étirée sur tout
        // l'écran, insensible au pincement comme au réglage.
        assertEquals(
            VideoFraming.aspectOf(1920, 1080, 1f),
            VideoFraming.aspectOf(1920, 1080, 0f),
        )
    }

    @Test
    fun `les pixels non carres comptent dans le rapport`() {
        // Un DVD anamorphosé : 720 × 576 stockés, affichés en 16:9.
        val aspect = VideoFraming.aspectOf(720, 576, 1.4587f)
        assertTrue(aspect > 1.7f && aspect < 1.85f, "rapport obtenu : $aspect")
    }

    @Test
    fun `en taille adaptative l'image entiere tient dans le cadre`() {
        // Un film large sur un écran moins large : des bandes en haut et en
        // bas, et rien qui dépasse.
        val (width, height) = VideoFraming.sizeFor(
            screenWidth, screenHeight, aspect = 2.39f, cover = false,
        )
        assertEquals(screenWidth, width)
        assertTrue(height < screenHeight, "hauteur obtenue : $height")
    }

    @Test
    fun `en taille d'origine l'image couvre le cadre`() {
        // Le même film, pincé pour remplir : plus de bandes, et ce qui dépasse
        // sort du cadre au lieu d'y être écrasé.
        val (width, height) = VideoFraming.sizeFor(
            screenWidth, screenHeight, aspect = 2.39f, cover = true,
        )
        assertEquals(screenHeight, height)
        assertTrue(width > screenWidth, "largeur obtenue : $width")
    }

    @Test
    fun `le rapport de l'image est tenu dans les deux cadrages`() {
        // La déformation est le seul défaut qu'on ne peut pas rattraper à
        // l'œil : les deux cadrages doivent rendre le rapport demandé.
        for (cover in listOf(false, true)) {
            val (width, height) = VideoFraming.sizeFor(
                screenWidth, screenHeight, aspect = 1.85f, cover = cover,
            )
            val rendered = width.toFloat() / height
            assertTrue(
                kotlin.math.abs(rendered - 1.85f) < 0.01f,
                "cover=$cover, rapport rendu : $rendered",
            )
        }
    }

    @Test
    fun `sans rapport connu le cadre est rempli tel quel`() {
        // Avant la première image il n'y a que du noir : le remplir évite un
        // saut au moment où le décodeur annonce enfin sa taille.
        assertEquals(
            screenWidth to screenHeight,
            VideoFraming.sizeFor(screenWidth, screenHeight, aspect = 0f, cover = false),
        )
    }

    @Test
    fun `une image plus etroite que le cadre est traitee symetriquement`() {
        // Une vidéo verticale sur un écran horizontal : des bandes sur les
        // côtés en adaptatif, un débordement en haut et en bas sinon.
        val contain = VideoFraming.sizeFor(
            screenWidth, screenHeight, aspect = 0.5625f, cover = false,
        )
        assertEquals(screenHeight, contain.second)
        assertTrue(contain.first < screenWidth)

        val cover = VideoFraming.sizeFor(
            screenWidth, screenHeight, aspect = 0.5625f, cover = true,
        )
        assertEquals(screenWidth, cover.first)
        assertTrue(cover.second > screenHeight)
    }
}
