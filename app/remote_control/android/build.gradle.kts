allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 260716-kba: mobile_scanner 7.2.x applies `kotlin-android` only on AGP < 9,
// expecting AGP 9's built-in Kotlin to provide its `kotlin {}` extension —
// but the Flutter template pins `android.builtInKotlin=false`, and Flutter's
// own KGP auto-apply skips the project because the (runtime-conditional)
// `apply plugin: 'kotlin-android'` line matches its textual detection. Apply
// KGP right after the plugin's `com.android.library` lands, so the extension
// exists before its `kotlin {}` block evaluates. Idempotent; remove once
// mobile_scanner handles AGP 9 with built-in Kotlin disabled.
subprojects {
    if (name == "mobile_scanner") {
        plugins.withId("com.android.library") {
            pluginManager.apply("org.jetbrains.kotlin.android")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
