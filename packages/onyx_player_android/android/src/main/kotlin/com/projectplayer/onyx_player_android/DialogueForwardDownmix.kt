package com.projectplayer.onyx_player_android

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer

/// Le repli stéréo d'Onyx, avec le dialogue en avant — voir l'ADR-0005.
///
/// mpv posait trois coefficients sur le rééchantillonneur qu'il utilisait de
/// toute façon (`center_mix_level=1.0`, `surround_mix_level=0.7`,
/// `lfe_mix_level=0.3`). ExoPlayer n'a pas d'équivalent : il faut faire le
/// mélange soi-même, et c'est ce que fait cette classe.
///
/// Le problème qu'elle résout est concret : sur une piste 5.1 repliée en
/// stéréo par la formule usuelle, la voix — qui vit presque entièrement dans
/// le canal central — se retrouve 3 dB sous les effets, et les dialogues
/// deviennent inaudibles dès qu'il se passe quelque chose à l'écran. Remonter
/// le centre au niveau des frontales corrige exactement ça, sans toucher au
/// reste du mixage.
///
/// **Inerte quand elle doit l'être.** Un appareil relié à un ampli reçoit ses
/// six canaux tels quels : le processeur ne s'active que si l'entrée a plus de
/// deux canaux, donc là où un repli aurait lieu de toute façon.
internal class DialogueForwardDownmix : BaseAudioProcessor() {

    override fun onConfigure(
        inputAudioFormat: AudioProcessor.AudioFormat,
    ): AudioProcessor.AudioFormat {
        // Deux canaux ou moins : rien à replier, on se retire de la chaîne.
        if (inputAudioFormat.channelCount <= 2) {
            return AudioProcessor.AudioFormat.NOT_SET
        }
        // Seul le PCM 16 bits est traité. Un flux compressé qui traverse en
        // passthrough n'a pas à être touché — et ne peut pas l'être.
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        return AudioProcessor.AudioFormat(
            inputAudioFormat.sampleRate,
            2,
            C.ENCODING_PCM_16BIT,
        )
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val channels = inputAudioFormat.channelCount
        val frameCount = inputBuffer.remaining() / (channels * BYTES_PER_SAMPLE)
        if (frameCount == 0) {
            inputBuffer.position(inputBuffer.limit())
            return
        }

        val output = replaceOutputBuffer(frameCount * 2 * BYTES_PER_SAMPLE)
        val samples = ShortArray(channels)

        repeat(frameCount) {
            for (c in 0 until channels) {
                samples[c] = inputBuffer.short
            }
            val (left, right) = mix(samples, channels)
            output.putShort(left)
            output.putShort(right)
        }

        inputBuffer.position(inputBuffer.limit())
        output.flip()
    }

    internal companion object {
        const val BYTES_PER_SAMPLE = 2

        /// Les trois nombres de l'ADR-0005.
        const val CENTER = 1.0
        const val SURROUND = 0.7
        const val LFE = 0.3

        /// Ce qui empêche l'écrêtage.
        ///
        /// Additionner une frontale, un centre à pleine échelle, un surround et
        /// un LFE peut dépasser la pleine échelle à quatre fois. Diviser par la
        /// somme des coefficients est ce que fait le rééchantillonneur de
        /// FFmpeg par défaut sur une sortie entière, et c'est ce qui garde les
        /// proportions entre les canaux — donc l'intention de l'ADR — au lieu
        /// d'écraser les crêtes.
        const val NORMALISATION = 1.0 / (1.0 + CENTER + SURROUND + LFE)

        /// Replie une trame vers un couple stéréo.
        ///
        /// L'ordre des canaux est celui de PCM/WAVE, que MediaCodec produit :
        /// avant-gauche, avant-droit, centre, LFE, arrière-gauche,
        /// arrière-droit. Une disposition inconnue tombe sur les deux premiers
        /// canaux, qui sont les frontales dans toutes les dispositions
        /// courantes — se tromper vers un stéréo plat vaut mieux que se tromper
        /// vers un mélange incohérent.
        fun mix(samples: ShortArray, channels: Int): Pair<Short, Short> {
            val frontLeft = samples[0].toDouble()
            val frontRight = samples[1].toDouble()

            if (channels < 5) {
                return clamp(frontLeft) to clamp(frontRight)
            }

            val centre = samples[2].toDouble()
            val lfe = if (channels >= 6) samples[3].toDouble() else 0.0
            val backLeft = samples[if (channels >= 6) 4 else 3].toDouble()
            val backRight = samples[if (channels >= 6) 5 else 4].toDouble()

            val left =
                (frontLeft + CENTER * centre + SURROUND * backLeft + LFE * lfe) *
                    NORMALISATION
            val right =
                (frontRight + CENTER * centre + SURROUND * backRight + LFE * lfe) *
                    NORMALISATION
            return clamp(left) to clamp(right)
        }

        fun clamp(value: Double): Short =
            value.coerceIn(Short.MIN_VALUE.toDouble(), Short.MAX_VALUE.toDouble())
                .toInt()
                .toShort()
    }
}
