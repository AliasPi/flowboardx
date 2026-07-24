import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeyProperties = Properties()
val releaseKeyFile = rootProject.file("key.properties")
if (releaseKeyFile.exists()) {
    releaseKeyFile.inputStream().use(releaseKeyProperties::load)
}

val requiredReleaseKeyProperties =
    listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val releaseStorePath = releaseKeyProperties.getProperty("storeFile")
val releaseStoreFile = releaseStorePath?.let { file(it) }
val releaseSigningConfigured =
    releaseKeyFile.isFile &&
        requiredReleaseKeyProperties.all {
            !releaseKeyProperties.getProperty(it).isNullOrBlank()
        } &&
        releaseStoreFile?.isFile == true
val releaseTaskRequested = gradle.startParameter.taskNames.any { requestedTask ->
    val taskName = requestedTask.substringAfterLast(':').lowercase()
    taskName.contains("release") ||
        taskName == "assemble" ||
        taskName == "build" ||
        taskName == "bundle"
}

if (releaseTaskRequested && !releaseSigningConfigured) {
    throw GradleException(
        "FlowboardX release signing is not configured. " +
            "Create android/key.properties with storeFile, storePassword, " +
            "keyAlias and keyPassword before building a release. " +
            "For an installable local test build use: " +
            "flutter build apk --debug --split-per-abi",
    )
}

android {
    namespace = "de.flowboardx.flowboard_x"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Keep this ID stable after the first store publication.
        applicationId = "de.flowboardx.flowboard_x"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }


    if (releaseSigningConfigured) {
        signingConfigs {
            create("release") {
                keyAlias = releaseKeyProperties.getProperty("keyAlias")
                keyPassword = releaseKeyProperties.getProperty("keyPassword")
                storeFile = requireNotNull(releaseStoreFile)
                storePassword = releaseKeyProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core:1.17.0")
    // The Latin model is linked into the APK and is immediately available
    // offline. Do not replace this with the play-services variant: that one
    // downloads its model at runtime.
    implementation("com.google.mlkit:text-recognition:16.0.1")
}

// Guard the direct `flutter build apk/appbundle` path as well as the release
// wrapper. Resolving the Maven artifact alone is not sufficient: a future AGP
// packaging or shrinker change must never produce an APK without the model.
val verifyBundledLatinRecognitionModel =
    tasks.register("verifyBundledLatinRecognitionModel") {
        dependsOn("mergeReleaseAssets")
        doLast {
            val modelDirectory =
                layout.buildDirectory
                    .dir(
                        "intermediates/assets/release/" +
                            "mergeReleaseAssets/mlkit-google-ocr-models",
                    ).get().asFile
            val modelFiles =
                if (modelDirectory.isDirectory) {
                    modelDirectory.walkTopDown().filter { it.isFile }.toList()
                } else {
                    emptyList()
                }
            val relativePaths =
                modelFiles.map {
                    it.relativeTo(modelDirectory).invariantSeparatorsPath
                }
            val requiredSuffixes =
                listOf(
                    "gocr/gocr_models/line_recognition_legacy_mobile/" +
                        "Latn_ctc/optical/lstm_model.fb",
                    "gocr/gocr_models/line_recognition_legacy_mobile/" +
                        "tflite_langid.tflite",
                    "gocr/layout/line_clustering_custom_ops/model.tflite",
                    "taser/detector/" +
                        "rpn_text_detector_mobile_space_to_depth_quantized_mbv2_v1.tflite",
                )
            val modelBytes = modelFiles.sumOf { it.length() }
            val missing =
                requiredSuffixes.filter { required ->
                    relativePaths.none { it.endsWith(required) }
                }
            if (modelFiles.size < 18 || modelBytes < 1_200_000L || missing.isNotEmpty()) {
                throw GradleException(
                    "Bundled Latin recognition model is incomplete: " +
                        "${modelFiles.size} files, $modelBytes bytes, " +
                        "missing=${missing.joinToString()}",
                )
            }
        }
    }

tasks.matching {
    it.name == "assembleRelease" ||
        it.name == "bundleRelease" ||
        it.name == "packageRelease"
}.configureEach {
    dependsOn(verifyBundledLatinRecognitionModel)
}
