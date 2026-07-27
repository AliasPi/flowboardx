import java.io.File
import java.security.MessageDigest
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

    androidResources {
        // The ONNX model is already a compact binary. Keeping it uncompressed
        // avoids a second full-size decompression buffer during session start.
        noCompress += "onnx"
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
    // CPU inference for the fully bundled PaddleOCR handwriting model.
    // ONNX Runtime is MIT licensed and ships all Android ABIs used by Flutter.
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.23.2")
    // The Latin model is linked into the APK and is immediately available
    // offline as a defensive fallback when ONNX Runtime cannot start on a
    // particular device. Do not replace this with the play-services variant:
    // that one downloads its model at runtime.
    implementation("com.google.mlkit:text-recognition:16.0.1")
    testImplementation("junit:junit:4.13.2")
}

// Guard the direct `flutter build apk/appbundle` path as well as the release
// wrapper. Resolving the Maven artifact alone is not sufficient: a future AGP
// packaging or shrinker change must never produce an APK without the model.
val verifyBundledLatinRecognitionModel =
    tasks.register("verifyBundledLatinRecognitionModel") {
        dependsOn("mergeReleaseAssets")
        dependsOn("mergeReleaseNativeLibs")
        doLast {
            val bundledHandwritingDirectory =
                project.file("src/main/assets/handwriting")
            val mergedHandwritingDirectory =
                layout.buildDirectory
                    .dir(
                        "intermediates/assets/release/" +
                            "mergeReleaseAssets/handwriting",
                    ).get().asFile
            val expectedHandwritingAssets =
                mapOf(
                    "latin_PP-OCRv5_mobile_rec.onnx" to
                        "7888113072263CB471B93F66DD5E2AD70548DC526FA1ACE760D0D973DD121498",
                    "latin_PP-OCRv5_mobile_rec.yml" to
                        "0BBE984570F597AF3638E50BDF2E8276F3AB26A61966096538B3B0D1849F5C84",
                    "PADDLEOCR_APACHE_2_LICENSE.txt" to
                        "3840C5C0C61C294264D2DD77B8777BE6DDD90121EF4E0E64ABCD22EDEA581D6E",
                    "ONNXRUNTIME_MIT_LICENSE.txt" to
                        "2F07C72751AED99790B8A4869CF2311DF85A860B22DED05FA22803587A48922C",
                )
            fun sha256(file: File): String {
                val digest = MessageDigest.getInstance("SHA-256")
                file.inputStream().buffered().use { input ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        digest.update(buffer, 0, read)
                    }
                }
                return digest.digest().joinToString("") { byte: Byte ->
                    "%02X".format(byte.toInt() and 0xff)
                }
            }
            expectedHandwritingAssets.forEach { (name, expectedHash) ->
                val source = bundledHandwritingDirectory.resolve(name)
                val merged = mergedHandwritingDirectory.resolve(name)
                if (!source.isFile ||
                    !merged.isFile ||
                    sha256(source) != expectedHash ||
                    sha256(merged) != expectedHash
                ) {
                    throw GradleException(
                        "Bundled handwriting asset is missing or changed: $name",
                    )
                }
            }

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

            val nativeLibraryRoot =
                layout.buildDirectory
                    .dir(
                        "intermediates/merged_native_libs/release/" +
                            "mergeReleaseNativeLibs/out/lib",
                    ).get().asFile
            val requiredAbis = listOf("armeabi-v7a", "arm64-v8a", "x86_64")
            val requiredOnnxLibraries =
                listOf("libonnxruntime.so", "libonnxruntime4j_jni.so")
            val missingOnnxLibraries =
                requiredAbis.flatMap { abi ->
                    requiredOnnxLibraries.mapNotNull { library ->
                        val nativeLibrary = nativeLibraryRoot.resolve("$abi/$library")
                        if (nativeLibrary.isFile && nativeLibrary.length() >= 50_000L) {
                            null
                        } else {
                            "$abi/$library"
                        }
                    }
                }
            if (missingOnnxLibraries.isNotEmpty()) {
                throw GradleException(
                    "Bundled ONNX Runtime is incomplete: " +
                        missingOnnxLibraries.joinToString(),
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
