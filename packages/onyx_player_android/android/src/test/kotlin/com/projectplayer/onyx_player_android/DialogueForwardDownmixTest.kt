package com.projectplayer.onyx_player_android

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/// Le seul morceau du portage ExoPlayer vérifiable sans appareil.
///
/// Ce qu'on protège ici n'est pas une formule mais une intention, écrite dans
/// l'ADR-0005 : sur une piste 5.1 repliée en stéréo, la voix — qui vit dans le
/// canal central — doit rester au niveau des frontales au lieu de passer 3 dB
/// dessous. Un changement qui casse un de ces tests casse l'audibilité des
/// dialogues, et ça ne se voit pas en relisant du code.
class DialogueForwardDownmixTest {

    private fun frame(vararg values: Int) =
        ShortArray(values.size) { values[it].toShort() }

    @Test
    fun `le centre arrive au niveau des frontales`() {
        // Une voix seule au centre, et la même énergie seule à l'avant gauche :
        // après repli, les deux doivent peser pareil. C'est toute la décision
        // de l'ADR-0005 en un test.
        val centreOnly = DialogueForwardDownmix.mix(
            frame(0, 0, 10000, 0, 0, 0), 6,
        )
        val frontOnly = DialogueForwardDownmix.mix(
            frame(10000, 0, 0, 0, 0, 0), 6,
        )
        assertEquals(frontOnly.first, centreOnly.first)
    }

    @Test
    fun `les surrounds gardent leur coefficient standard`() {
        val (left, _) = DialogueForwardDownmix.mix(
            frame(0, 0, 0, 0, 10000, 0), 6,
        )
        val expected = 10000 * DialogueForwardDownmix.SURROUND *
            DialogueForwardDownmix.NORMALISATION
        assertTrue(abs(left - expected) <= 1, "attendu ~$expected, obtenu $left")
    }

    @Test
    fun `le LFE donne du corps sans devenir le mixage`() {
        val (left, _) = DialogueForwardDownmix.mix(
            frame(0, 0, 0, 10000, 0, 0), 6,
        )
        val expected = 10000 * DialogueForwardDownmix.LFE *
            DialogueForwardDownmix.NORMALISATION
        assertTrue(abs(left - expected) <= 1, "attendu ~$expected, obtenu $left")
    }

    @Test
    fun `le canal gauche ne reçoit rien de l'arrière droit`() {
        // Un repli qui mélangerait les côtés ferait s'effondrer l'image stéréo.
        val (left, right) = DialogueForwardDownmix.mix(
            frame(0, 0, 0, 0, 0, 10000), 6,
        )
        assertEquals(0, left.toInt())
        assertTrue(right > 0)
    }

    @Test
    fun `six canaux à pleine échelle n'écrêtent pas`() {
        // Sans normalisation, additionner quatre canaux à fond dépasserait la
        // pleine échelle à quatre fois et produirait une distorsion franche.
        val max = Short.MAX_VALUE.toInt()
        val (left, right) = DialogueForwardDownmix.mix(
            frame(max, max, max, max, max, max), 6,
        )
        assertTrue(left <= Short.MAX_VALUE && left > 0, "gauche=$left")
        assertTrue(right <= Short.MAX_VALUE && right > 0, "droite=$right")
    }

    @Test
    fun `une piste déjà stéréo traverse sans être touchée`() {
        val (left, right) = DialogueForwardDownmix.mix(frame(1234, -4321), 2)
        assertEquals(1234, left.toInt())
        assertEquals(-4321, right.toInt())
    }

    @Test
    fun `le cinq-un sans LFE lit les arrières au bon endroit`() {
        // En 5.0 il n'y a pas de LFE : les arrières remontent d'un cran. Les
        // lire au mauvais indice donnerait un mélange incohérent, pas une
        // erreur.
        val (left, right) = DialogueForwardDownmix.mix(
            frame(0, 0, 0, 10000, 0), 5,
        )
        assertTrue(left > 0, "l'arrière gauche doit atteindre la gauche")
        assertEquals(0, right.toInt())
    }
}
