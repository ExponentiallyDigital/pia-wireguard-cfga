# pia-wireguard-cfga<img src="./assets/icon/icon.png" alt="PIA WireGuard CFGA" width="150" />

<a href="https://www.android.com/" target="_blank" rel="noopener noreferrer"><img src="https://img.shields.io/badge/platform-%20Android%20-blue" alt="Platform"></a> <a href="https://github.com/ExponentiallyDigital/pia-wireguard-cfga/releases" target="_blank" rel="noopener noreferrer"><img src="https://img.shields.io/github/v/release/ExponentiallyDigital/pia-wireguard-cfga" alt="Release"></a> <a href="https://github.com/ExponentiallyDigital/pia-wireguard-cfga/tags" target="_blank" rel="noopener noreferrer"><img src="https://img.shields.io/github/last-commit/ExponentiallyDigital/pia-wireguard-cfga" alt="Last Commit"></a> <a href="https://github.com/ExponentiallyDigital/pia-wireguard-cfga/blob/main/LICENSE" target="_blank" rel="noopener noreferrer"><img src="https://img.shields.io/github/license/ExponentiallyDigital/pia-wireguard-cfga" alt="License"></a> <a href="https://github.com/ExponentiallyDigital/pia-wireguard-cfga/releases" target="_blank" rel="noopener noreferrer"><img src="https://img.shields.io/github/downloads/ExponentiallyDigital/pia-wireguard-cfga/total" alt="Downloads"></a><br><a href="https://sonarcloud.io/project/overview?id=ExponentiallyDigital_pia-wireguard-cfga" target="_blank" rel="noopener noreferrer"><img src="https://sonarcloud.io/api/project_badges/measure?project=ExponentiallyDigital_pia-wireguard-cfga&metric=security_rating" alt="Security Rating"></a> <a href="https://sonarcloud.io/project/overview?id=ExponentiallyDigital_pia-wireguard-cfga" target="_blank" rel="noopener noreferrer"><img src="https://sonarcloud.io/api/project_badges/measure?project=ExponentiallyDigital_pia-wireguard-cfga&metric=reliability_rating" alt="Reliability"></a> <a href="https://sonarcloud.io/project/overview?id=ExponentiallyDigital_pia-wireguard-cfga" target="_blank" rel="noopener noreferrer"><img src="https://sonarcloud.io/api/project_badges/measure?project=ExponentiallyDigital_pia-wireguard-cfga&metric=sqale_rating" alt="Maintainability"> <a href="https://github.com/ExponentiallyDigital/ExponentiallyDigital/security/policy" target="_blank" rel="noopener noreferrer"><img src="https://img.shields.io/badge/Security-Policy-blue" alt="Security Policy"></a></a><br><a href="https://sonarcloud.io/summary/new_code?id=ExponentiallyDigital_pia-wireguard-cfga" target="_blank" rel="noopener noreferrer"><img src="https://sonarcloud.io/api/project_badges/measure?project=ExponentiallyDigital_pia-wireguard-cfga&metric=alert_status" alt="Quality"></a> <a href="https://sonarcloud.io/project/overview?id=ExponentiallyDigital_pia-wireguard-cfga" target="_blank" rel="noopener noreferrer"><img src="https://sonarcloud.io/api/project_badges/measure?project=ExponentiallyDigital_pia-wireguard-cfga&metric=vulnerabilities" alt="Vulnerabilities"></a> <a href="https://sonarcloud.io/project/overview?id=ExponentiallyDigital_pia-wireguard-cfga" target="_blank" rel="noopener noreferrer"><img src="https://sonarcloud.io/api/project_badges/measure?project=ExponentiallyDigital_pia-wireguard-cfga&metric=bugs" alt="Bugs"></a> <a href="https://sonarcloud.io/project/overview?id=ExponentiallyDigital_pia-wireguard-cfga" target="_blank" rel="noopener noreferrer"><img src="https://sonarcloud.io/api/project_badges/measure?project=ExponentiallyDigital_pia-wireguard-cfga&metric=coverage" alt="Coverage"></a>

---

A native Android GUI app built with Flutter and Dart that generates a ready-to-use WireGuard configuration file for the Private Internet Access (PIA) VPN service. It authenticates with PIA's official provisioning API, selects the lowest-latency server in your chosen region, generates a fresh WireGuard keypair, and allows you to save the complete `.conf` to the clipboard or share/save to a user specified app/location. If you have an ASUS router running [Asuswrt-Merlin](https://www.asuswrt-merlin.net/) firmware, you can optionally "push" the new config directly to your router!

