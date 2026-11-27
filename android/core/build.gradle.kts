plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin { jvmToolchain(17) }

dependencies {
    api(libs.coroutines.core)
    api(libs.serialization.json)
    api(libs.sshj)
    implementation(libs.bouncycastle)
    testImplementation(libs.junit)
    testImplementation(libs.coroutines.test)
}

tasks.test {
    // The agent tests run the real server program with Node.js from the repository build.
    systemProperty("claudemirror.server", System.getenv("CLAUDE_MIRROR_E2E_SERVER") ?: rootProject.layout.buildDirectory.dir("server").get().asFile.path)
    inputs.properties(System.getenv().filterKeys { it.startsWith("CLAUDE_MIRROR_E2E_") })
    dependsOn(rootProject.tasks.named("prepareServer"))
}
