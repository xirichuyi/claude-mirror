plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}

// The server program the app uploads to a machine: remote-agent.cjs and manifest.json,
// built from the repository's TypeScript sources.
tasks.register<Exec>("prepareServer") {
    val repository = rootDir.parentFile
    val output = layout.buildDirectory.dir("server")
    inputs.dir(repository.resolve("src"))
    inputs.files(repository.resolve("package.json"), repository.resolve("package-lock.json"), repository.resolve("macos/scripts/prepare-server.cts"))
    outputs.dir(output)
    workingDir = repository
    commandLine("npm", "run", "prepare-server", "--", output.get().asFile.path)
}
