// pia_service.dart
// Optimized WireGuard provisioning engine. Native HttpClient, concurrent probing.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:x25519/x25519.dart' as x25519;

class WgServer {
  final String ip, cn;
  const WgServer({required this.ip, required this.cn});
}

class Region {
  final String id;
  final List<WgServer> wgServers;
  const Region({required this.id, required this.wgServers});
}

class ProbeResult {
  final WgServer server;
  final Duration? latency;
  const ProbeResult({required this.server, this.latency});
  bool get failed => latency == null;
}

class RegResponse {
  final String status, serverKey, peerIP;
  final int serverPort;
  const RegResponse({
    required this.status,
    required this.serverKey,
    required this.peerIP,
    required this.serverPort,
  });

  factory RegResponse.fromJson(Map<String, dynamic> json) => RegResponse(
        status: json['status'] ?? '',
        serverKey: json['server_key'] ?? '',
        peerIP: json['peer_ip'] ?? '',
        serverPort: json['server_port'] ?? 0,
      );
}

class PiaService {
  static const _serverListUrl =
      'https://serverlist.piaservers.net/vpninfo/servers/v6';
  static const _tokenUrl =
      'https://www.privateinternetaccess.com/gtoken/generateToken';
  static const _caCertUrl =
      'https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt';

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  // Helper for native GET request strings
  Future<String> _httpGet(String url) async {
    final request = await _client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    return response.transform(utf8.decoder).join();
  }

  // Fetch and map the system regions list
  Future<List<Region>> fetchRegions({void Function(String)? onProgress}) async {
    onProgress?.call('Fetching PIA server list...');
    try {
      final body = await _httpGet(_serverListUrl);
      final newlineIdx = body.indexOf('\n');
      if (newlineIdx == -1) {
        throw Exception('Format error');
      }

      final decoded =
          jsonDecode(body.substring(0, newlineIdx)) as Map<String, dynamic>;
      final rawRegions = decoded['regions'] as List? ?? [];

      final regions = rawRegions
          .map((r) {
            final servers = r['servers'] as Map<String, dynamic>? ?? {};
            return Region(
              id: r['id'] ?? '',
              wgServers: (servers['wg'] as List? ?? [])
                  .map((s) => WgServer(ip: s['ip'] ?? '', cn: s['cn'] ?? ''))
                  .toList(),
            );
          })
          .where((r) => r.wgServers.isNotEmpty)
          .toList();

      return regions..sort((a, b) => a.id.compareTo(b.id));
    } catch (e) {
      throw Exception('Server list error: $e');
    }
  }

  // Measures TCP latency concurrently to maximize execution speed
  Future<List<ProbeResult>> probeLatency(List<WgServer> servers,
      {void Function(String)? onProgress}) async {
    onProgress?.call('Probing latencies concurrently...');

    final tasks = servers.map((server) async {
      try {
        final start = DateTime.now();
        final socket = await Socket.connect(server.ip, 1337,
            timeout: const Duration(seconds: 2));
        final latency = DateTime.now().difference(start);
        await socket.close();
        onProgress
            ?.call('  ${server.ip} responded in ${latency.inMilliseconds}ms');
        return ProbeResult(server: server, latency: latency);
      } catch (e) {
        onProgress?.call('  ${server.ip} failed: $e');
        return ProbeResult(server: server);
      }
    });

    final results = await Future.wait(tasks);
    return results
      ..sort((a, b) {
        if (a.failed) {
          return 1;
        }
        if (b.failed) {
          return -1;
        }
        return a.latency!.compareTo(b.latency!);
      });
  }

  // Request operational token via HTTP Basic Auth
  Future<String> getToken(String username, String password,
      {void Function(String)? onProgress}) async {
    onProgress?.call('Authenticating with PIA...');
    try {
      final request = await _client.postUrl(Uri.parse(_tokenUrl));
      final credentials = base64Encode(utf8.encode('$username:$password'));
      request.headers
          .set(HttpHeaders.authorizationHeader, 'Basic $credentials');
      final response = await request.close();
      // 1. Read the response body payload regardless of the status code
      final body = await response.transform(utf8.decoder).join();
      // 2. Handle non-200 status codes with the response body included
      if (response.statusCode != 200) {
        String detailedError = body;
        try {
          // Attempt to extract cleaner text if the server responds with a JSON message
          final parsedJson = jsonDecode(body);
          if (parsedJson is Map && parsedJson.containsKey('message')) {
            detailedError = parsedJson['message'];
          } else if (parsedJson is Map && parsedJson.containsKey('error')) {
            detailedError = parsedJson['error'];
          }
        } catch (_) {
          // If body is not JSON (plain text or HTML), keep it as-is
        }
        throw Exception('HTTP ${response.statusCode} - $detailedError');
      }

      final token =
          (jsonDecode(body) as Map<String, dynamic>)['token'] as String? ?? '';
      if (token.isEmpty) {
        throw Exception('Empty token received');
      }

      onProgress?.call('Authentication successful.');
      return token;
    } catch (e) {
      throw Exception('Auth error: $e');
    }
  }

