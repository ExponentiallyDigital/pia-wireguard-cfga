# Contributing to pia‑wireguard‑cfga

Thank you for your interest in contributing to **pia‑wireguard‑cfga** — a security‑sensitive, reproducible‑build Android application that generates Private Internet Access (PIA) WireGuard configurations and optionally deploys them to Asuswrt‑Merlin routers.

This document explains how to contribute safely, consistently, and in a way that aligns with the project’s security and build‑determinism goals.

---

## Project expectations

This project places strong emphasis on:

- **Security** (credential handling, memory safety, no persistence, certificate pinning)
- **Reproducible builds** (strict dependency pinning, deterministic CI)
- **Code quality** (Flutter analysis, high test coverage, SonarCloud, OSV scanning)
- **Supply‑chain hardening** (pinned GitHub Actions SHAs, SBOM generation)
- **Clear, auditable changes** (lockfile enforcement, structured PRs)

Contributions must respect these principles.

---

## How to contribute

### 1. Fork the repository

Create your own fork on GitHub and clone it locally.

### 2. Create a feature branch

Use a descriptive branch name:

```bash
git checkout -b feature/<short-description>
```

Examples:

- `feature/router-slot-validation`
- `fix/latency-probe-timeout`
- `docs/update-build-instructions`

### 3. Set up your development environment

Follow the build instructions from the README:

- Flutter SDK ≥ 3.10
- Android Studio + JDK 17
- Android SDK Command-line Tools
- Physical device or AVD
- Run:

```bash
flutter clean
flutter pub get --enforce-lockfile
dart run flutter_launcher_icons
```

### 4. Follow code style & quality rules

Before committing:

- Run static analysis

```bash
flutter analyze
```

```bash
- Format all Dart code
flutter format .
```

- Run tests

```bash
flutter test --coverage
```

> [!NOTE]
> This project targets **>90% test coverage**.  
> New features must include tests; PRs without tests will not be accepted.

### 5. Respect dependency pinning

This project uses **Gradle dependency locking in strict mode** and pinned Dart dependencies.

If you add or update dependencies:

1. Update the relevant Gradle or Dart manifest.
2. Regenerate lockfiles:

```bash
./android/gradlew -p android :dependencies :app:dependencies --write-locks
```

3. Commit the updated lockfiles.

PRs that modify dependencies **without updated lockfiles will fail CI**.

### 6. **GitHub Actions security requirements**

All GitHub Actions must be pinned to **full commit SHAs**, not tags.

If you modify workflows:

- Run the repository’s `update-shgas.ps1` script to regenerate pinned SHAs.
- Commit the updated workflow files.

### 7. Commit your changes

Use clear, conventional commit messages:

```bash
git commit -m "feat: add router slot description parsing"
git commit -m "fix: correct CA pinning fallback logic"
git commit -m "docs: update screenshots for tablet layout"
```

### 8. Push and open a pull request

```bash
git push origin feature/<short-description>
```

Then open a PR against `main`.

Your PR **must include**:

- A clear description of the change
- Test coverage for new logic
- Confirmation that `flutter analyze` passes
- Confirmation that lockfiles are updated (if applicable)
- Screenshots for UI changes (phone + tablet if relevant)

---

## Security‑sensitive contributions

Because this app handles:

- WireGuard private keys
- PIA credentials
- Router SSH credentials
- Certificate pinning
- Memory‑resident secrets

…any contribution that touches authentication, cryptography, memory handling, or router‑push logic will undergo **enhanced review**.

If you believe you have found a security issue:

Please **do not open a public issue.** Follow the private reporting process in **SECURITY.md**.

---

## Testing guidelines

All new features must include:

- Unit tests for logic in `lib/`
- Integration tests where applicable
- Router‑push logic tests using mocks (never real SSH)
- Tests for error paths, not just success paths

Coverage reports can be generated with:

```bash
flutter test --coverage
fcr coverage/lcov.info --open
```

---

## Build determinism requirements

To maintain reproducible builds:

- Never commit keystore files
- Never commit generated artifacts
- Never modify CI signing logic
- Never introduce dynamic or floating dependency versions
- Never bypass lockfile enforcement

If a PR breaks reproducibility, it will be rejected.

---

## Documentation contributions

Documentation updates are welcome.  
When updating screenshots:

- Provide phone + 7" + 10" tablet screenshots (as in README)
- Use consistent dark‑mode theme (`#12141A`)
- Place images under `/images/` with descriptive filenames

---

## Bugs & feature requests

Use the GitHub Issues page:

- Provide reproduction steps
- Include device model + Android version
- Include relevant log output (sanitised)
- For router issues, include router model + Merlin version

---

## Code of conduct

Be respectful, constructive, and security‑minded.  
This project values:

- Clear communication
- Evidence‑based reasoning
- High‑quality engineering
- Respect for user privacy and safety

---

## Licensing

By contributing, you agree that your contributions will be licensed under the **GNU GPLv3**, the same license as the project.

---

## Thank you

We deeply appreciate security researchers and contributors who help keep this project safe.
Your efforts directly protect users’ privacy, routers, and VPN credentials. If you have questions about this policy, please [open an issue](https://github.com/ExponentiallyDigital/pia-wireguard-cfga/issues) and/or see **SECURITY.md**.
