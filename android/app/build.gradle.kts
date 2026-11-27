plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "claudemirror.app"
    compileSdk = 37

    defaultConfig {
        applicationId = "local.claudemirror.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging {
        resources.excludes += setOf("META-INF/DEPENDENCIES", "META-INF/LICENSE*", "META-INF/NOTICE*", "META-INF/versions/9/OSGI-INF/MANIFEST.MF")
    }
    // The server program built by the root project's prepareServer task.
    sourceSets["main"].assets.srcDir(rootProject.layout.buildDirectory.dir("server-assets").get().asFile)
}

val serverAssets = tasks.register<Copy>("serverAssets") {
    from(rootProject.tasks.named("prepareServer"))
    into(rootProject.layout.buildDirectory.dir("server-assets/server"))
}
tasks.named("preBuild") { dependsOn(serverAssets) }

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
