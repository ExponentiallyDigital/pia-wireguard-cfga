// test/unit/main_unit_test.dart
//
// High-coverage tests for lib/main.dart.
//
// Why naive tests only reach ~66%: nearly all uncovered code in main.dart runs
// ONLY after a WireGuard config is successfully generated. Driving that path
// requires defeating two real-I/O blockers that HttpOverrides alone does NOT
// handle:
//   1) PiaService.probeLatency() does a REAL Socket.connect(ip, 1337). We satisfy
//      it by binding a real ServerSocket on 127.0.0.1:1337 during each test.
//   2) PiaService.registerKey() really parses the downloaded CA cert via
//      SecurityContext.setTrustedCertificatesBytes(); we feed it a real valid PEM.
// Combined with the project's existing FakeHttpClient (HttpOverrides) for the four
// HTTP calls, generateConfig() runs end-to-end with no network access.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pia_wireguard_cfga/main.dart';
import 'package:pia_wireguard_cfga/router_push_sheet.dart';

import '../http_test_helpers.dart';

// Region id we type into the form and serve from the fake server list.
const String _kRegion = 'us_test';

// MUST equal the CN the project's FakeHttpClient presents to badCertificateCallback
// (FakeX509Certificate('CN=server-cn')) so registerKey's pin check passes.
const String _kCn = 'server-cn';

// A real, valid self-signed certificate so SecurityContext.setTrustedCertificatesBytes
// in PiaService.registerKey() succeeds (that call actually parses these bytes).
const String _kTestCertPem = '''-----BEGIN CERTIFICATE-----
MIIDDTCCAfWgAwIBAgIULc36dwyl3c58/o2Cbi+MC1pqvp0wDQYJKoZIhvcNAQEL
BQAwFjEUMBIGA1UEAwwLUElBLVRlc3QtQ0EwHhcNMjYwNjA5MTgzOTA1WhcNMzYw
NjA2MTgzOTA1WjAWMRQwEgYDVQQDDAtQSUEtVGVzdC1DQTCCASIwDQYJKoZIhvcN
AQEBBQADggEPADCCAQoCggEBAOerejlSVzdHVHyM2Lz+Z2Zw7n06iMIs2Bv6cBCZ
bOyIMubdn7gHioWn0DMDedYlKHJbDFTAWYRtovcown2rVhTILYHyrBkRHjOwjtwu
6S0fSI4Obt/ZmdIGhci+JrdjqRCJYYul9X9cWKo3q269Uq5E7nhLgIO/N4DdB3UL
a6zW9xX0JX+adNHqs31mFdhcjIDfoHbg/WTTbwb1yj562GDKcKxXt4j3JxCa7QJA
fWPqEPKfrgMBxR8JITedhtDgIoUXbOEJWLxII5hAFtTYAcs2k/9IpE+zbcRMtgNB
ljt/lw6a1YI3Zw+mcyAr/3HmfPbNp4DM496sQHMF3UAW/6UCAwEAAaNTMFEwHQYD
VR0OBBYEFHpsZ/WOyV8vozOW4JiaNxFhzfcXMB8GA1UdIwQYMBaAFHpsZ/WOyV8v
ozOW4JiaNxFhzfcXMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEB
AFkIETEtEBbRzur2IDXwptrk8nogS0QJwGzKMMlMyl+GH2/o77BewK3MzdzwgPUO
2aYvjd5zfCQ9MHldj4H+yG+Qa92FuzihcZhGBiuDcuL84T6Q+FDgeTWCej5BkzYg
HS+jUBJxOVwt83DEaBgYqn7k2je6kyB/Q9/g6Y/FsDdKEllTSdRgpOGOxRDB+j8J
x0xpEworH0XBzRKwwIwzbGUH9sA4BuFTFUIloFFjsN1X/wDxxtF9vueZsCeXP1QL
MQRWTK4MMjOHQQ4tGnOJ0pThj2Au4XwOnU6S1nrcMJ9jb5srad2TH6BQFLe4uwrC
1JXQGhGiJI6sr78U1FRmSV0=
-----END CERTIFICATE-----''';

String _serverListBody() =>
    '${jsonEncode({
          'regions': [
            {
              'id': _kRegion,
              'servers': {
                'wg': [
                  {'ip': '127.0.0.1', 'cn': _kCn}
                ]
              }
            }
          ]
        })}\n';

