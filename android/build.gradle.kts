// 1. Lock the plugins and build toolchain dependencies (What SonarQube wants)
buildscript {
    dependencyLocking {
        ignoredDependencies.add("io.flutter:*")
        lockAllConfigurations()
    }
}

// 2. Lock standard project configurations (Kept for completeness)
dependencyLocking {
    ignoredDependencies.add("io.flutter:*")
    lockAllConfigurations()
}

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
    dependencyLocking {
        ignoredDependencies.add("io.flutter:*")
        lockAllConfigurations()
    }
}
subprojects {
    project.evaluationDependsOn(":app")
    dependencyLocking {
        ignoredDependencies.add("io.flutter:*")
        lockAllConfigurations()
    }
}

tasks.register<Delete>("clean") {
    group = "build"
    description = "Deletes the root build directory to completely clean the Android project outputs."   
    delete(rootProject.layout.buildDirectory)
}