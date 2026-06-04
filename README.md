# pia-wireguard-cfga<img src="./assets/icon/icon.png" alt="PIA WireGuard CFGA" width="150" />

<a href="https://www.android.com/" target="_blank" rel="noopener noreferrer"><img src="https://img.shields.io/badge/platform-%20Android%20-blue" alt="Platform"></a> <a href="https://github.com/ExponentiallyDigital/pia-wireguard-cfga/releases" target="_blank" rel="noopener noreferrer"><img src="https://img.shields.io/github/v/release/ExponentiallyDigital/pia-wireguard-cfga" alt="Release"></a> <a href="https://github.com/ExponentiallyDigital/pia-wireguard-cfga/tags" target="_blank" rel="noopener noreferrer"><img src="https://img.shields.io/github/last-commit/ExponentiallyDigital/pia-wireguard-cfga" alt="Last Commit"></a> <a href="https://github.com/ExponentiallyDigital/pia-wireguard-cfga/blob/main/LICENSE" target="_blank" rel="noopener noreferrer"><img src="https://img.shields.io/github/license/ExponentiallyDigital/pia-wireguard-cfga" alt="License"></a> <a href="https://github.com/ExponentiallyDigital/pia-wireguard-cfga/releases" target="_blank" rel="noopener noreferrer"><img src="https://img.shields.io/github/downloads/ExponentiallyDigital/pia-wireguard-cfga/total" alt="Downloads"></a><br><a href="https://sonarcloud.io/project/overview?id=ExponentiallyDigital_pia-wireguard-cfga" target="_blank" rel="noopener noreferrer"><img src="https://sonarcloud.io/api/project_badges/measure?project=ExponentiallyDigital_pia-wireguard-cfga&metric=security_rating" alt="Security Rating"></a> <a href="https://sonarcloud.io/project/overview?id=ExponentiallyDigital_pia-wireguard-cfga" target="_blank" rel="noopener noreferrer"><img src="https://sonarcloud.io/api/project_badges/measure?project=ExponentiallyDigital_pia-wireguard-cfga&metric=reliability_rating" alt="Reliability"></a> <a href="https://sonarcloud.io/project/overview?id=ExponentiallyDigital_pia-wireguard-cfga" target="_blank" rel="noopener noreferrer"><img src="https://sonarcloud.io/api/project_badges/measure?project=ExponentiallyDigital_pia-wireguard-cfga&metric=sqale_rating" alt="Maintainability"></a><br><a href="https://sonarcloud.io/project/overview?id=ExponentiallyDigital_pia-wireguard-cfga" target="_blank" rel="noopener noreferrer"><img src="https://sonarcloud.io/api/project_badges/measure?project=ExponentiallyDigital_pia-wireguard-cfga&metric=vulnerabilities" alt="Vulnerabilities"></a> <a href="https://sonarcloud.io/project/overview?id=ExponentiallyDigital_pia-wireguard-cfga" target="_blank" rel="noopener noreferrer"><img src="https://sonarcloud.io/api/project_badges/measure?project=ExponentiallyDigital_pia-wireguard-cfga&metric=bugs" alt="Bugs"></a> <a href="https://sonarcloud.io/project/overview?id=ExponentiallyDigital_pia-wireguard-cfga" target="_blank" rel="noopener noreferrer"><img src="https://sonarcloud.io/api/project_badges/measure?project=ExponentiallyDigital_pia-wireguard-cfga&metric=coverage" alt="Coverage"></a>

A native Android GUI app built with Flutter and Dart that generates a ready-to-use WireGuard configuration file for the Private Internet Access (PIA) VPN service. It authenticates with PIA's official provisioning API, selects the lowest-latency server in your chosen region, generates a fresh WireGuard keypair, and allows you to save the complete `.conf` to the clipboard or share/save to a user specified app/location.

