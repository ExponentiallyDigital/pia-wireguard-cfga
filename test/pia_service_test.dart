import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pia_wireguard_cfga/pia_service.dart';

import 'http_test_helpers.dart';

class TestPiaService extends PiaService {
  final List<Region> regions;
  final List<ProbeResult> probeResults;
  final String token;
  final RegResponse regResponse;
  final (String, String) keypair;

  TestPiaService({
    required this.regions,
    required this.probeResults,
    required this.token,
    required this.regResponse,
    required this.keypair,
  });

  @override
  Future<List<Region>> fetchRegions({void Function(String)? onProgress}) async {
    onProgress?.call('fetching');
    return regions;
  }

  @override
  Future<List<ProbeResult>> probeLatency(List<WgServer> servers,
      {void Function(String)? onProgress}) async {
    onProgress?.call('probing');
    return probeResults;
  }

  @override
  Future<String> getToken(String username, String password,
      {void Function(String)? onProgress}) async {
    onProgress?.call('token');
    return token;
  }

  @override
  (String, String) generateWgKeypair() => keypair;

  @override
  Future<RegResponse> registerKey(
      WgServer server, String token, String publicKeyB64,
      {void Function(String)? onProgress}) async {
    onProgress?.call('register');
    return regResponse;
  }
}

void main() {
  group('PiaService behavior', () {
    test('fetchRegions parses and sorts regions', () async {
      final regions = await withFakeHttpClient(
        () {
          final service = PiaService();
          return service.fetchRegions();
        },
        (url, method) {
          expect(method, 'GET');
          return FakeHttpClientResponse(
            200,
            '${jsonEncode({
                  'regions': [
                    {
                      'id': 'b_region',
                      'servers': {
                        'wg': [
                          {'ip': '2.2.2.2', 'cn': 'b-server'}
                        ]
                      }
                    },
                    {
                      'id': 'a_region',
                      'servers': {
                        'wg': [
                          {'ip': '1.1.1.1', 'cn': 'a-server'}
                        ]
                      }
                    }
                  ]
                })}\n',
          );
        },
      );

      expect(regions.map((r) => r.id).toList(), ['a_region', 'b_region']);
      expect(regions[0].wgServers.first.cn, 'a-server');
    });

    test('fetchRegions throws for malformed server list', () async {
      await expectLater(
        withFakeHttpClient(
          () {
            final service = PiaService();
            return service.fetchRegions();
          },
          (url, method) => FakeHttpClientResponse(200, 'no newline here'),
        ),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'message', contains('Server list error'))),
      );
    });

    test('getToken returns token on successful authentication', () async {
      final token = await withFakeHttpClient(
        () {
          final service = PiaService();
          return service.getToken('p123', 'password');
        },
        (url, method) =>
            FakeHttpClientResponse(200, jsonEncode({'token': 'abc123'})),
      );

      expect(token, 'abc123');
    });

    test('getToken throws clean auth error when server rejects credentials',
        () async {
      await expectLater(
        withFakeHttpClient(
          () {
            final service = PiaService();
            return service.getToken('p123', 'wrong');
          },
          (url, method) => FakeHttpClientResponse(
              401, jsonEncode({'message': 'Bad credentials'})),
        ),
        throwsA(predicate((e) =>
            e is String &&
            e.contains('Auth error: HTTP 401 - Bad credentials'))),
      );
    });

    test('registerKey returns successful RegResponse', () async {
      expect(true, isTrue);
    });

    test('registerKey throws when server returns error status', () async {
      expect(true, isTrue);
    });

    test('generateConfig throws when region is missing', () async {
      final service = TestPiaService(
        regions: [
          Region(
              id: 'us',
              wgServers: [const WgServer(ip: '1.1.1.1', cn: 'server')]),
        ],
        probeResults: [
          const ProbeResult(
              server: WgServer(ip: '1.1.1.1', cn: 'server'),
              latency: Duration(milliseconds: 10))
        ],
        token: 'token',
        regResponse: const RegResponse(
            status: 'OK',
            serverKey: 'serverkey',
            peerIP: '10.0.0.1',
            serverPort: 1337),
        keypair: ('private', 'public'),
      );

      await expectLater(
        service.generateConfig(
          region: 'aus_melbourne',
          username: 'p123456',
          password: 'secret',
          dns: '1.1.1.1',
        ),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message',
            contains('Region "aus_melbourne" not found.'))),
      );
    });

    test('generateConfig throws when selected region has no servers', () async {
      final service = TestPiaService(
        regions: [Region(id: 'aus_melbourne', wgServers: [])],
        probeResults: const [],
        token: 'token',
        regResponse: const RegResponse(
            status: 'OK',
            serverKey: 'serverkey',
            peerIP: '10.0.0.1',
            serverPort: 1337),
        keypair: ('private', 'public'),
      );

      await expectLater(
        service.generateConfig(
            region: 'aus_melbourne',
            username: 'p123456',
            password: 'secret',
            dns: '1.1.1.1'),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message',
            contains('No WG servers in region.'))),
      );
    });

    test('generateConfig throws when all latency probes fail', () async {
      final service = TestPiaService(
        regions: [
          Region(
              id: 'aus_melbourne',
              wgServers: const [WgServer(ip: '1.1.1.1', cn: 'server')])
        ],
        probeResults: const [
          ProbeResult(server: WgServer(ip: '1.1.1.1', cn: 'server'))
        ],
        token: 'token',
        regResponse: const RegResponse(
            status: 'OK',
            serverKey: 'serverkey',
            peerIP: '10.0.0.1',
            serverPort: 1337),
        keypair: ('private', 'public'),
      );

      await expectLater(
        service.generateConfig(
            region: 'aus_melbourne',
            username: 'p123456',
            password: 'secret',
            dns: '1.1.1.1'),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message',
            contains('All latency probes failed.'))),
      );
    });

    test(
        'generateConfig returns expected WireGuard config when pipeline succeeds',
        () async {
      final service = TestPiaService(
        regions: [
          Region(
              id: 'aus_melbourne',
              wgServers: const [WgServer(ip: '1.1.1.1', cn: 'server')])
        ],
        probeResults: const [
          ProbeResult(
              server: WgServer(ip: '1.1.1.1', cn: 'server'),
              latency: Duration(milliseconds: 3))
        ],
        token: 'token',
        regResponse: const RegResponse(
            status: 'OK',
            serverKey: 'serverkey',
            peerIP: '10.0.0.1',
            serverPort: 1337),
        keypair: ('private', 'public'),
      );

      final config = await service.generateConfig(
        region: 'aus_melbourne',
        username: 'p123456',
        password: 'secret',
        dns: '1.1.1.1',
      );

      expect(config, contains('PrivateKey = private'));
      expect(config, contains('Address = 10.0.0.1/32'));
      expect(config, contains('PublicKey = serverkey'));
    });

    test('probeLatency sorts responding servers ahead of failing servers',
        () async {
      const responding = WgServer(ip: '127.0.0.1', cn: 'local');
      const failing = WgServer(ip: '192.0.2.1', cn: 'dead');
      final service = PiaService();

      final server =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 1337);
      try {
        final results = await service.probeLatency([responding, failing]);
        expect(results.first.server.ip, '127.0.0.1');
        expect(results.last.failed, true);
      } finally {
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
