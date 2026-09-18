package com.projectplayer.onyx_player_android

import androidx.media3.common.Timeline
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.TrackGroupArray
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.upstream.Allocator

/// `DefaultLoadControl`, sans le blocage des gros débits.
///
/// ExoPlayer arrête de charger dès que les octets en mémoire atteignent sa
/// cible — environ 140 Mo pour un film. Le tampon **arrière** compte dans ces
/// octets, alors qu'il se mesure en secondes. Sur un remux 4K à 80 Mbit/s,
/// quinze secondes de retour pèsent déjà 150 Mo : la cible est atteinte par ce
/// qui a déjà été vu, le chargement s'arrête, le tampon avant se vide, et la
/// lecture passe en mise en mémoire tampon. Pendant qu'elle attend, la tête de
/// lecture ne bouge plus, donc le tampon arrière ne se libère jamais — le film
/// « charge » indéfiniment. Un 1080p à 10 Mbit/s n'en approche pas, d'où un
/// problème qui ne touche que les gros fichiers.
///
/// La garde : tant qu'il reste moins de [floorUs] devant la tête de lecture, on
/// charge quand même, pourvu que le tas Java ait encore de la place — c'est là
/// que vivent les tampons d'ExoPlayer, et le dépasser tue l'app.
///
/// ## Pourquoi chaque méthode est réécrite à la main
///
/// Cette classe déléguait avec `: LoadControl by delegate`, et **aucune lecture
/// ne démarrait plus sur Android** : `IllegalStateException:
/// getBackBufferDurationUs not implemented`, levée à la construction du
/// lecteur, donc avant le moindre octet de vidéo.
///
/// `LoadControl` n'a qu'un seul membre abstrait, `getAllocator` ; ses dix
/// autres sont des méthodes `default` Java. La délégation Kotlin ne génère un
/// relais que pour les membres abstraits : les `default` restent ceux de
/// l'interface. Or ceux-là ne font pas ce qu'on croit — la version qui prend un
/// `PlayerId` appelle la surcharge sans argument, dont le corps est un `throw`.
/// Le `DefaultLoadControl` configuré au-dessus n'était donc jamais consulté,
/// pour rien d'autre que l'allocateur.
///
/// D'où le passe-plat explicite ci-dessous. Il est verbeux, et c'est sa
/// qualité : chaque ligne dit où va l'appel, et une montée de media3 qui
/// ajouterait un membre le fera voir en refusant de compiler plutôt qu'en
/// levant sur l'appareil de quelqu'un.
internal class StallGuardLoadControl(
    private val delegate: DefaultLoadControl,
    private val floorUs: Long = DEFAULT_FLOOR_US,
    private val heapHasHeadroom: () -> Boolean = ::javaHeapHasHeadroom,
) : LoadControl {

    /// La seule méthode qui fait autre chose que relayer.
    override fun shouldContinueLoading(parameters: LoadControl.Parameters): Boolean {
        // Le délégué d'abord, toujours : il tient son propre état de chargement
        // et doit voir passer chaque appel.
        val wanted = delegate.shouldContinueLoading(parameters)
        return shouldLoad(wanted, parameters.bufferedDurationUs, floorUs, heapHasHeadroom)
    }

    // --- Le passe-plat -------------------------------------------------------

    override fun onPrepared(playerId: PlayerId) = delegate.onPrepared(playerId)

    override fun onTracksSelected(
        parameters: LoadControl.Parameters,
        trackGroups: TrackGroupArray,
        trackSelections: Array<ExoTrackSelection?>,
    ) = delegate.onTracksSelected(parameters, trackGroups, trackSelections)

    override fun onStopped(playerId: PlayerId) = delegate.onStopped(playerId)

    override fun onReleased(playerId: PlayerId) = delegate.onReleased(playerId)

    override fun getAllocator(playerId: PlayerId): Allocator =
        delegate.getAllocator(playerId)

    override fun getBackBufferDurationUs(playerId: PlayerId): Long =
        delegate.getBackBufferDurationUs(playerId)

    override fun retainBackBufferFromKeyframe(playerId: PlayerId): Boolean =
        delegate.retainBackBufferFromKeyframe(playerId)

    override fun shouldStartPlayback(parameters: LoadControl.Parameters): Boolean =
        delegate.shouldStartPlayback(parameters)

    override fun shouldContinuePreloading(
        playerId: PlayerId,
        timeline: Timeline,
        mediaPeriodId: MediaSource.MediaPeriodId,
        bufferedDurationUs: Long,
    ): Boolean =
        delegate.shouldContinuePreloading(playerId, timeline, mediaPeriodId, bufferedDurationUs)

    internal companion object {
        /// Cinq secondes : assez pour ne pas repartir en mise en mémoire tampon
        /// à chaque seconde lue, assez peu pour que le dépassement de la cible
        /// reste borné — 60 Mo au pire sur un remux 4K à 100 Mbit/s.
        const val DEFAULT_FLOOR_US = 5_000_000L

        fun shouldLoad(
            delegateWants: Boolean,
            bufferedDurationUs: Long,
            floorUs: Long,
            heapHasHeadroom: () -> Boolean,
        ): Boolean {
            if (delegateWants) return true
            if (bufferedDurationUs >= floorUs) return false
            return heapHasHeadroom()
        }

        /// Le même critère que `DefaultLoadControl` applique à
        /// `prioritizeTimeOverSizeThresholds` : le tas peut encore grandir, ou il
        /// lui reste au moins 4 % de libre.
        fun javaHeapHasHeadroom(): Boolean {
            val runtime = Runtime.getRuntime()
            val max = runtime.maxMemory()
            return runtime.totalMemory() < max || runtime.freeMemory() >= max / 25
        }
    }
}
