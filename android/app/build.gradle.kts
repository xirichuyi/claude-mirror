plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// One product version for all clients: the release workflow checks the tag against this plist.
val productVersion = Regex("<key>CFBundleShortVersionString</key>\\s*<string>(\\d+)\\.(\\d+)\\.(\\d+)</string>")
    .find(rootProject.file("../macos/Resources/Info.plist").readText())?.groupValues ?: error("No version in macos/Resources/Info.plist")

// Release signing comes only from the environment (CI secrets); nothing is kept in the repository.
val releaseKeystore = System.getenv("ANDROID_KEYSTORE")?.takeIf { it.isNotBlank() }?.let(rootProject::file)

android {
    namespace = "claudemirror.app"
    compileSdk = 37

    defaultConfig {
        applicationId = "local.claudemirror.android"
        minSdk = 26
        targetSdk = 35
        versionCode = productVersion[1].toInt() * 10000 + productVersion[2].toInt() * 100 + productVersion[3].toInt()
        versionName = productVersion.drop(1).joinToString(".")
    }
    signingConfigs {
        if (releaseKeystore != null) create("release") {
            storeFile = releaseKeystore
            storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("ANDROID_KEY_ALIAS")
            keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging {
        // The QUIC helper is an executable, so it must be extracted to nativeLibraryDir.
        jniLibs.useLegacyPackaging = true
        resources.excludes += setOf("META-INF/DEPENDENCIES", "META-INF/LICENSE*", "META-INF/NOTICE*", "META-INF/versions/9/OSGI-INF/MANIFEST.MF")
    }
    // The server program built by the root project's prepareServer task.
    sourceSets["main"].assets.srcDir(rootProject.layout.buildDirectory.dir("server-assets").get().asFile)
    sourceSets["main"].jniLibs.srcDir(rootProject.layout.buildDirectory.dir("quic-jni").get().asFile)
}

// Static musl builds of tether-quic: copied to servers, and run on the phone itself (Android executes static Linux binaries).
val quicOutput = rootProject.layout.buildDirectory.dir("quic")
val quicBinaries = tasks.register<Exec>("quicBinaries") {
    workingDir = rootDir.parentFile
    commandLine("sh", "scripts/build-quic-linux.sh", quicOutput.get().asFile.path)
    val repository = rootDir.parentFile
    inputs.dir(repository.resolve("quic/src"))
    inputs.files(repository.resolve("quic/Cargo.toml"), repository.resolve("quic/Cargo.lock"), repository.resolve("scripts/build-quic-linux.sh"))
    outputs.dir(quicOutput)
}
val quicJni = tasks.register<Copy>("quicJni") {
    dependsOn(quicBinaries)
    from(quicOutput) { include("tether-quic-linux-arm64"); rename { "libtetherquic.so" }; into("arm64-v8a") }
    from(quicOutput) { include("tether-quic-linux-x64"); rename { "libtetherquic.so" }; into("x86_64") }
    into(rootProject.layout.buildDirectory.dir("quic-jni"))
}

val serverAssets = tasks.register<Copy>("serverAssets") {
    from(rootProject.tasks.named("prepareServer"))
    into(rootProject.layout.buildDirectory.dir("server-assets/server"))
    from(quicBinaries) { into("quic") }
}
tasks.named("preBuild") { dependsOn(serverAssets, quicJni) }

dependencies {
    implementation(project(":core"))
    implementation(libs.coroutines.android)
    implementation(libs.bouncycastle)
    implementation(libs.termlib)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.icons)
    implementation(libs.core)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.navigation.compose)
    implementation(libs.markdown)
}