This app is a GUI Android APK equivalent of my [Windows 11/Linux command line app](https://github.com/ExponentiallyDigital/pia-wireguard-cfg).

## Why use this?

Manually creating a PIA WireGuard configuration requires authenticating against multiple APIs, parsing server lists, performing key exchange, and assembling the config by hand. **pia-wireguard-cfga** automates the entire process.

## Features

- **Automated lowest-latency server selection:** measures live TCP latency against port 1337 across all available servers in your selected target region, ensuring that you provision with the fastest node.
- **Cryptographically secure keypair generation:** dynamically generates an ephemeral WireGuard keypair using `x25519` with proper RFC 7748 scalar clamping directly inside the runtime environment.
- **Dynamic certificate pinning:** fetches PIA's trusted root CA certificate dynamically at runtime from the `pia-foss/manual-connections` repository. No hardcoded certificates ensure operations continue smoothly even if PIA rotates authority roots.
- **Zero-persistence local footprint:** sensitive keys, usernames, and passwords reside exclusively as short-lived volatile variables inside system RAM (`AppState`). Config payloads are written to a named temporary file solely to preserve the correct filename through the OS share pipeline, then deleted immediately in a `finally` block once `share()` returns -- whether the share completes, is cancelled, or throws. No unencrypted files are permanently cached or retained in local storage.
- **Credential safety:** your PIA password is entered interactively at execution and used strictly to request a short-lived HTTP Basic Auth provisioning token. Credentials are never written to disk, stored, or logged.
- **Automatic session wipe:** includes an automatic 3-minute safety countdown timer. If the app is left idle for 3 continuous minutes while displaying a configuration, the screen UI, form states, and memory addresses are wiped. Active screen interactions reset the timer to 3 minutes.
- **Automated clipboard protection:** copies the generated config securely to the clipboard and triggers an independent 60-second real-time countdown visible under the button. After 60 seconds, or immediately if the user triggers a manual session wipe, the system clipboard is overwritten with an empty string to prevent background clipboard-scraping apps from harvesting your config.
- **Native task-switcher protection (`FLAG_SECURE`):** enforces native OS-level window flags to block third-party screenshot capturing and automatically obfuscates/blanks the app layout view inside the Android Recent Apps / Task Switcher interface.
- **Input field hardening:** user credential entry textboxes disable predictive dictionary caching, auto-correction tracking assistance, and keyboard learning behaviours, alongside native selection overrides to block background clipboard scraping.
- **Modern adaptive styling:** fully supports Android 8.0+ Adaptive Icons using a native multi-layered presentation conforming to a dark-mode theme aesthetic (`#12141A`).

---

## Pre-built releases

This app has been submitted to the Google Play Store, when their process concludes, a link will be placed **`<here>`**.

If you want to download a pre-built release from [GitHub](https://github.com/ExponentiallyDigital/pia-wireguard-cfga/releases), the file you need is **`pia_wireguard_cfga-<version>_release.apk`**.

Each release includes the following versioned files:

- **`pia_wireguard_cfga-<version>_release.apk`** – optimised signed release APK
- **`pia_wireguard_cfga-<version>_debug.apk`** – debug APK for testing
- **`pia_wireguard_cfga-<version>_google-play-store.aab`** – an Android App Bundle for the Play Store
- **`pia-wireguard-cfga-<version>_sbom.spdx.json`** – software bill of materials (SPDX format)
- **`README.html`** – offline documentation (generated from this README)
- **`LICENSE`** – license file

The installlable pre-built apps above have [GitHub Attestations](https://github.com/ExponentiallyDigital/pia-wireguard-cfga/attestations) for [build provenance](https://slsa.dev/spec/draft/build-provenance) verification.

---

## Using the app

1. Enter a region or tap the icon to the right and select from a dynamically updated alpha sorted filterable list of available PIA regions:

<table>
<tr>
<td align="center">
<img src="./images/01-interface.png" width="350"><br>
<strong>PIA WireGuard Config App UI</strong>
</td>
<td align="center">
<img src="./images/02-region-selection.png" width="350"><br>
<strong>Region Selection Screen</strong>
</td>
</tr>
</table>

2. Add/paste your PIA username/password details:

<p align="center">
  <img src="./images/03-interface-fields.png"
       alt="Interface fields"
       width="350">
</p>
<p align="center">
  <strong>Interface Fields</strong>
</p>

3. Optional - accept the default DNS servers (Quad 9: 9.9.9.9, 149.112.112.12) or enter your choice (e.g.,Cloudflare: 1.1.1.1, 1.0.0.1 ), use a comma to separate entries.

4. Tap the **GENERATE CONFIG** button.

5. After successful PIA authentication your chosen region's config file is displayed in the **GENERATED CONFIG** window. You can select specific text from this window or tap **COPY** to send the window contents to the clipboard (clipboard is cleared after 60 seconds).
   Use **SHARE / SAVE** to send the config file to a specific app e.g. your favourite file system app to save the generated conf file to a location of choice:

<table>
<tr>
<td align="center">
<img src="./images/04-generated-config.png" width="350"><br>
<strong>Generated config</strong>
</td>
<td align="center">
<img src="./images/06-share.png" width="350"><br>
<strong>Share</strong>
</td>
</tr>
</table>

6. Conf files are named per the region name (agreed, PIA isn't consistent with the region name format!)
7. Above the **GENERATED CONFIG** window there's a **CLEAR CREDS & CFG** button that removes your WireGuard credentials (config data, PIA username/password) from your device's screen and securely overwrites these variables from system memory. Next to that there's a countdown timer. After no activity for 3 minutes, your credentials are automatically wiped. The timer is reset when there's in app activity (scrolling, tapping etc).
   If you use the **COPY** button, the clipboard is cleared after 60 seconds automatically regardless of activity.

<p align="center">
  <img src="./images/06b-clipboard clearing.png"
       alt="Automated clipboard clear"
       width="350">
</p>
<p align="center">
  <strong>Automated clipboard clear</strong>
</p>

8. As above, at the bottom of the screen there's a scrollable "LOG" of processing/activity that can be cleared.

## Pushing the config to an ASUS router

Once a config has been generated, you can push it to an **ASUS router running [Asuswrt-Merlin](https://www.asuswrt-merlin.net/) firmware** over SSH without copying the `.conf` by hand!

1. Generate a config as described above
2. In the **GENERATED CONFIG** section tap **PUSH CONFIG TO ROUTER...**

<p align="center">
  <img src="./images/07-push-config-button.png"
       alt="Generated Config"
       width="350">
</p>
<p align="center">
  <strong>Router push dialog</strong>
</p>
   
3. On the **ROUTER SSH LOGIN** window, enter the router **IP**, **SSH username** and **SSH password**, then tap **CONNECT**. The app reads all five slots and flags the currently **ACTIVE** and **KILL SWITCH** slot.

<p align="center">
  <img src="./images/08-router-login.png"
       alt="Router login"
       width="350">
</p>
<p align="center">
  <strong>Router login</strong>
</p>

4. Select your target `wgc1`–`wgc5` slot, existing slot descriptions are shown so you can avoid overwriting one you want to keep, then tap **CONFIRM WRITE TO ROUTER**.

<p align="center">
  <img src="./images/09-select-slot.png"
       alt="Write to router"
       width="350">
</p>
<p align="center">
  <strong>Write to router</strong>
</p>

5. Below in the **LOG** you'll see the app stopping the active tunnel, backing up the chosen slot, writing the new configuration to NVRAM, starting the new tunnel, then verifying that the `wgc<slot>` appears in `wg show interfaces` (retried for up to 60 seconds) and reports the assigned local and public IP addresses.

<p align="center">
  <img src="./images/10-waiting-for-tunnel.png"
       alt="Write to router"
       width="350">
</p>
<p align="center">
  <strong>Write to router</strong>
</p>

6. On success the dialog closes and the router is running your new tunnel. On failure the previous slot config and the previously active tunnel are restored automatically, check the **LOG** for details.

<p align="center">
  <img src="./images/11-push-complete.png"
       alt="Push complete"
       width="350">
</p>
<p align="center">
  <strong>Push complete</strong>
</p>

All app processing is reported live in the in-app **LOG** panel including SSH commands, active-interface detection, slot backup, the NVRAM write/commit, the start sequence, and the up-to-60-second verification, so you always know exactly what is happening and what was done. If any step fails, the app automatically restores both the target slot's previous contents and the previously active tunnel, and logs the recovery so the router isn't left in a broken state.

> [!TIP]
> Activity during the push to router continually resets the 3-minute idle timer, so a long verification will not trigger the automatic session wipe.

### Push to router prerequisites

- An ASUS router running **Asuswrt-Merlin** firmware with WireGuard **client** support (slots `wgc1`–`wgc5`).
- **SSH access enabled** on the router (Administration → System → enable the _SSH Daemon_; LAN-only is recommended) and reachable from your device.
- The router's **LAN IP**, plus an **SSH username** and **password** (defaults to `192.168.0.254` / `admin`).
- A config already generated in the app, the **PUSH CONFIG TO ROUTER...** button only appears once a config is generated.

## Notes

- **Pre-shared keys**: PIA WireGuard does not (ASAICT) employ pre-shared keys. When pushing a config to the router, this field is always set to empty unless a push fails, then its original value is restored.
- **Time-to-live constraints**: PIA WireGuard configs expire every few weeks per PIA's token handling, requiring you to regenerate a config file periodically (which is why this app exists!).
- **Key safety**: the generated config contains private encryption keys. Treat them like a password and manage them securely.
  > [!CAUTION]
  >
  > **Push to router**: the app assumes that <b>only one WireGuard VPN is active at any time</b>, when you save the config to your router that "slot" will become the active VPN replacing any previously active slot and any slot with a <b>kill switch</b> will be deactivated and the kill switch together with NAT and firewalling will be applied to the newly created slot.

---

## What does push to router do to the router?

A great question to ask as anything that talks to your router programatically should be under extreme scrutiny. A lot of thinking, research, and analysis went into implementing this feature. It runs exactly the same sequence of activities that the web UI performs.

### In summary...

When you select a PIA region and push it to your router, the app connects directly to your router over your home network and switches your VPN tunnel to the new location. It first checks whether a VPN tunnel is already running, stops it cleanly, writes the new VPN server details into the router's permanent memory, and then starts the new tunnel. The app watches the router until it confirms the tunnel is active, then checks that internet traffic is actually flowing through it by verifying the public IP address your router is using. If anything goes wrong at any point, the app restores the router to exactly the state it was in before you started.

### In detail...

The push operation establishes an SSH session to the router and uses `wg show interfaces` to detect any currently active WireGuard client slot. If an existing slot config is present in NVRAM, the current `wgcN_*` keys are snapshotted as a backup before any changes are made. The active tunnel is stopped by disabling its `enforce` and `enable` NVRAM flags, committing, then issuing `service "stop_wgc N"; service start_vpnrouting0` targeted at that specific slot. The new configuration is written across the full set of NVRAM keys for the target slot, with `ep_addr_r` and `rip` explicitly cleared since these are populated dynamically by the firmware after tunnel establishment. After a single nvram commit, the new tunnel is started via `service "restart_wgc N"; service start_vpnrouting0`. The app then polls `wg show interfaces` for up to 60 seconds to confirm the interface is active, followed by polling `ipv4.icanhazip.com` (a service run and hosted by [Cloudflare](https://www.cloudflare.com/)) via curl through the tunnel to confirm routed connectivity. On any failure, independent recovery blocks restore the backed-up NVRAM keys and re-enable the previously active slot as appropriate to the failure scenario.

---

## App permissions

The app uses the following Android permissions:

### Internet (android.permission.INTERNET)

Required to:

- authenticate with Private Internet Access (PIA)
- retrieve VPN server information
- generate WireGuard configuration profiles
- perform latency and connectivity tests

No user traffic is routed through this application. The app communicates only with PIA provisioning and API endpoints required to generate configuration files.

### Network state (android.permission.ACCESS_NETWORK_STATE)

Required to:

- detect whether the device currently has network connectivity
- avoid unnecessary network requests when offline
- provide better error handling and diagnostics

### Storage access

The application can export generated WireGuard configuration files to the device.

#### Write external storage (android.permission.WRITE_EXTERNAL_STORAGE)

- used only on legacy Android versions (Android 9 and earlier)
- allows exported configuration files to be written to the Downloads folder

#### Read external storage (android.permission.READ_EXTERNAL_STORAGE)

- used only on older Android versions where required by the operating system
- allows the application to verify exported configuration files

---

## Security

We take credential safety and application hardening seriously. Please see the [SECURITY.md](./SECURITY.md) for details on our secure development practices, data handling lifecycle, and instructions on how to privately report potential vulnerabilities.

---

## Privacy

This application does not collect analytics, advertising identifiers, or personal usage data. Authentication credentials are used only to communicate with Private Internet Access services required to generate configuration files.

---

## Bugs and feature requests

Found a bug or want to request a feature? [Open an issue here](https://github.com/ExponentiallyDigital/pia-wireguard-cfga/issues).

---

## Support

This tool is unsupported and may cause objects in mirrors to be closer than they appear. Batteries not included.

---

## Trademark and affiliation notice

This is an independent, open-source utility released under the GNU General Public License v3.0. It requires an active Private Internet Access (PIA) account subscription to authenticate with the provisioning endpoints. This application is not affiliated with, endorsed by, sponsored by, or associated with Private Internet Access or WireGuard. WireGuard® is a registered trademark of Jason A. Donenfeld. Private Internet Access and PIA are trademarks of their respective owner.

---

## License

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses/>.

Copyright (C) 2026 Andrew Newbury.
