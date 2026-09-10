group = "com.projectplayer.onyx_player_android"
version = "1.0-SNAPSHOT"

// Une seule version pour tous les modules media3 : les mélanger produit des
// erreurs de lien que rien n'annonce à la compilation.
val media3Version = "1.11.0"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.projectplayer.onyx_player_android"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        // Aligné sur l'app, qui est à 23 depuis le scanner de QR codes.
        minSdk = 23
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        // Media3 marque une partie de son API `@UnstableApi`, qui est un
        // `@RequiresOptIn` de niveau ERREUR : `DefaultLoadControl` et
        // `SeekParameters` ne compilent pas sans ça. Posé une fois pour le
        // module plutôt qu'annoté classe par classe — tout ce module est du
        // Media3, la question ne se pose pas fichier par fichier.
        freeCompilerArgs.add("-opt-in=androidx.media3.common.util.UnstableApi")
    }
}

dependencies {
    // Le lecteur. `exoplayer` tire le noyau, les extracteurs et le rendu ;
    // rien d'autre n'est nécessaire tant qu'on lit du HTTP progressif et du
    // HLS, ce que couvre `exoplayer-hls`.
    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-exoplayer-hls:$media3Version")
    // Un décodeur audio FFmpeg pour ExoPlayer, qui n'a sinon que MediaCodec :
    // sans lui, TrueHD, DTS et (E-)AC-3 sont muets sur tout appareil qui n'a ni
    // décodeur matériel ni passthrough vers un ampli. La version suit media3
    // (`<media3>-<nextlib>`), et doit la suivre à chaque montée.
    implementation("io.github.anilbeesetti:nextlib-media3ext:$media3Version-0.15.0")

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