// Routes the four HTTP calls PiaService makes during generateConfig().
FakeHttpClientResponse _fakeResponses(Uri url, String method) {
  final u = url.toString();
  if (u.contains('vpninfo/servers/v6')) {
    return FakeHttpClientResponse(200, _serverListBody());
  }
  if (u.contains('generateToken')) {
    return FakeHttpClientResponse(200, '{"token":"test-token"}');
  }
  if (u.contains('ca.rsa.4096.crt')) {
    return FakeHttpClientResponse(200, _kTestCertPem);
  }
  if (u.contains('addKey')) {
    return FakeHttpClientResponse(
        200,
        '{"status":"OK","server_key":"c2VydmVycHVia2V5",'
        '"peer_ip":"10.7.7.2/32","server_port":1337}');
  }
  return FakeHttpClientResponse(404, 'not found');
}

// In-memory handlers for every platform plugin main.dart touches, so no
// MissingPluginException escapes an un-try/catch'd line (e.g. getTemporaryDirectory,
// which is OUTSIDE _shareConfig's try block).
void _installPluginMocks(WidgetTester tester) {
  final messenger = tester.binding.defaultBinaryMessenger;
  final clip = <String, Object?>{'text': ''};

  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      clip['text'] = (call.arguments as Map)['text'];
      return null;
    }
    if (call.method == 'Clipboard.getData') {
      return <String, Object?>{'text': clip['text']};
    }
    return null;
  });

  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/url_launcher'),
    (call) async => true,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => Directory.systemTemp.path,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/share'),
    (call) async => 'dev.fluttercommunity.plus/share success',
  );
}

// Pump frames while giving the REAL event loop time (via runAsync) so the real
// Socket.connect plus the fake-async HTTP inside generateConfig() can complete.
Future<void> _driveUntil(WidgetTester tester, bool Function() done,
    {int maxIterations = 150}) async {
  for (var i = 0; i < maxIterations; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump();
    if (done()) return;
  }
}

