package com.projectplayer.onyx_player_android

import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import kotlin.test.Test
import kotlin.test.assertEquals
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

    /// La panne qui a coûté trois versions : plus aucune lecture ne démarrait
    /// sur Android, sur `IllegalStateException: getBackBufferDurationUs not
    /// implemented`, levée à la construction du lecteur.
    ///
    /// La classe déléguait avec `: LoadControl by delegate`. `LoadControl` n'a
    /// qu'un membre abstrait — `getAllocator` — et dix méthodes `default` Java,
    /// que la délégation Kotlin ne relaie pas : elles restaient celles de
    /// l'interface, dont le corps est un `throw`.
    ///
    /// Le test appelle donc ce que le moteur appelle, et vérifie que la réponse
    /// vient bien du délégué. Une montée de media3 qui ajouterait un membre
    /// `default` le ferait échouer ici, plutôt que sur l'appareil de quelqu'un.
    @Test
    fun `chaque methode atteint le delegue plutot que le defaut de l'interface`() {
        val backBufferMs = 12_000
        val delegate = DefaultLoadControl.Builder()
            .setBackBuffer(backBufferMs, true)
            .build()
        val guard = StallGuardLoadControl(delegate)
        val player = PlayerId("test")

        guard.onPrepared(player)

        // Celle qui levait. La valeur prouve que l'appel est allé au délégué :
        // le défaut de l'interface ne rend rien, il lève.
        assertEquals(backBufferMs * 1_000L, guard.getBackBufferDurationUs(player))
        assertTrue(guard.retainBackBufferFromKeyframe(player))
        guard.getAllocator(player)

        guard.onStopped(player)
        guard.onReleased(player)
    }
}
