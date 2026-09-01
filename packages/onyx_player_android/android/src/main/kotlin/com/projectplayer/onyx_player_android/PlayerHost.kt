package com.projectplayer.onyx_player_android

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener

/// Un lecteur ExoPlayer et l'état que Dart en connaît.
///
/// La SurfaceView vit ailleurs (voir [PlayerSurfaceFactory]) et se rattache ici
/// par identifiant : le lecteur est créé avant que la vue n'existe, et il
/// survit à sa reconstruction — ce que Flutter fait librement dès qu'un parent
/// change de forme.
internal class PlayerInstance(
    val id: Long,
    context: Context,
    private val onStatusChanged: (OnyxPlayerStatus) -> Unit,
) {
    val player: ExoPlayer = ExoPlayer.Builder(context).build()

    /// Compteurs d'images du rendu vidéo. ExoPlayer ne les expose que par
    /// notification, donc on les accumule ici pour pouvoir les lire à la
    /// demande — c'est le chiffre qui répond à « est-ce que c'est fluide ».
    private var droppedFrames: Long = 0
    private var renderedFrames: Long = 0

    private var lastErrorKind: OnyxPlayerErrorKind? = null
    private var lastErrorMessage: String? = null

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) = emit()

        override fun onIsPlayingChanged(isPlaying: Boolean) = emit()

        override fun onVideoSizeChanged(videoSize: VideoSize) = emit()

        override fun onPlayerError(error: PlaybackException) {
            lastErrorKind = classify(error)
            lastErrorMessage = error.errorCodeName + ": " + (error.message ?: "")
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

    init {
        player.addListener(listener)
        player.addAnalyticsListener(analytics)
    }

    fun open(url: String, startPositionMs: Long) {
        // Position posée avant la préparation : ExoPlayer l'applique au
        // chargement plutôt que comme un saut après coup, donc rien n'est mis
        // en mémoire tampon au début du fichier pour être jeté aussitôt.
        player.setMediaItem(MediaItem.fromUri(url), startPositionMs)
        player.prepare()
    }

    fun status(): OnyxPlayerStatus {
        val size = player.videoSize
        return OnyxPlayerStatus(
            playerId = id,
            state = when (player.playbackState) {
                Player.STATE_BUFFERING -> OnyxPlaybackState.BUFFERING
                Player.STATE_READY -> OnyxPlaybackState.READY
                Player.STATE_ENDED -> OnyxPlaybackState.ENDED
                else -> OnyxPlaybackState.IDLE
            },
            isPlaying = player.isPlaying,
            positionMs = player.currentPosition.coerceAtLeast(0),
            // ExoPlayer rend TIME_UNSET tant qu'il ne sait pas ; Dart attend 0.
            durationMs = if (player.duration == androidx.media3.common.C.TIME_UNSET) {
                0
            } else {
                player.duration.coerceAtLeast(0)
            },
            bufferedPositionMs = player.bufferedPosition.coerceAtLeast(0),
            videoSize = if (size.width > 0 && size.height > 0) {
                OnyxVideoSize(size.width.toLong(), size.height.toLong())
            } else {
                null
            },
            errorKind = lastErrorKind,
            errorMessage = lastErrorMessage,
        )
    }

    fun stats(): OnyxPlaybackStats =
        OnyxPlaybackStats(droppedFrames = droppedFrames, renderedFrames = renderedFrames)

    fun release() {
        player.removeListener(listener)
        player.removeAnalyticsListener(analytics)
        player.release()
    }

    private fun emit() = onStatusChanged(status())

    private companion object {
        /// Ce que Dart doit savoir de l'erreur : est-ce que ce fichier est
        /// illisible ici — auquel cas il faut le transcoder — ou est-ce que la
        /// source a lâché, auquel cas réessayer a un sens.
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
/// déjà les appels de l'API hôte. Le seul chemin qui pourrait venir d'ailleurs
/// est la position périodique, qui est postée sur ce même Handler.
internal class PlayerHost(private val context: Context) : OnyxPlayerApi {
    private val players = mutableMapOf<Long, PlayerInstance>()
    private var nextId = 1L

    private val handler = Handler(Looper.getMainLooper())
    private var sink: PigeonEventSink<OnyxPlayerStatus>? = null

    /// La position n'est pas un événement chez ExoPlayer : elle avance toute
    /// seule et personne ne prévient. Quatre fois par seconde suffit pour une
    /// barre de progression, et c'est vingt fois moins que ce que coûtait le
    /// flux de position de mpv, que le lecteur limitait déjà côté Dart.
    private val ticker = object : Runnable {
        override fun run() {
            if (players.isEmpty()) return
            for (instance in players.values) {
                if (instance.player.isPlaying) emit(instance.status())
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
        val instance = PlayerInstance(id, context) { status -> emit(status) }
        players[id] = instance
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

    override fun open(playerId: Long, url: String, startPositionMs: Long) {
        players[playerId]?.open(url, startPositionMs)
    }

    override fun play(playerId: Long) {
        players[playerId]?.player?.play()
    }

    override fun pause(playerId: Long) {
        players[playerId]?.player?.pause()
    }

    override fun seekTo(playerId: Long, positionMs: Long) {
        players[playerId]?.player?.seekTo(positionMs)
    }

    override fun status(playerId: Long): OnyxPlayerStatus =
        players[playerId]?.status() ?: OnyxPlayerStatus(
            playerId = playerId,
            state = OnyxPlaybackState.IDLE,
            isPlaying = false,
            positionMs = 0,
            durationMs = 0,
            bufferedPositionMs = 0,
        )

    override fun stats(playerId: Long): OnyxPlaybackStats =
        players[playerId]?.stats() ?: OnyxPlaybackStats(droppedFrames = 0, renderedFrames = 0)

    /// Détruit ce qui reste quand le moteur Flutter s'en va. Sans ça, un
    /// ExoPlayer survivrait à l'activité avec son décodeur et sa connexion.
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