This app is a GUI Android APK equivalent of my [Windows 11/Linux command line app](https://github.com/ExponentiallyDigital/pia-wireguard-cfg).

## Why use this?

Manually creating a PIA WireGuard configuration requires authenticating against multiple APIs, parsing server lists, performing key exchange, and assembling the config by hand. **pia-wireguard-cfga** automates the entire process.

## Features

- **Automated lowest-latency server selection:** measures live TCP latency against port 1337 across all available servers in your selected target region, ensuring you always provision against the fastest node.
- **Cryptographically secure keypair generation:** dynamically generates an ephemeral WireGuard keypair using `x25519` with proper RFC 7748 scalar clamping directly inside the runtime environment.
- **Dynamic certificate pinning:** fetches PIA's trusted root CA certificate dynamically at runtime from the `pia-foss/manual-connections` repository. No hardcoded certificates ensure operations continue smoothly even if PIA rotates authority roots.
- **Zero-persistence local footprint:** sensitive keys, usernames, and passwords reside exclusively as short-lived volatile variables inside system RAM (`AppState`). Config payloads are written to a named temporary file solely to preserve the correct filename through the OS share pipeline, then deleted immediately in a `finally` block once `share()` returns -- whether the share completes, is cancelled, or throws. No unencrypted files are permanently cached or retained in local storage.
- **Credential safety:** your PIA password is entered interactively at execution and used strictly to request a short-lived HTTP Basic Auth provisioning token. Credentials are never written to disk, stored, or logged.
- **Automatic session self-destruct:** includes an automatic 3-minute safety countdown timer. If the app is left idle for 3 continuous minutes while displaying a configuration, the screen UI, form states, and memory addresses are completely wiped. Active screen interactions automatically reset the clock back to a full 3 minutes.
- **Automated clipboard protection:** copies the generated config securely to the clipboard and triggers an independent 60-second real-time countdown visible under the button. After 60 seconds, or immediately if the user triggers a manual session wipe, the system clipboard is overwritten with an empty string to prevent background clipboard-scraping apps from harvesting your config.
- **Native Task-Switcher Protection (`FLAG_SECURE`):** Enforces native OS-level window flags to block third-party screenshot capturing and automatically obfuscates/blanks the app layout view inside the Android Recent Apps / Task Switcher interface.
- **Input field hardening:** user credential entry textboxes disable predictive dictionary caching, auto-correction tracking assistance, and keyboard learning behaviours, alongside native selection overrides to block background clipboard scraping.
- **Modern adaptive styling:** fully supports Android 8.0+ Adaptive Icons using a native multi-layered presentation conforming to a dark-mode theme aesthetic (`#12141A`).

## Pre-built releases

If you don't want to compile the app from scratch, pre-packaged release archives are available under the [Releases](https://github.com/ExponentiallyDigital/pia-wireguard-cfga/releases) section of this [GitHub repository](https://github.com/ExponentiallyDigital/pia-wireguard-cfga).

Each release contains a versioned, compiled, production-ready `.zip` archive containing:

- The optimised multi-platform Android application (`pia-wireguard-cfga.apk`) and SHA1 (`pia-wireguard-cfga.sha1`)
- Offline documentation (`README.html`, `README.md` and `LICENSE`)

## Using the app

1. Enter a region or click the icon to the right and select from a dynamically updated alpha sorted filterable list of current PIA regions.

<table style="width: 100%; border-collapse: collapse; border: none;">
  <tr>
    <td align="center" style="width: 50%; border: none; padding: 10px;">
      <img src="./images/interface.jpg" alt="Screenshot: pia-wireguard-cfga UI" width="100%">
    </td>
    <td align="center" style="width: 50%; border: none; padding: 10px;">
      <img src="./images/region-selection.jpg" alt="Screenshot: region selection" width="100%">
    </td>
  </tr>
  <tr>
    <td align="center" style="border: none; padding: 5px 10px 10px 10px; vertical-align: top;">
      <strong>PIA WireGuard Config App UI</strong>
    </td>
    <td align="center" style="border: none; padding: 5px 10px 10px 10px; vertical-align: top;">
      <strong>Region Selection Screen</strong>
    </td>
  </tr>
</table>

2. Add/paste your PIA username/password details (entered text cannot be copied from the password field)

<table style="width: 100%; border-collapse: collapse; border: none;">
  <tr>
    <td style="width: 25%; border: none;"></td>
    <td align="center" style="width: 50%; border: none; padding: 10px;">
      <img src="./images/interface-fields.jpg" alt="Screenshot: interface fields" width="100%">
    </td>
    <td style="width: 25%; border: none;"></td>
  </tr>
  <tr>
    <td style="border: none;"></td>
    <td align="center" style="border: none; padding: 5px 10px 10px 10px; vertical-align: top;">
      <strong>Interface Fields</strong>
    </td>
    <td style="border: none;"></td>
  </tr>
</table>

3. Optional - accept the default DNS servers (Quad 9) or enter your choices, use a comma to separate entries.
4. Click on the "GENERATE CONFIG" button.
5. After successful PIA authentication your chosen region's config file is displayed in the "GENERATED CONFIG" window. You can select specific text from this window or click "COPY" to send the window contents to the clipboard. Use "SHARE / SAVE" to send the config file to a specific app e.g. your favourite file system app to save the generated conf file to a location of choice.

<table style="width: 100%; border-collapse: collapse; border: none;">
  <tr>
    <td style="width: 25%; border: none;"></td>
    <td align="center" style="width: 50%; border: none; padding: 10px;">
      <img src="./images/generated-config.jpg" alt="Screenshot: generated config" width="100%">
    </td>
    <td style="width: 25%; border: none;"></td>
  </tr>
  <tr>
    <td style="border: none;"></td>
    <td align="center" style="border: none; padding: 5px 10px 10px 10px; vertical-align: top;">
      <strong>Generated Config</strong>
    </td>
    <td style="border: none;"></td>
  </tr>
</table>

6. Conf files are named per the region name (agreed, PIA isn't consistent with the region name format!)
7. Above the "GENERATED CONFIG" window there's a "CLEAR" button that removes your WireGuard credentials (config data, PIA username/password) from your device's screen and securely overwrites these variables stored in memory. Next to that there's a countdown timer. After no activity for 3 minutes, your credentials are automatically wiped. The timer is reset when there's in app activity (scrolling, tapping etc).
8. At the bottom of the screen there's a scrollable "LOG" of processing/activity that can be cleared.

## Build setup

If you prefer to compile and test the application locally, follow the configuration steps below.

### Prerequisites

- **Flutter SDK:** version 3.10 or later ([Flutter installation guide](https://flutter.dev/docs/get-started/install))
- **Android SDK / Studio:** [download Android Studio](https://developer.android.com/studio) and configure with Java Development Kit (JDK 17), also install Android SDK Command-line Tools and check your config with `flutter doctor`
- A connected physical Android device (with USB Debugging enabled) or an active Android Virtual Device (AVD) Emulator.

### 1. Install dependencies

Pull the tracking package constraints defined within the project manifests:

```bash
flutter pub get
```

### 2. Generate assets (launcher icons)

The app leverages the `flutter_launcher_icons` framework to generate adaptive foreground and background configurations for Android launchers. Before your initial compilation, generate the native resource files:

```bash
dart run flutter_launcher_icons
```

### 3. Run locally for testing

To run a hot-reloaded debug instance directly onto your attached mobile workspace:

```bash
flutter run
```

### 4. Build release APK

To create a stand-alone production compilation targeted for distribution:

```bash
flutter build apk --release
```

#### Local output destinations

- Standard Flutter pipeline archive: build/app/outputs/flutter-apk/app-release.apk
- Gradle pipeline build output: build/app/outputs/apk/release/pia-wireguard-cfga-release.apk

### 5. Sideload

To push the compiled binaries directly onto your phone via Android Debug Bridge (ADB):

```bash
adb install build/app/outputs/flutter-apk/app-release.apk
```

### 6. Dependency pinning & reproducible builds

Project and build-toolchain dependencies are pinned to prevent supply-chain vulnerabilities and ensure reproducible builds across CI/CD environments.

If you update packages or change build plugins, you must regenerate the Gradle lockfiles. To generate the three files, execute the following from the project root folder:

```cmd
.\android\gradlew -p android :dependencies :app:dependencies --write-locks
```

## How it works

The provisioning logic in `lib/pia_service.dart` is a direct Dart translation of the command line version's [Go code](https://github.com/ExponentiallyDigital/pia-wireguard-cfg/blob/main/main.go), implementing the same steps in the same order:

1. **Server discovery**: pulls the complete endpoints mapping directly from serverlist.piaservers.net/vpninfo/servers/v6. The payload splits at the first newline boundary to discard the payload block signature.
2. **Latency probes**: dispatches immediate TCP probes to port 1337 across regional candidate blocks to calculate routing latency.
3. **Session tokens**: challenges the central API through a standard POST request over TLS, securing an execution token from basic user parameters.
4. **Keypair issuance**: generate WireGuard keypair using X25519 with RFC 7748 scalar clamping  
      (k[0] &= 248, k[31] &= 127, k[31] |= 64)
5. **Secure registration**: submits the dynamic public key configuration to the chosen low-latency endpoint via an HTTPS API (port 1337). The step utilises the dynamically resolved PIA root certificate, matching the specific Common Name (CN) mapping fields rather than raw IP routing addresses. The certificate is not hardcoded, so that it stays current when PIA rotates it.
6. **Config assembly**: transforms payload metadata returns into localised .conf specifications utilising Unix line endings (\n) for cross-compatibility.

### Sample output

```none
[Interface]
PrivateKey = <freshly generated private key>
Address    = <client IP/32 assigned by PIA>
DNS        = 9.9.9.9, 149.112.112.112
MTU        = 1420

[Peer]
PublicKey           = <server public key from PIA>
Endpoint            = <server IP:port from PIA>
PersistentKeepalive = 25
AllowedIPs          = 0.0.0.0/0
```

## Output & session destruction

The generated configuration data lifecycle is managed under a high-security paradigm:

- **Ephemeral verification:** displayed on-screen inside an obscured text viewport for instant validation.
- **Transient streaming:** shareable seamlessly using Android's system share sheet (e.g., via "Save to Files" or encrypted side-channels) via localized memory stream descriptors.
- **Manual clear:** the "Clear" action button scrubs the username, password, and displayed config on screen data.
- **Clipboard sanitization:** tapping "COPY" invokes a 60-second timer that clears the clipboard storage space automatically, limiting the visibility window of raw private key data.
- **Safety timeout clock:** adjacent to the "Clear" action button, a real-time countdown widget tracks session idle state, executing a complete memory and view scrub if the application interface goes completely untouched for 3 consecutive minutes.

## Notes

- **Time-to-live constraints**: PIA Wireguard configs expire every few weeks per PIA's token handling, requiring you to regenerate a config file periodically (which is why this app exists!).
- **Key safety**: the generated config contains private encryption keys. Treat them like a password and manage them securely.
- **Network requirements**: an active internet connection is required to resolve remote lookup tables and register credentials with API endpoints.

## Package dependencies

| Package              | Purpose                                                                                   |
| -------------------- | ----------------------------------------------------------------------------------------- |
| `http`               | HTTP REST connection pipelines to PIA APIs                                                |
| `x25519`             | Ephemeral WireGuard keypair generation                                                    |
| `share_plus`         | Share/save config file via Android share sheet                                            |
| `package_info_plus`  | Querying app package metadata dynamically from `pubspec.yaml` to unify version reporting  |

## App permissions & OS queries

This app requires specific native system declarations to manage secure API handshakes, latency benchmarking, configuration export workflows, and external documentation routing:

### 1. Hardware & networking permissions (`uses-permission`)

- **Internet access** (`android.permission.INTERNET`)
    - **Purpose:** required for secure communication with Private Internet Access (PIA) backend API layers to perform user authentication, dynamically fetch current VPN server endpoints, and request temporary session tokens.
- **Network connectivity state** (`android.permission.ACCESS_NETWORK_STATE`)
    - **Purpose:** allows the application to verify active device internet handshakes before launching network operations, preventing unexpected crashes and managing socket timeouts.

### 2. Legacy storage compatibility

- **Write external storage** (`android.permission.WRITE_EXTERNAL_STORAGE`)
    - **Constraint:** enforced only on legacy operating systems up to **Android 9 / Pie** (`maxSdkVersion="28"`).
    - **Purpose:** grants isolated clearance to save generated `.conf` WireGuard profiles directly to the device's shared system `Downloads/` directory.
- **Read external storage** (`android.permission.READ_EXTERNAL_STORAGE`)
    - **Constraint:** enforced only on platforms up to **Android 12** (`maxSdkVersion="32"`).
    - **Purpose:** ensures complete file-checking validation can occur during configuration generation and deployment tasks.

### 3. Deep-linking intent queries (`queries`)

- **Browsable HTTPS target protocols** (`android.intent.action.VIEW` + `android.intent.category.BROWSABLE`)
    - **Purpose:** implemented explicitly for devices running **Android 11 (API 30) or modern versions** to white-list secure deep-links. This grants the internal presentation layout permissions to query and branch out into the host device's native system web browser when users tap external hyperlink text anchors (e.g., source code documentation or developer profiles).

## Development "to do" list

1. Fix table display on README: renders fine in VS Code with Markdown Preview Enhanced, but borders are visible on GitHub, and pandoc HTML version has horizintal lines above/below tables
2. Release to Play Store - needs 12 testers over 14 continuous days
3. create SECURITY.md
4. DONE review Actions CI pipeline - add flutter analyze, rename pipeline
5. DONE clear clipboard after 60 seconds if conf copied there
6. extra security/code analysis:
   DONE dependabot (dependency review)
   DONE OSV-Scanner
   DONE mobsf
   AppSweep (Guardsquare) - needs invitation to get free account
7. add badges for above
8. include software BOM (bill of materials) - move from README to SECURITY md
9. DONE split release.yaml into code scan and actual release
10. DONE renamed $ADDON to $RELEASE in release.yaml (was carry over from WoW addon packaging)
11. DONE fixup html intermediary file name (caused resultant doc title issue)
12. add SBOM as a release artifact (Syft)
13. add how to privately report a security vulnerability (enabled in GitHub)
14. DONE implement local PS1 app to replace tags with SHAs
15. switch from SHA-1 to SHA-256 for integrity verification
16. DONE enable dependabot

## Build chain & utility notes

- keep your build environment up to date with:

```cmd
flutter upgrade
flutter pub upgrade
.\android\gradlew -p android :dependencies :app:dependencies --write-locks
```

- To run **OSV-Scanner** locally (scans dependencies against Google's OSV vulnerability database):

  ```bash
  # 1. Download the latest Linux binary (run from repo root, e.g. under WSL)
  sudo curl -L https://github.com/google/osv-scanner/releases/latest/download/osv-scanner_linux_amd64 \
    -o /usr/local/bin/osv-scanner
  sudo chmod +x /usr/local/bin/osv-scanner

  # 2. Basic scan (recursively scans all supported lockfiles in the project)
  osv-scanner .

  # 3. Scan only the Dart/Flutter lockfile
  osv-scanner --lockfile=pubspec.lock

  # 4. Scan Android Gradle dependencies (expect many!)
  osv-scanner --lockfile=android/app/gradle.lockfile
  ```

## Contributing

Contributions are welcome. To contribute:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Ensure code formatting is clean (`flutter format .` and `flutter analyze`)
5. Push to the branch (`git push origin feature/AmazingFeature`)
6. Open a Pull Request

## Bugs and feature requests

Found a bug or want to request a feature? [Open an issue here](https://github.com/ExponentiallyDigital/pia-wireguard-cfga/issues).

## Support

This tool is unsupported and may cause objects in mirrors to be closer than they appear. Batteries not included.

## License

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses/>.

Copyright (C) 2026 Andrew Newbury.
