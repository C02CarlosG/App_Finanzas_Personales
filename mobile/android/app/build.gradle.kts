import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---- Firma de release (docs/release-android.md) ----
// La llave NUNCA vive en el repositorio. Se lee de android/key.properties (local, ignorado por git) o de variables
// de entorno (CI); las variables tienen prioridad. Un build release sin llave FALLA: no se firma con la de depuración.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun signingValue(property: String, env: String): String? =
    System.getenv(env)?.takeIf { it.isNotBlank() } ?: keyProperties.getProperty(property)?.takeIf { it.isNotBlank() }

val releaseStoreFile = signingValue("storeFile", "ANDROID_KEYSTORE_FILE")
val releaseStorePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
val hasReleaseKey = listOf(releaseStoreFile, releaseStorePassword, releaseKeyAlias, releaseKeyPassword).all { it != null }

// Solo para `flutter run --release` en tu equipo: -PallowDebugSigning=true (o ALLOW_DEBUG_SIGNING=1) firma con la
// llave de depuración. Ese APK no sirve para distribuir.
val allowDebugSigning = project.findProperty("allowDebugSigning") == "true" || System.getenv("ALLOW_DEBUG_SIGNING") == "1"

android {
    namespace = "mx.finanzaspersonales.finanzas_personales"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // El identificador no se puede cambiar después de publicar la app.
        applicationId = "mx.finanzaspersonales.finanzas_personales"
        // flutter_secure_storage y SQLite nativo requieren API 24+.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // versionCode y versionName salen de `version:` en pubspec.yaml; el CI de release pasa --build-number.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasReleaseKey) {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (hasReleaseKey) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }
}

// Corta el build release antes de producir un APK/AAB firmado con la llave equivocada.
gradle.taskGraph.whenReady {
    val buildsRelease = allTasks.any { it.path.startsWith(":app:") && it.name.matches(Regex("(assemble|bundle|package)Release")) }
    if (buildsRelease && !hasReleaseKey && !allowDebugSigning) {
        throw GradleException(
            "Falta la llave de firma de release. Define android/key.properties (storeFile, storePassword, keyAlias, " +
                "keyPassword) o las variables ANDROID_KEYSTORE_FILE, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS y " +
                "ANDROID_KEY_PASSWORD. Detalle en docs/release-android.md. Para una prueba local que NO se distribuye: " +
                "-PallowDebugSigning=true."
        )
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
