package com.projectplayer.onyx_player_android

import android.content.Context
import android.media.MediaCodecList
import android.os.Handler
import android.os.Looper
import android.view.SurfaceView
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.text.CueGroup
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.analytics.AnalyticsListener
import java.io.File

/// Un lecteur ExoPlayer, et l'état que Dart en connaît.
///
/// L'instance est construite **paresseusement**, à la première ouverture : les
/// tampons de `DefaultLoadControl` se posent à la construction et ne se
/// changent plus après, alors que l'app les choisit selon qu'elle lit le
/// fichier directement ou une session transcodée. La reconstruire quand ils
/// changent est sans conséquence — ce moment est déjà un rechargement complet.
///
/// La `SurfaceView` vit ailleurs (voir [PlayerSurfaceFactory]) et se rattache
/// ici par identifiant. Elle est mémorisée pour être re-branchée après une
/// reconstruction, sinon l'image partirait dans le vide.
internal class PlayerInstance(
    val id: Long,
    private val context: Context,
    private val onStatusChanged: (OnyxPlayerStatus) -> Unit,
) {
    private var player: ExoPlayer? = null
    private var tuning: OnyxLoadTuning? = null
    private var surfaceView: SurfaceView? = null

    private var droppedFrames: Long = 0
    private var renderedFrames: Long = 0

    private var lastErrorKind: OnyxPlayerErrorKind? = null
    private var lastErrorMessage: String? = null
    private var cues: List<String> = emptyList()
    private var forcedDurationMs: Long = 0
    private var exactSeek: Boolean = true
    private var preferredAudioLanguages: List<String> = emptyList()

    /// Le WebVTT posé à côté du média, à ré-appliquer si on rouvre.
    private var externalSubtitle: MediaItem.SubtitleConfiguration? = null
    private var subtitleFile: File? = null
    private var currentUrl: String? = null

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) = emit()
        override fun onIsPlayingChanged(isPlaying: Boolean) = emit()
        override fun onVideoSizeChanged(videoSize: VideoSize) = emit()
        override fun onTracksChanged(tracks: Tracks) = emit()

        override fun onCues(cueGroup: CueGroup) {
            // Seul le texte remonte : les pistes bitmap passent par le
            // transcodage, qui les incruste dans l'image (voir l'ADR-0009).
            cues = cueGroup.cues.mapNotNull { it.text?.toString() }
                .filter { it.isNotBlank() }
            emit()
        }

        override fun onPlayerError(error: PlaybackException) {
            lastErrorKind = classify(error)
            lastErrorMessage = "${error.errorCodeName}: ${error.message ?: ""}"
            emit()
        }

        override fun onPlayerErrorChanged(error: PlaybackException?) {
            if (error == null) {
                lastErrorKind = null
                lastErrorMessage = null
            }
        }
    }

    private val analytics = object : AnalyticsListener {
        override fun onDroppedVideoFrames(
            eventTime: AnalyticsListener.EventTime,
            droppedFrames: Int,
            elapsedMs: Long,
        ) {
            this@PlayerInstance.droppedFrames += droppedFrames
        }

        override fun onVideoFrameProcessingOffset(
            eventTime: AnalyticsListener.EventTime,
            totalProcessingOffsetUs: Long,
            frameCount: Int,
        ) {
            renderedFrames += frameCount
        }
    }

    // --- Cycle de vie -------------------------------------------------------

    private fun ensurePlayer(): ExoPlayer {
        player?.let { return it }

        val load = DefaultLoadControl.Builder().apply {
            tuning?.let { t ->
                setBufferDurationsMs(
                    t.minBufferMs.toInt(),
                    t.maxBufferMs.toInt(),
                    t.bufferForPlaybackMs.toInt(),
                    // Ce qu'il faut avoir remis en mémoire après une coupure
                    // avant de repartir. Le même que le démarrage : une reprise
                    // n'a pas de raison d'être plus prudente qu'un départ.
                    t.bufferForPlaybackMs.toInt(),
                )
                setBackBuffer(t.backBufferMs.toInt(), true)
            }
        }.build()

        // Le repli stéréo d'Onyx s'insère dans la chaîne audio du puits. Il
        // ne s'active que sur une entrée à plus de deux canaux — voir
        // [DialogueForwardDownmix].
        val renderers = object : DefaultRenderersFactory(context) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioOutputPlaybackParams: Boolean,
            ): AudioSink = DefaultAudioSink.Builder(context)
                .setEnableFloatOutput(enableFloatOutput)
                .setEnableAudioOutputPlaybackParameters(enableAudioOutputPlaybackParams)
                .setAudioProcessors(arrayOf(DialogueForwardDownmix()))
                .build()
        }

        val created = ExoPlayer.Builder(context)
            .setLoadControl(load)
            .setRenderersFactory(renderers)
            .build()
        created.addListener(listener)
        created.addAnalyticsListener(analytics)
        created.setSeekParameters(
            if (exactSeek) SeekParameters.EXACT else SeekParameters.CLOSEST_SYNC,
        )
        applyPreferredLanguages(created)
        surfaceView?.let { created.setVideoSurfaceView(it) }
        player = created
        return created
    }

    fun attachSurface(view: SurfaceView) {
        surfaceView = view
        player?.setVideoSurfaceView(view)
    }

    fun detachSurface() {
        surfaceView = null
        player?.clearVideoSurface()
    }

    fun applyTuning(next: OnyxLoadTuning) {
        val current = tuning
        val same = current != null &&
            current.minBufferMs == next.minBufferMs &&
            current.maxBufferMs == next.maxBufferMs &&
            current.bufferForPlaybackMs == next.bufferForPlaybackMs &&
            current.backBufferMs == next.backBufferMs
        tuning = next
        if (same) return
        // Les tampons ne se changent pas sur une instance construite. La
        // reconstruire ici est gratuit : ce point du code est toujours suivi
        // d'une ouverture.
        releasePlayer()
    }

    fun open(url: String, startPositionMs: Long, play: Boolean) {
        currentUrl = url
        val exo = ensurePlayer()
        exo.setMediaItem(buildMediaItem(url), startPositionMs)
        exo.prepare()
        exo.playWhenReady = play
    }

    private fun buildMediaItem(url: String): MediaItem {
        val builder = MediaItem.Builder().setUri(url)
        externalSubtitle?.let { builder.setSubtitleConfigurations(listOf(it)) }
        return builder.build()
    }

    fun play() = withPlayer { it.play() }
    fun pause() = withPlayer { it.pause() }
    fun seekTo(positionMs: Long) = withPlayer { it.seekTo(positionMs) }

    fun setVolume(volume: Double) = withPlayer {
        // L'app parle en 0..100, comme mpv ; ExoPlayer en 0..1.
        it.volume = (volume / 100.0).coerceIn(0.0, 1.0).toFloat()
    }

    fun setRate(rate: Double) = withPlayer { it.setPlaybackSpeed(rate.toFloat()) }

    fun setExactSeek(exact: Boolean) {
        exactSeek = exact
        player?.setSeekParameters(
            if (exact) SeekParameters.EXACT else SeekParameters.CLOSEST_SYNC,
        )
    }

    fun overrideDuration(totalMs: Long) {
        forcedDurationMs = totalMs
        emit()
    }

    fun setPreferredAudioLanguages(priorities: List<String>) {
        preferredAudioLanguages = priorities
        player?.let { applyPreferredLanguages(it) }
    }

    private fun applyPreferredLanguages(exo: ExoPlayer) {
        exo.trackSelectionParameters = exo.trackSelectionParameters
            .buildUpon()
            .setPreferredAudioLanguages(*preferredAudioLanguages.toTypedArray())
            .build()
    }

    fun selectAudioTrack(trackId: String) = selectTrack(C.TRACK_TYPE_AUDIO, trackId)

    fun selectSubtitleTrack(trackId: String?) {
        val exo = player ?: return
        if (trackId == null) {
            exo.trackSelectionParameters = exo.trackSelectionParameters
                .buildUpon()
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
                .build()
            return
        }
        exo.trackSelectionParameters = exo.trackSelectionParameters
            .buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            .build()
        selectTrack(C.TRACK_TYPE_TEXT, trackId)
    }

    /// [trackId] est `groupe:piste`, la forme que [tracksOf] produit — ExoPlayer
    /// n'a pas d'identifiant stable à lui, et les indices sont ce qu'il faut
    /// pour lui redemander la même.
    private fun selectTrack(trackType: Int, trackId: String) {
        val exo = player ?: return
        val groups = exo.currentTracks.groups.filter { it.type == trackType }
        val (groupIndex, trackIndex) = parseTrackId(trackId) ?: return
        val group = groups.getOrNull(groupIndex) ?: return
        exo.trackSelectionParameters = exo.trackSelectionParameters
            .buildUpon()
            .setOverrideForType(
                TrackSelectionOverride(group.mediaTrackGroup, trackIndex),
            )
            .build()
    }

    fun setExternalSubtitle(vtt: String?, language: String?, title: String?) {
        subtitleFile?.delete()
        subtitleFile = null

        if (vtt == null || vtt.isBlank()) {
            externalSubtitle = null
            cues = emptyList()
            reloadKeepingPosition()
            return
        }

        // ExoPlayer charge un sous-titre par URI, pas par contenu ; le
        // contrôleur, lui, a déjà le texte en main (le serveur a recalé les
        // temps sur l'offset du flux). Un fichier temporaire est le pont.
        val file = File.createTempFile("onyx-sub-", ".vtt", context.cacheDir)
        file.writeText(vtt)
        subtitleFile = file
        externalSubtitle = MediaItem.SubtitleConfiguration
            .Builder(android.net.Uri.fromFile(file))
            .setMimeType(MimeTypes.TEXT_VTT)
            .setLanguage(language)
            .setLabel(title)
            .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
            .build()
        reloadKeepingPosition()
    }

    /// Rouvre le média avec la configuration de sous-titres courante, sans
    /// perdre la place. Poser un sous-titre externe fait partie de l'item, donc
    /// il n'y a pas d'autre moyen que de le reconstruire.
    private fun reloadKeepingPosition() {
        val exo = player ?: return
        val url = currentUrl ?: return
        val at = exo.currentPosition
        val wasPlaying = exo.playWhenReady
        exo.setMediaItem(buildMediaItem(url), at)
        exo.prepare()
        exo.playWhenReady = wasPlaying
    }

    // --- Lecture d'état -----------------------------------------------------

    fun status(): OnyxPlayerStatus {
        val exo = player
        val size = exo?.videoSize
        val reported = exo?.duration ?: C.TIME_UNSET
        val duration = when {
            forcedDurationMs > 0 -> forcedDurationMs
            reported == C.TIME_UNSET -> 0
            else -> reported.coerceAtLeast(0)
        }
        return OnyxPlayerStatus(
            playerId = id,
            state = when (exo?.playbackState) {
                Player.STATE_BUFFERING -> OnyxPlaybackState.BUFFERING
                Player.STATE_READY -> OnyxPlaybackState.READY
                Player.STATE_ENDED -> OnyxPlaybackState.ENDED
                else -> OnyxPlaybackState.IDLE
            },
            isPlaying = exo?.isPlaying ?: false,
            positionMs = exo?.currentPosition?.coerceAtLeast(0) ?: 0,
            durationMs = duration,
            bufferedPositionMs = exo?.bufferedPosition?.coerceAtLeast(0) ?: 0,
            audioTracks = tracksOf(C.TRACK_TYPE_AUDIO),
            subtitleTracks = tracksOf(C.TRACK_TYPE_TEXT),
            subtitleCues = cues,
            videoSize = if (size != null && size.width > 0 && size.height > 0) {
                OnyxVideoSize(size.width.toLong(), size.height.toLong())
            } else {
                null
            },
            selectedAudioTrackId = selectedIdOf(C.TRACK_TYPE_AUDIO),
            selectedSubtitleTrackId = selectedIdOf(C.TRACK_TYPE_TEXT),
            errorKind = lastErrorKind,
            errorMessage = lastErrorMessage,
        )
    }

    private fun tracksOf(trackType: Int): List<OnyxTrack> {
        val exo = player ?: return emptyList()
        val out = mutableListOf<OnyxTrack>()
        exo.currentTracks.groups
            .filter { it.type == trackType }
            .forEachIndexed { groupIndex, group ->
                for (i in 0 until group.length) {
                    val format = group.getTrackFormat(i)
                    out.add(
                        OnyxTrack(
                            id = "$groupIndex:$i",
                            title = format.label,
                            language = format.language,
                        ),
                    )
                }
            }
        return out
    }

    private fun selectedIdOf(trackType: Int): String? {
        val exo = player ?: return null
        exo.currentTracks.groups
            .filter { it.type == trackType }
            .forEachIndexed { groupIndex, group ->
                for (i in 0 until group.length) {
                    if (group.isTrackSelected(i)) return "$groupIndex:$i"
                }
            }
        return null
    }

    fun stats(): OnyxPlaybackStats =
        OnyxPlaybackStats(droppedFrames = droppedFrames, renderedFrames = renderedFrames)

    // --- Fin ---------------------------------------------------------------

    private fun releasePlayer() {
        player?.let {
            it.removeListener(listener)
            it.removeAnalyticsListener(analytics)
            it.release()
        }
        player = null
    }

    fun release() {
        releasePlayer()
        subtitleFile?.delete()
        subtitleFile = null
        surfaceView = null
    }

    private inline fun withPlayer(action: (ExoPlayer) -> Unit) {
        player?.let(action)
    }

    private fun emit() = onStatusChanged(status())

    private companion object {
        fun parseTrackId(id: String): Pair<Int, Int>? {
            val parts = id.split(':')
            if (parts.size != 2) return null
            val group = parts[0].toIntOrNull() ?: return null
            val track = parts[1].toIntOrNull() ?: return null
            return group to track
        }

        /// Ce que Dart doit savoir de l'erreur : ce fichier est-il illisible ici
        /// — auquel cas il faut le transcoder — ou la source a-t-elle lâché,
        /// auquel cas réessayer a un sens.
        fun classify(error: PlaybackException): OnyxPlayerErrorKind =
            when (error.errorCode) {
                PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
                PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
                PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
                PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
                PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
                -> OnyxPlayerErrorKind.UNSUPPORTED

                PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
                PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
                PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND,
                PlaybackException.ERROR_CODE_IO_NO_PERMISSION,
                PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE,
                -> OnyxPlayerErrorKind.SOURCE

                else -> OnyxPlayerErrorKind.UNKNOWN
            }
    }
}

