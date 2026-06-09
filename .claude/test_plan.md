# test_plan.md

All tests live in one self-contained file: `test/unit/main_unit_test.dart`.
Run with `flutter test --coverage` (aggregates with the other suites too).

## Shared fixtures

- `_serverListBody()` — JSON with one region `us_test`, server `{ip: 127.0.0.1, cn: server-cn}` + trailing `\n` (PiaService splits on first newline).
- `_kTestCertPem` — a real self-signed cert so `setTrustedCertificatesBytes` succeeds.
- `_fakeResponses(url, method)` — routes the 4 HTTP calls by URL substring
  (`vpninfo/servers/v6`, `generateToken`, `ca.rsa.4096.crt`, `addKey`).
- `_installPluginMocks(tester)` — Clipboard, url_launcher, path_provider, share_plus.
- `_driveUntil(...)` — `runAsync(Future.delayed)` + `pump` loop so the **real socket**
  and fake-async HTTP inside `generateConfig` actually complete.
- A real `ServerSocket` on `127.0.0.1:1337` (setUp/tearDown) for the generate group.

## Cases → coverage

| #   | Test                                              | Lines covered                                                                                      |
| --- | ------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| 1   | builds MaterialApp + MainScreen home              | `PiaWgApp.build`, initial state                                                                    |
| 2   | empty creds → validation error, then CLEAR LOG    | `_generate` 234–241; log clear                                                                     |
| 3   | password visibility toggle                        | 438                                                                                                |
| 4   | version link tap launches URL                     | `_launchUrlStr` 295–300, **364**                                                                   |
| 5   | region picker: load + filter + select             | `_loadRegions` 203–232, `_RegionPickerSheet` 769–845, filter **802**                               |
| 6   | region picker failure (HTTP 500)                  | 225–226                                                                                            |
| 7   | **generate → config section → CLEAR CREDS & CFG** | 257–262, 519–624, `_startOrResetTimer` 184–198, `_clearSession` 169–181, `_clearClipboard` 482–488 |
| 8   | **generate → COPY → lifecycle resume**            | `_copyToClipboard` 491–514, lifecycle 131–146                                                      |
| 9   | **generate → SHARE/SAVE**                         | `_shareConfig` 273–290                                                                             |
| 10  | **generate → PUSH CONFIG TO ROUTER**              | `_showRouterPushSheet` 626–647                                                                     |

## Cleanup

Each generate test ends with `pumpWidget(const SizedBox())` → `State.dispose` cancels
`_wipeTimer`/`_clipboardTimer` → no "Timer still pending" failure.

## Expected result

`lib/main.dart` ≈ 96–98% line coverage (comfortably ≥ 90%).
