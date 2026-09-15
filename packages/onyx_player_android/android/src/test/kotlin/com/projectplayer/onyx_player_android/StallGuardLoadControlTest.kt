package com.projectplayer.onyx_player_android

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/// Le blocage que la garde lève : la cible d'octets remplie par le tampon
/// arrière d'un remux 4K, et plus rien devant la tête de lecture.
class StallGuardLoadControlTest {

    private val floor = StallGuardLoadControl.DEFAULT_FLOOR_US

    @Test
    fun `ce que le delegue veut charger est charge`() {
        assertTrue(StallGuardLoadControl.shouldLoad(true, 60_000_000, floor) { false })
    }

    @Test
    fun `cible atteinte et tampon avant presque vide on charge quand meme`() {
        // Le cas du film qui « charge » indéfiniment.
        assertTrue(StallGuardLoadControl.shouldLoad(false, 200_000, floor) { true })
    }

    @Test
    fun `au-dessus du plancher la cible du delegue fait foi`() {
        assertFalse(StallGuardLoadControl.shouldLoad(false, floor, floor) { true })
    }

    @Test
    fun `sans place dans le tas la garde ne force rien`() {
        // Dépasser le tas Java tue l'app : mieux vaut une mise en mémoire tampon.
        assertFalse(StallGuardLoadControl.shouldLoad(false, 0, floor) { false })
    }
}