/// Le côté Kotlin du contrat, et le propriétaire des lecteurs vivants.
///
/// Tout passe par le thread principal : ExoPlayer l'exige, et Pigeon y délivre
/// déjà les appels de l'API hôte.
internal class PlayerHost(private val context: Context) : OnyxPlayerApi {
    private val players = mutableMapOf<Long, PlayerInstance>()
    private var nextId = 1L

    private val handler = Handler(Looper.getMainLooper())
    private var sink: PigeonEventSink<OnyxPlayerStatus>? = null

    /// La position n'est pas un événement chez ExoPlayer : elle avance toute
    /// seule et personne ne prévient. Quatre fois par seconde suffit pour une
    /// barre de progression.
    private val ticker = object : Runnable {
        override fun run() {
            if (players.isEmpty()) return
            for (instance in players.values) {
                if (instance.status().isPlaying) emit(instance.status())
            }
            handler.postDelayed(this, POSITION_INTERVAL_MS)
        }
    }

    fun attachSink(sink: PigeonEventSink<OnyxPlayerStatus>?) {
        this.sink = sink
    }

    fun playerFor(id: Long): PlayerInstance? = players[id]

    override fun create(): Long {
        val id = nextId++
        players[id] = PlayerInstance(id, context) { status -> emit(status) }
        if (players.size == 1) {
            handler.removeCallbacks(ticker)
            handler.postDelayed(ticker, POSITION_INTERVAL_MS)
        }
        return id
    }