  // Generates WireGuard keypair using secure random bytes and scalar clamping
  (String, String) generateWgKeypair() {
    final priv = Uint8List.fromList(
        List.generate(32, (_) => Random.secure().nextInt(256)));
    priv[0] &= 248;
    priv[31] &= 127;
    priv[31] |= 64;
    return (
      base64Encode(priv),
      base64Encode(x25519.X25519(priv, x25519.basePoint))
    );
  }

  // Registers WireGuard public key using custom SecurityContext pinning
  Future<RegResponse> registerKey(
      WgServer server, String token, String publicKeyB64,
      {void Function(String)? onProgress}) async {
    final caCertPem = await _httpGet(_caCertUrl);
    onProgress?.call('Registering key with ${server.ip}...');

    final secCtx = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(caCertPem));
    final localClient = HttpClient(context: secCtx)
      ..badCertificateCallback = (_, __, ___) => true;

    try {
      final uri = Uri.parse(
        'https://${server.ip}:1337/addKey?pt=${Uri.encodeQueryComponent(token)}&pubkey=${Uri.encodeQueryComponent(publicKeyB64)}',
      );
      final request = await localClient.getUrl(uri)
        ..headers.host = server.cn;
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}\n$body');
      }

      final reg = RegResponse.fromJson(jsonDecode(body));
      if (reg.status != 'OK') {
        throw Exception('Status: "${reg.status}"');
      }

      onProgress?.call('Key registered. Peer IP: ${reg.peerIP}');
      return reg;
    } finally {
      localClient.close(force: true);
    }
  }

  // Compiles parameters into a unified system WireGuard string payload
  String buildConfig({
    required String privateKey,
    required String peerIP,
    required String dns,
    required String serverKey,
    required String serverIP,
    required int serverPort,
  }) {
    final cleanIP = peerIP.split('/').first;
    return '[Interface]\nPrivateKey = $privateKey\nAddress = $cleanIP/32\nDNS = $dns\nMTU = 1420\n\n'
        '[Peer]\nPublicKey = $serverKey\nEndpoint = $serverIP:$serverPort\nPersistentKeepalive = 25\nAllowedIPs = 0.0.0.0/0\n';
  }

  // Main system engine pipeline flow orchestrator
  Future<String> generateConfig({
    required String region,
    required String username,
    required String password,
    required String dns,
    void Function(String)? onProgress,
  }) async {
    final regions = await fetchRegions(onProgress: onProgress);
    final selected = regions.firstWhere((r) => r.id == region, orElse: () {
      throw Exception('Region "$region" not found.');
    });
    if (selected.wgServers.isEmpty) {
      throw Exception('No WG servers in region.');
    }

    final probeResults =
        await probeLatency(selected.wgServers, onProgress: onProgress);
    final responding = probeResults.where((r) => !r.failed).toList();
    if (responding.isEmpty) {
      throw Exception('All latency probes failed.');
    }

    final bestServer = responding.first.server;
    final bestLatency = responding.first.latency?.inMilliseconds ?? 0;
    onProgress?.call(
        'Selected ${bestServer.ip} ${bestServer.cn.toLowerCase()} ${bestLatency}ms');

    final token = await getToken(username, password, onProgress: onProgress);

    onProgress?.call('Generating WireGuard keypair...');
    final (privateKey, publicKey) = generateWgKeypair();
    final reg =
        await registerKey(bestServer, token, publicKey, onProgress: onProgress);

    return buildConfig(
      privateKey: privateKey,
      peerIP: reg.peerIP,
      dns: dns.isEmpty ? '9.9.9.9, 149.112.112.112' : dns,
      serverKey: reg.serverKey,
      serverIP: bestServer.ip,
      serverPort: reg.serverPort,
    );
  }
}