// Pump PiaWgApp, fill the form, tap GENERATE, and wait until the success log line
// appears (config now present). Caller must have bound 127.0.0.1:1337 and be
// running inside withFakeHttpClient.
Future<void> _generate(WidgetTester tester) async {
  // Use a tall surface so the whole scrolling column (incl. the post-generate
  // COPY / SHARE / PUSH / CLEAR buttons) is on-screen and tappable. The default
  // 800x600 test window pushes those buttons below the fold.
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(const PiaWgApp());
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextFormField).at(0), _kRegion);
  await tester.enterText(find.byType(TextFormField).at(1), 'p1234567');
  await tester.enterText(find.byType(TextFormField).at(2), 'secret-pass');
  await tester.pump();

  await tester.tap(find.text('GENERATE CONFIG'));
  await _driveUntil(
    tester,
    () => find
        .textContaining('Config generated successfully')
        .evaluate()
        .isNotEmpty,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PiaWgApp shell', () {
    testWidgets('builds MaterialApp with MainScreen home', (tester) async {
      await tester.pumpWidget(const PiaWgApp());
      await tester.pumpAndSettle();

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.title, 'PIA WireGuard Config');
      expect(app.debugShowCheckedModeBanner, isFalse);
      expect(find.byType(MainScreen), findsOneWidget);
      expect(find.text('GENERATE CONFIG'), findsOneWidget);
      expect(find.text('Ready.'), findsOneWidget);
    });

    testWidgets('empty credentials log a validation error and clear works',
        (tester) async {
      await tester.pumpWidget(const PiaWgApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('GENERATE CONFIG'));
      await tester.pump();

      expect(find.textContaining('required'), findsOneWidget);
      expect(find.text('CLEAR LOG'), findsOneWidget);

      await tester.tap(find.text('CLEAR LOG'));
      await tester.pump();
      expect(find.text('Ready.'), findsOneWidget);
    });

    testWidgets('password visibility toggles', (tester) async {
      await tester.pumpWidget(const PiaWgApp());
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.visibility), findsOneWidget);
      await tester.tap(find.byIcon(Icons.visibility));
      await tester.pump();
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    });

    testWidgets('version link tap launches a URL', (tester) async {
      _installPluginMocks(tester);
      await tester.pumpWidget(const PiaWgApp());
      await tester.pumpAndSettle();

      // Tapping the FutureBuilder hits the InkWell that wraps it (the version link).
      await tester.tap(find.byType(FutureBuilder<PackageInfo>));
      await tester.pump();
      // Success == no MissingPluginException escaped from _launchUrlStr.
    });
  });

  group('Region picker (HTTP faked, no probe needed)', () {
    testWidgets('loads, filters and selects a region', (tester) async {
      await withFakeHttpClient(() async {
        await tester.pumpWidget(const PiaWgApp());
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.list_alt));
        await tester.pumpAndSettle();

        expect(find.text(_kRegion), findsOneWidget);

        // The picker's filter is the LAST TextField in the tree (it's in the
        // modal sheet, added after the 4 form fields).
        await tester.enterText(find.byType(TextField).last, 'us_');
        await tester.pumpAndSettle();
        expect(find.text(_kRegion), findsOneWidget);

        await tester.tap(find.text(_kRegion));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextFormField, _kRegion), findsOneWidget);
      }, _fakeResponses);
    });

    testWidgets('failure logs an error and restores the browse button',
        (tester) async {
      await withFakeHttpClient(
        () async {
          await tester.pumpWidget(const PiaWgApp());
          await tester.pumpAndSettle();

          await tester.tap(find.byIcon(Icons.list_alt));
          await tester.pumpAndSettle();

          expect(find.textContaining('Failed to load regions'), findsOneWidget);
          expect(find.byIcon(Icons.list_alt), findsOneWidget);
        },
        (url, method) => FakeHttpClientResponse(500, 'down'),
      );
    });
  });

  group('Full generate path (real loopback socket + valid cert)', () {
    late ServerSocket probeServer;
    late StreamSubscription<Socket> probeSub;

    setUp(() async {
      // Real listener so PiaService.probeLatency()'s Socket.connect(ip, 1337)
      // succeeds. The project's dart_test.yaml (concurrency: 1) serialises the
      // suites so this never collides with pia_service_test's 1337 listener.
      probeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 1337);
      probeSub = probeServer.listen((s) => s.destroy());
    });

    tearDown(() async {
      await probeSub.cancel();
      await probeServer.close();
    });

    testWidgets('generates config, shows section, then clears session',
        (tester) async {
      _installPluginMocks(tester);
      await withFakeHttpClient(() async {
        await _generate(tester);

        expect(find.text('GENERATED CONFIG'), findsOneWidget);
        expect(find.text('COPY'), findsOneWidget);
        expect(find.text('SHARE / SAVE'), findsOneWidget);
        expect(find.text('PUSH CONFIG TO ROUTER...'), findsOneWidget);
        // Session timer widget is visible (seconds remaining > 0).
        expect(find.byIcon(Icons.timer_outlined), findsOneWidget);

        // Fire the periodic session timer once.
        await tester.pump(const Duration(seconds: 1));

        await tester.tap(find.text('CLEAR CREDS & CFG'));
        await tester.pump();
        await tester.pump();

        expect(find.text('GENERATED CONFIG'), findsNothing);
        expect(find.textContaining('Session cleared'), findsOneWidget);
      }, _fakeResponses);

      await tester.pumpWidget(const SizedBox()); // dispose -> cancel timers
      await tester.pump();
    });

    testWidgets('copy to clipboard and lifecycle resume re-sync',
        (tester) async {
      _installPluginMocks(tester);
      await withFakeHttpClient(() async {
        await _generate(tester);

        await tester.tap(find.text('COPY'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1)); // clipboard timer tick
        expect(find.textContaining('Clearing clipboard in'), findsOneWidget);

        // Simulate a background round-trip and return (deadlines still in the
        // future). AppLifecycleListener only permits valid state transitions, so
        // we walk down then back up to 'resumed'.
        final dynamic binding = tester.binding;
        for (final state in const [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          binding.handleAppLifecycleStateChanged(state);
          await tester.pump();
        }
      }, _fakeResponses);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('share/save runs the export path', (tester) async {
      _installPluginMocks(tester);
      await withFakeHttpClient(() async {
        await _generate(tester);

        await tester.tap(find.text('SHARE / SAVE'));
        // Give the real temp-file write/share/cleanup real event-loop time.
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 25)));
          await tester.pump();
        }
        // Reaching here with the section still present == no unhandled exception
        // escaped _shareConfig.
        expect(find.text('GENERATED CONFIG'), findsOneWidget);
      }, _fakeResponses);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('opens the router push sheet', (tester) async {
      _installPluginMocks(tester);
      await withFakeHttpClient(() async {
        await _generate(tester);

        await tester.tap(find.text('PUSH CONFIG TO ROUTER...'));
        await tester.pumpAndSettle();
        expect(find.byType(RouterPushSheet), findsOneWidget);
      }, _fakeResponses);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
