# Build setup

The script `build.ps1` in the ./scripts folder automates a local build or if you prefer to compile and test the application locally, follow the below steps.

## Prerequisites

- **Flutter SDK:** version 3.10 or later ([Flutter installation guide](https://flutter.dev/docs/get-started/install))
- **Android SDK / Studio:** [download Android Studio](https://developer.android.com/studio) and configure with Java Development Kit (JDK 17), also install Android SDK Command-line Tools and check your config with `flutter doctor`
- A connected physical Android device (with USB Debugging enabled) or an active Android Virtual Device (AVD) Emulator.

## Building

A shell script `build-optimisation` is included in the ./scripts folder, this can be used to set up the build environment for 8, 16, 32, 64 RAM configuations. It should significantly speed up building/debugging runs.

### 1. Clean and install dependencies

Clean the build environment and pull the tracking package constraints defined within the project manifests:

```bash
flutter clean
flutter pub get --enforce-lockfile
```

#### 2. Generate assets (launcher icons)

The app leverages the `flutter_launcher_icons` framework to generate adaptive foreground and background configurations for Android launchers. Before your initial compilation, generate the native resource files:

```bash
dart run flutter_launcher_icons
```

#### 3. Test and run

The command `fcr` belongs to the `flutter_coverage_report` package. It is a fantastic pure-Dart tool that takes your dense, ugly lcov.info file and parses it into a sleek, interactive HTML webpage right in your browser. Install via

```bash
dart pub global activate flutter_coverage_report
```

Execute tests and run a hot-reloaded debug instance directly onto your attached mobile/emulated device:

```bash
flutter test --coverage
fcr coverage/lcov.info --open ## creates & opens ./coverage/coverage-report.html
flutter run -d <device_id>    ## get your device ID via "flutter devices"
```

You may need to install the Android emulator for `flutter run` to execute

```bash
sudo apt install google-android-emulator-installer
emulator -list-avds       ## show emulated devices
emulator -avd Pixel_7_Pro ## replace Pixel_7_Pro with your device name
flutter devices           ## check it is installed
```

#### 4. App signing & keystore configuration

To ensure that both local release builds and GitHub Actions CI builds produce matching digital signatures, this project uses a unified keystore strategy. This allows Android devices to accept over-the-top APK installations (sideloading updates) without requiring a manual uninstall first.

> [!CAUTION]
> Android strictly enforces that every APK update must be signed by the exact same certificate as the installed version. Mixing a debug-signed local APK with a release-signed CI APK (or vice versa) results in an `INSTALL_FAILED_UPDATE_INCOMPATIBLE` rejection.

#### Local developer set up (One-time)

1. **Generate the keystore:** execute the following command to generate a 2048-bit RSA key pair valid for 10,000 days:

   ```bash
   keytool -genkey -v -keystore release.jks -alias pia-wireguard \
       -keyalg RSA -keysize 2048 -validity 10000
   ```

2. Secure the keystore file: move release.jks completely OUTSIDE of the repository folder (e.g., place it securely in your user home directory: ~/.android/). Never commit a .jks file to source control.

3. Configure local environment credentials: create a local configuration file named android/key.properties (this file is already safely ignored by .gitignore) and provide the exact absolute path and passwords:

   ```ini
   storeFile=/Users/YOUR_USERNAME/.android/release.jks
   storePassword=YOUR_STORE_PASSWORD
   keyAlias=pia-wireguard
   keyPassword=YOUR_KEY_PASSWORD
   ```

#### CI/CD environment setup (GitHub Actions)

The `release.yml` workflow is designed to dynamically assemble this footprint before compilation so developers and automation stay perfectly in sync:

1. **Base64 encode the keystore**: to inject the binary keystore into GitHub without committing it, encode it to a clean text blob and copy it to your clipboard:
   - **macOS**: `base64 -i release.jks | pbcopy`
   - **Linux**: `base64 -w 0 release.jks`
   - **Windows (PowerShell)**: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("release.jks")) | Set-Clipboard`

2. Add repository secrets: in your GitHub Repository, navigate to Settings > Secrets and variables > Actions and create four secrets using the values you created above:
   - KEYSTORE_BASE64 (The string blob copied from the base64 command)
   - KEYSTORE_PASSWORD
   - KEY_ALIAS
   - KEY_PASSWORD

The pipeline will decode the base64 asset and provision a temporary `key.properties` dynamically before executing `flutter build apk --release`.

#### 5. Build release APK

Once your local `android/key.properties` or GitHub Repository Secrets are mapped out (see header comments in `android\app\build.gradle.kts`), create a stand-alone production compilation targeted for distribution:

```bash
flutter build apk --release
```

#### Local output destinations

- Standard Flutter pipeline archive: build/app/outputs/flutter-apk/app-release.apk
- Gradle pipeline build output: build/app/outputs/apk/release/pia-wireguard-cfga-release.apk

#### 6. Sideload

To push the compiled app to your phone via Android Debug Bridge (ADB):

```bash
adb install build/app/outputs/flutter-apk/app-release.apk
```

---

## Package dependencies

| Package             | Purpose                                                                             |
| ------------------- | ----------------------------------------------------------------------------------- |
| `http`              | HTTP REST connection pipelines to PIA APIs                                          |
| `x25519`            | Ephemeral WireGuard keypair generation                                              |
| `share_plus`        | Share/save config file via Android share sheet                                      |
| `package_info_plus` | Querying app package metadata dynamically from `pubspec.yaml` for version reporting |

## Dependency pinning & reproducible builds

Project and build-toolchain dependencies are strictly pinned to mitigate supply-chain vulnerabilities and ensure fully reproducible, deterministic builds across all local environments and CI/CD pipelines.

In `android\app\build.gradle.kts` we utilise Gradle's dependency locking feature enforced in **Strict Mode** (`LockMode.STRICT`). This guarantees that dynamic versions or changing dependencies cannot secretly pull in untested, unreviewed, or malicious updates. The build environment remains identical for every developer, every time.

### Why this matters

- **Supply-chain security**: prevents "dependency confusion" or compromised upstream updates from automatically making their way into our builds.
- **Consistency**: eliminates the infamous "it works on my machine" dilemma by freezing the entire dependency graph—including transitive dependencies.
- **Auditability**: changes to dependencies appear clearly in pull request diffs, allowing reviewers to catch unintended upgrades.

#### The strict mode safeguard

If a dependency version is changed or a new package is added _without_ updating the lockfiles, the local build and CI/CD pipeline will intentionally crash with an error resembling:

> `> Resolved dependency 'androidx.core:core-ktx:1.12.0' which is not configured in the lockfile.`

This is expected and correct behavior designed to block untracked dependency updates from making it into production.

#### When to regenerate lockfiles

You must regenerate the Gradle lockfiles whenever you:

1. Add a new package or dependency to build.gradle.
2. Update the version of an existing package.
3. Modify or upgrade build plugins.

#### How to regenerate lockfiles

From the project root folder, execute the appropriate command for your operating system to update the three lockfiles:

CMD/PS1

```DOS
.\android\gradlew -p android :dependencies :app:dependencies --write-locks
```

Linux

```bash
./android/gradlew -p android :dependencies :app:dependencies --write-locks
```

> [!NOTE]
> After running this command, make sure to commit the updated lockfiles (\*.lockfile) to Git along with your build.gradle changes. If the lockfiles are missing or out of sync, the CI/CD pipeline will fail the build.

## Updating GitHub action SHAs

The `update-shgas.ps1` script, located in the repository root, automates the process of hardening GitHub Actions by pinning them to secure commit SHAs.
The script queries the GitHub API for the latest release tags, resolves them to full SHAs across all `.github/workflows/*.yml` files, and rewrites the workflows in-place. Any previously pinned SHAs are automatically re-evaluated and updated if a newer version is available.

### Example transformation

Before:

```bash
     uses: google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@v1.0.3
```

After:

```bash
     uses: google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@9a498708959aeaef5ef730655706c5a1df1edbc2  ## v2.3.8
```

#### Why this is a best practice

Pinning workflows to a specific commit SHA, rather than a mutable version tag like v1 or latest, is a critical security practice recommended by GitHub for several reasons:

- Defends against supply chain attacks: Git tags are mutable. If a malicious actor compromises a third-party dependency repository, they can move an existing version tag (like v1.0.3) to point to malicious code. Commit SHAs are cryptographically immutable and cannot be spoofed.

- Ensures build reproducibility: pinning guarantees that the exact same code runs during every workflow execution, preventing unexpected breaking changes or hidden updates from disrupting your CI/CD pipeline.

- Maintains readability via automation: while SHAs are great for security, they are terrible for human readability. The script solves this by automatically appending a comment with the human-readable version tag (e.g., ## v2.3.8), giving you the best of both worlds: strict security and clear version tracking.

## Build chain & utility notes

- keep your build environment up to date with:

  ```cmd
  flutter upgrade
  flutter pub upgrade
  .\android\gradlew -p android :dependencies :app:dependencies --write-locks
  ```

- To run **OSV-Scanner** locally (scans dependencies against Google's OSV vulnerability database):

  ```bash
  ## 1. Download the latest Linux binary (run from repo root, e.g. under WSL)
  sudo curl -L https://github.com/google/osv-scanner/releases/latest/download/osv-scanner_linux_amd64 \
    -o /usr/local/bin/osv-scanner
  sudo chmod +x /usr/local/bin/osv-scanner

  ## 2. Basic scan (recursively scans all supported lockfiles in the project)
  osv-scanner .

  ## 3. Scan only the Dart/Flutter lockfile
  osv-scanner --lockfile=pubspec.lock

  ## 4. Scan Android Gradle dependencies (expect many!)
  osv-scanner --lockfile=android/app/gradle.lockfile
  ```