    override fun release(playerId: Long) {
        players.remove(playerId)?.release()
        if (players.isEmpty()) handler.removeCallbacks(ticker)
    }

    override fun open(playerId: Long, url: String, startPositionMs: Long, play: Boolean) {
        players[playerId]?.open(url, startPositionMs, play)
    }

    override fun play(playerId: Long) { players[playerId]?.play() }
    override fun pause(playerId: Long) { players[playerId]?.pause() }
    override fun seekTo(playerId: Long, positionMs: Long) {
        players[playerId]?.seekTo(positionMs)
    }
    override fun setVolume(playerId: Long, volume: Double) {
        players[playerId]?.setVolume(volume)
    }
    override fun setRate(playerId: Long, rate: Double) {
        players[playerId]?.setRate(rate)
    }
    override fun setPreferredAudioLanguages(playerId: Long, priorities: List<String>) {
        players[playerId]?.setPreferredAudioLanguages(priorities)
    }
    override fun selectAudioTrack(playerId: Long, trackId: String) {
        players[playerId]?.selectAudioTrack(trackId)
    }
    override fun selectSubtitleTrack(playerId: Long, trackId: String?) {
        players[playerId]?.selectSubtitleTrack(trackId)
    }
    override fun setExternalSubtitle(
        playerId: Long,
        vttContent: String?,
        language: String?,
        title: String?,
    ) {
        players[playerId]?.setExternalSubtitle(vttContent, language, title)
    }
    override fun setExactSeek(playerId: Long, exact: Boolean) {
        players[playerId]?.setExactSeek(exact)
    }
    override fun overrideDuration(playerId: Long, totalMs: Long) {
        players[playerId]?.overrideDuration(totalMs)
    }
    override fun applyTuning(playerId: Long, tuning: OnyxLoadTuning) {
        players[playerId]?.applyTuning(tuning)
    }

