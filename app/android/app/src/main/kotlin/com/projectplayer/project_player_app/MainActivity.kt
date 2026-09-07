package com.projectplayer.project_player_app

import android.app.ActivityManager
import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.Display
import kotlin.math.abs
import kotlin.math.roundToInt
import androidx.core.view.WindowCompat
import androidx.lifecycle.Lifecycle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /// The channel, kept so the activity can talk back — picture-in-picture is
    /// entered and left by the system, not by Dart, and the interface has to
    /// hear about it.
    private var device: MethodChannel? = null

    /// The shape of the film, when Dart has asked for picture-in-picture.
    ///
    /// Null means "do not". Holding it here rather than asking Dart at the last
    /// moment is what makes the feature work at all: `onUserLeaveHint` is the
    /// one instant where the window may be created, and a round trip to Dart
    /// would land after it.
    private var pictureInPicture: Rational? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        device = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEVICE_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTelevision" -> result.success(isTelevision())
                    "deviceName" -> result.success(deviceName())
                    "memoryProfile" -> result.success(memoryProfile())
                    "matchRefreshRate" -> {
                        val fps = call.argument<Double>("fps") ?: 0.0
                        result.success(matchRefreshRate(fps))
                    }
                    "releaseRefreshRate" -> {
                        releaseRefreshRate()
                        result.success(null)
                    }
                    "supportsPictureInPicture" ->
                        result.success(supportsPictureInPicture())
                    "setPictureInPicture" -> {
                        val width = call.argument<Int>("width") ?: 0
                        val height = call.argument<Int>("height") ?: 0
                        setPictureInPicture(width, height)
                        result.success(supportsPictureInPicture())
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    // --- Picture-in-picture -------------------------------------------------

    /// Whether this device can put a film in a corner of the home screen.
    ///
    /// A television cannot — Android TV has its own idea of it, and the chrome
    /// here is not built for it — and neither can a device that simply does not
    /// carry the feature.
    private fun supportsPictureInPicture(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !isTelevision() &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /// Arms or disarms the little window, and says what shape it should be.
    ///
    /// A width or height of zero disarms it: leaving the player, or a film that
    /// has not said how big it is yet.
    private fun setPictureInPicture(width: Int, height: Int) {
        if (!supportsPictureInPicture()) return
        pictureInPicture =
            if (width > 0 && height > 0) Rational(width, height) else null
        // From Android 12 the system enters on its own, on the same gesture
        // that goes home — which is what makes the picture fly into the corner
        // instead of blinking into it. Below that, `onUserLeaveHint` is the
        // only hook there is.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching { setPictureInPictureParams(pictureInPictureParams()) }
        }
    }

    private fun pictureInPictureParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
        pictureInPicture?.let { builder.setAspectRatio(it) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pictureInPicture != null)
        }
        return builder.build()
    }

    /// The user is leaving — home button, or the gesture that does the same.
    ///
    /// This is the only moment Android allows the window to be created, and it
    /// is why the shape is held in [pictureInPicture] rather than asked for
    /// now. On Android 12 and up the system has already done it.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return
        if (pictureInPicture == null || !supportsPictureInPicture()) return
        if (isInPictureInPictureMode) return
        runCatching { enterPictureInPictureMode(pictureInPictureParams()) }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        device?.invokeMethod(
            "pictureInPictureChanged",
            mapOf(
                "inPictureInPicture" to isInPictureInPictureMode,
                // Leaving the window while the activity is *not* coming back to
                // the front means it was closed, not restored. The two need
                // telling apart: one puts the interface back, the other has to
                // stop a film that no longer has anywhere to play.
                "closed" to (
                    !isInPictureInPictureMode &&
                        !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
                    ),
            ),
        )
    }

    /// Whether this build is running on a television.
    ///
    /// Three signals, because no single one covers the field. UI_MODE_TYPE_TELEVISION
    /// is the official answer and the one Google TV gives. FEATURE_LEANBACK catches
    /// boxes that report a normal UI mode but ship the TV launcher. The touchscreen
    /// check is the backstop for the cheap sticks and for Fire TV, which historically
    /// answered the first two inconsistently — and "no touchscreen on Android" is, in
    /// practice, a device driven by a remote.
    private fun isTelevision(): Boolean {
        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        if (uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) {
            return true
        }

        val pm = packageManager
        if (pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK)) return true
        if (pm.hasSystemFeature("android.software.leanback_only")) return true
        if (pm.hasSystemFeature("android.hardware.type.television")) return true

        return !pm.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)
    }

    /// Human-readable device label, shown on the phone that approves a pairing so
    /// the user can tell which screen is asking.
    private fun deviceName(): String {
        val model = Build.MODEL ?: ""
        val brand = (Build.BRAND ?: "").replaceFirstChar { it.uppercase() }
        return when {
            model.isEmpty() -> brand.ifEmpty { "Android TV" }
            model.startsWith(brand, ignoreCase = true) -> model
            brand.isEmpty() -> model
            else -> "$brand $model"
        }
    }

    /// What the player is allowed to spend on buffering.
    ///
    /// A streaming stick has between 1 and 2 GB of RAM for the whole system, an
    /// order of magnitude less than the desktops the playback buffers were sized
    /// against. Asking for a desktop's buffer there is not a slow player, it is
    /// a process the low-memory killer starts pressuring mid-film.
    ///
    /// `totalMemoryMb` is the device's physical RAM, not the app's heap limit:
    /// libmpv's demuxer cache is a native allocation and never touches the Dart
    /// heap, so the Java heap limit says nothing about it.
    private fun memoryProfile(): Map<String, Any> {
        val activityManager =
            getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val info = ActivityManager.MemoryInfo()
        activityManager?.getMemoryInfo(info)
        return mapOf(
            "totalMemoryMb" to (info.totalMem / (1024L * 1024L)).toInt(),
            "isLowRamDevice" to (activityManager?.isLowRamDevice ?: false),
        )
    }

    /// Asks the display for a refresh rate the content divides into evenly.
    ///
    /// A television is 60 Hz and a film is 23.976 fps. Sixty does not divide by
    /// twenty-four, so every second frame is held one vsync longer than its
    /// neighbour — the 3:2 cadence. Nothing is dropped and nothing is late; the
    /// picture simply moves in an uneven rhythm, which is what a pan across a
    /// landscape makes impossible to miss. No amount of decoder or buffer work
    /// removes it, because it is not a shortage of anything.
    ///
    /// The fix is the one every television player uses: ask the panel to run at
    /// a rate the content divides into — 24, 48 or 120 Hz for a 24 fps film —
    /// and let each frame be held for the same number of vsyncs as the last.
    ///
    /// Same resolution only. Picking the mode is ours; changing what the screen
    /// is showing at is not.
    ///
    /// Returns the refresh rate that was requested, or 0 when nothing matched —
    /// including on every device that is not a television, where taking over the
    /// display mode is not this app's business.
    private fun matchRefreshRate(fps: Double): Double {
        if (fps <= 0.0 || !isTelevision()) return 0.0
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return 0.0

        val display: Display = window?.decorView?.display ?: return 0.0
        val current = display.mode ?: return 0.0

        var best: Display.Mode? = null
        var bestMultiple = Int.MAX_VALUE
        for (mode in display.supportedModes) {
            if (mode.physicalWidth != current.physicalWidth) continue
            if (mode.physicalHeight != current.physicalHeight) continue

            val ratio = mode.refreshRate / fps
            val multiple = ratio.roundToInt()
            if (multiple < 1) continue
            // Within 0.5%: 59.94/23.976 is exactly 2.5 and must not match, while
            // 24.0 Hz against 23.976 fps content must.
            if (abs(ratio - multiple) > 0.005) continue

            // The lowest whole multiple is the calmest: at 24 Hz each frame is
            // one vsync, at 120 Hz it is five, and both are even — but the lower
            // one asks less of a panel that has to composite it.
            if (multiple < bestMultiple) {
                bestMultiple = multiple
                best = mode
            }
        }

        val chosen = best ?: return 0.0
        if (chosen.modeId == current.modeId) return chosen.refreshRate.toDouble()

        runOnUiThread {
            window.attributes = window.attributes.apply {
                preferredDisplayModeId = chosen.modeId
            }
        }
        return chosen.refreshRate.toDouble()
    }

    /// Hands the display back to the system's own choice. Called when the player
    /// closes: the menus are not 24 fps, and leaving the panel at a film's rate
    /// makes every scroll in the app judder instead.
    private fun releaseRefreshRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        runOnUiThread {
            window.attributes = window.attributes.apply {
                preferredDisplayModeId = 0
            }
        }
    }

    private companion object {
        const val DEVICE_CHANNEL = "onyx/device"
    }
}
