package com.projectplayer.project_player_app

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTelevision" -> result.success(isTelevision())
                    "deviceName" -> result.success(deviceName())
                    else -> result.notImplemented()
                }
            }
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

    private companion object {
        const val DEVICE_CHANNEL = "onyx/device"
    }
}