    override fun status(playerId: Long): OnyxPlayerStatus =
        players[playerId]?.status() ?: OnyxPlayerStatus(
            playerId = playerId,
            state = OnyxPlaybackState.IDLE,
            isPlaying = false,
            positionMs = 0,
            durationMs = 0,
            bufferedPositionMs = 0,
            audioTracks = emptyList(),
            subtitleTracks = emptyList(),
            subtitleCues = emptyList(),
        )

    override fun stats(playerId: Long): OnyxPlaybackStats =
        players[playerId]?.stats() ?: OnyxPlaybackStats(0, 0)

    /// Ce que la puce sait décoder, demandé une fois.
    ///
    /// mpv décodait DTS-HD et TrueHD en logiciel ; ExoPlayer n'a pas de
    /// décodeur à lui. Répondre ici permet au contrôleur de choisir la lecture
    /// directe ou le transcodage **avant** d'ouvrir, au lieu d'échouer sous les
    /// yeux de l'utilisateur puis de se rattraper.
    override fun decodableAudioMimeTypes(): List<String> {
        val out = mutableSetOf<String>()
        try {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            for (info in list.codecInfos) {
                if (info.isEncoder) continue
                for (type in info.supportedTypes) {
                    if (type.startsWith("audio/")) out.add(type.lowercase())
                }
            }
        } catch (_: Exception) {
            // Une puce qui refuse de s'énumérer est traitée comme ne sachant
            // rien : le transcodage prend le relais, ce qui marche toujours.
        }
        return out.toList()
    }

    fun releaseAll() {
        handler.removeCallbacks(ticker)
        players.values.forEach { it.release() }
        players.clear()
        sink = null
    }

    private fun emit(status: OnyxPlayerStatus) {
        sink?.success(status)
    }

    private companion object {
        const val POSITION_INTERVAL_MS = 250L
    }
}
