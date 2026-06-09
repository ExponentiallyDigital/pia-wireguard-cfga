context.md

# context.md — Coverage uplift for `lib/main.dart`

## Goal

Raise `lib/main.dart` line coverage from **66.4%** (`lcov: LF:372, LH:247`) to **≥90%**.

## Project facts

- Flutter 3.44.1 (stable) / Dart 3.12.1, Windows 11.
- App: `PiaWgApp` → `MainScreen` (StatefulWidget). It generates PIA WireGuard configs.
- `_MainScreenState` owns a hard-constructed `final _service = PiaService()` (no DI).
- `PiaService` (in `lib/pia_service.dart`) uses **`dart:io HttpClient`** for HTTP and a
  **real `Socket.connect`** for latency probing.

## Why the previous attempts only reached 66%

The committed (Gemini) `test/unit/main_unit_test.dart` was mostly placeholders:
`if (find.byKey(Key('username_field')).evaluate().isNotEmpty)` — but those keys don't
exist in `main.dart`, so the bodies never ran. Tests "passed" while covering nothing.

**~125 uncovered lines are all "post-generate" code** — they only execute after a config
is successfully generated: `_clearSession`, `_startOrResetTimer`, the `_generate` success
tail (lines 257–290), `_copyToClipboard`, `_clearClipboard`, `_shareConfig`,
`_buildTimerWidget`, `_buildGeneratedConfigSection`, `_showRouterPushSheet`, and the
`didChangeAppLifecycleState` resume branch (131–146).

## The two real blockers (this is the key insight)

1. **Real socket.** `PiaService.probeLatency()` does
   `Socket.connect(server.ip, 1337, timeout: 2s)`. `HttpOverrides` fakes `HttpClient` but
   **not** `Socket`. With a fake IP all probes fail → `generateConfig` throws
   _"All latency probes failed."_ → config never set → post-generate UI never renders.
   **Fix:** bind a real `ServerSocket` on `127.0.0.1:1337` and use `ip = '127.0.0.1'`.
2. **Real cert parse.** `PiaService.registerKey()` runs
   `SecurityContext(withTrustedRoots: false)..setTrustedCertificatesBytes(utf8.encode(caCertPem))`.
   This actually parses the PEM and **throws on invalid input**.
   **Fix:** serve a real, valid self-signed PEM for the CA-cert URL.

## Existing test infra we reuse

`test/http_test_helpers.dart` already provides `withFakeHttpClient(body, factory)` +
`FakeHttpClientResponse`, faking `HttpClient` via `HttpOverrides.runZoned`. Its
`FakeHttpClient` presents `FakeX509Certificate('CN=server-cn')` to
`badCertificateCallback`, so the fake region's `cn` **must be `server-cn`** for
`registerKey`'s pin check (`cert.subject.contains('CN=${server.cn}')`) to pass.

## What stays uncovered (acceptable, ~7 lines)

Timer/lifecycle "deadline ≤ 0" branches (133, 144, 195–196, 511–512) use real
`DateTime.now()`, which doesn't advance in tests; line 668 is a closure never invoked.
Realistic ceiling ≈ 96–98%.
