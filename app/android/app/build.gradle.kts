import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing key. It never lives in the repo: locally it comes from
// android/key.properties, in CI the release workflow decodes a keystore out of
// the GitHub secrets into that same file.
//
// Absent the file we fall back to the debug key, so `flutter build apk
// --release` still works on a fresh checkout. That fallback is only good enough
// for a local test: Android refuses to update an app with an APK signed by a
// different key, and CI runners are disposable, so a debug-signed CI build
// would force users to uninstall before every release.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

// Les `--dart-define` de la commande Flutter, que son plugin Gradle transmet
// encodés en base64 dans la propriété `dart-defines`. Lus ici pour que le
// manifeste suive le même drapeau `STORE_BUILD` que le Dart
// (lib/utils/store_build.dart) : un seul interrupteur, pas deux à tenir
// d'accord. Voir l'ADR-0046.
val dartDefines: Map<String, String> =
    (project.findProperty("dart-defines") as String?)
        ?.split(",")
        ?.filter { it.isNotEmpty() }
        ?.associate {
            val pair = String(Base64.getDecoder().decode(it)).split("=", limit = 2)
            pair[0] to pair.getOrElse(1) { "" }
        }
        ?: emptyMap()
val storeBuild = dartDefines["STORE_BUILD"] == "true"

android {
    namespace = "com.tsuky.onyx"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Google Play refuse `REQUEST_INSTALL_PACKAGES` à une app qui n'est pas
    // un gestionnaire de paquets. Le manifeste de `src/store/` le retire, et
    // ne se superpose qu'au build release d'un build store.
    if (storeBuild) {
        sourceSets.getByName("release").manifest.srcFile("src/store/AndroidManifest.xml")
    }

    defaultConfig {
        // Le même identifiant que sur iOS, tvOS et macOS. Définitif une fois
        // l'app publiée sur Google Play.
        applicationId = "com.tsuky.onyx"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 23 is the barcode scanner's floor (mobile_scanner / ML Kit), and the
        // refresh-rate matching in MainActivity already needs M anyway.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                // Resolved against android/, so key.properties can point at a
                // keystore sitting next to it without an absolute path.
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
}
