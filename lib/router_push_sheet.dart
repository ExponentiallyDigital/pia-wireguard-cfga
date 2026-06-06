import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dartssh2/dartssh2.dart';

class RouterPushSheet extends StatefulWidget {
  final String config;
  final String regionId;
  final void Function(String, {bool isError, bool isSuccess}) onLog;
  final VoidCallback? onActivity;

  const RouterPushSheet({
    super.key,
    required this.config,
    required this.regionId,
    required this.onLog,
    this.onActivity,
  });

  @override
  State<RouterPushSheet> createState() => _RouterPushSheetState();
}

class _RouterPushSheetState extends State<RouterPushSheet> {
  final _ipCtrl = TextEditingController(text: '192.168.1.1');
  final _userCtrl = TextEditingController(text: 'admin');
  final _passCtrl = TextEditingController();

  int _step = 0; // 0 = credentials, 1 = slot selection
  bool _loading = false;
  Map<int, String> _slots = {};
  int _selectedSlot = -1;

  @override
  void dispose() {
    _ipCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchSlots() async {
    widget.onActivity?.call(); // Refresh session
    final ip = _ipCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;

    if (ip.isEmpty || user.isEmpty || pass.isEmpty) {
      widget.onLog('Router IP, username, and password are required.',
          isError: true);
      return;
    }

    setState(() => _loading = true);
    widget.onLog('Connecting to router at $ip via SSH...');

    try {
      final socket =
          await SSHSocket.connect(ip, 22, timeout: const Duration(seconds: 5));
      final client = SSHClient(
        socket,
        username: user,
        onPasswordRequest: () => pass,
      );

      final Map<int, String> retrievedSlots = {};

      for (int i = 1; i <= 5; i++) {
        final result = await client.run('nvram get wgc${i}_desc');
        final desc = utf8.decode(result).trim();
        retrievedSlots[i] = desc;
      }

      client.close();

      if (retrievedSlots.isEmpty) {
        throw Exception(
            'No WireGuard config found. Router firmware may not support this nvram schema.');
      }

      widget.onLog('Successfully retreived router config.', isSuccess: true);
      setState(() {
        _slots = retrievedSlots;
        _step = 1;
      });
    } catch (e) {
      widget.onLog('Router SSH connection error: $e', isError: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  Map<String, String> _parseWgConfig(String conf) {
    final map = <String, String>{};
    for (final line in conf.split('\n')) {
      final parts = line.split('=');
      if (parts.length >= 2) {
        map[parts[0].trim()] = parts.sublist(1).join('=').trim();
      }
    }
    return map;
  }

  Future<void> _pushToRouter() async {
    if (_selectedSlot == -1) return;

    setState(() => _loading = true);
    final slot = _selectedSlot;
    widget.onLog('Preparing to push config to slot wgc$slot...');

    try {
      final wgMap = _parseWgConfig(widget.config);
      final epParts = wgMap['Endpoint']?.split(':') ?? [];
      final epIp = epParts.isNotEmpty ? epParts[0] : '';
      final epPort = epParts.length > 1 ? epParts[1] : '1337';

      // Fallback to region ID if the description is blank
      final existingDesc = _slots[slot] ?? '';
      final newDesc = existingDesc.isEmpty ? widget.regionId : existingDesc;

      final socket = await SSHSocket.connect(_ipCtrl.text.trim(), 22,
          timeout: const Duration(seconds: 5));
      final client = SSHClient(
        socket,
        username: _userCtrl.text.trim(),
        onPasswordRequest: () => _passCtrl.text,
      );

      // Create base list of NVRAM update commands
      final List<String> cmds = [];

      // Loop 1 to 5: Set all slots to disabled (0) EXCEPT the explicitly selected target slot (1)
      for (int i = 1; i <= 5; i++) {
        cmds.add('nvram set wgc${i}_enable="${i == slot ? "1" : "0"}"');
      }

      // Add configuration payload commands for target slot to retain unmodified secondary variables
      cmds.addAll([
        'nvram set wgc${slot}_desc="$newDesc"',
        'nvram set wgc${slot}_priv="${wgMap['PrivateKey'] ?? ''}"',
        'nvram set wgc${slot}_addr="${wgMap['Address']?.replaceAll('/32', '') ?? ''}"',
        'nvram set wgc${slot}_dns="${wgMap['DNS'] ?? ''}"',
        'nvram set wgc${slot}_mtu="${wgMap['MTU'] ?? '1420'}"',
        'nvram set wgc${slot}_ppub="${wgMap['PublicKey'] ?? ''}"',
        'nvram set wgc${slot}_ep_addr="$epIp"',
        'nvram set wgc${slot}_ep_addr_r="$epIp"',
        'nvram set wgc${slot}_ep_port="$epPort"',
        'nvram set wgc${slot}_aips="${wgMap['AllowedIPs'] ?? '0.0.0.0/0'}"',
        'nvram commit',
        'service restart_wgc'
      ]);

      for (var cmd in cmds) {
        await client.run(cmd);
      }

      // --- VPN Director Rules Management ---
      widget.onLog('Updating VPN Director policy routing rules...');

      // Read the single-line rulelist file content
      final readResult =
          await client.run('cat /jffs/openvpn/vpndirector_rulelist');
      final rulelistString = utf8.decode(readResult).trim();

      if (rulelistString.isNotEmpty) {
        final String activeIface = 'WGC$slot'; // e.g. "WGC1"

        // This regex matches a single rule structure: <status>description>local>remote>interface
        // It relies on the next rule starting with '<' or reaching the end of the line.
        final ruleRegex = RegExp(r'<(\d)>([^<]+)');
        final matches = ruleRegex.allMatches(rulelistString);

        final List<String> updatedRules = [];

        for (var match in matches) {
          final existingStatus = match.group(1); // e.g., "0" or "1"
          final ruleBody = match.group(2) ??
              ''; // e.g., "WGC1 Local Subnet to VPN>192.168.0.0/24>>WGC1"

          // Check if this specific rule block targets any of our WireGuard interfaces
          if (ruleBody.endsWith('>WGC1') ||
              ruleBody.endsWith('>WGC2') ||
              ruleBody.endsWith('>WGC3') ||
              ruleBody.endsWith('>WGC4') ||
              ruleBody.endsWith('>WGC5')) {
            if (ruleBody.endsWith('>$activeIface')) {
              // Enable rule if matching the interface being saved
              updatedRules.add('<1>$ruleBody');
            } else {
              // Disable rule if referencing any other WireGuard slot interface
              updatedRules.add('<0>$ruleBody');
            }
          } else {
            // Keep rules matching OpenVPN or WAN interfaces exactly as they were
            updatedRules.add('<$existingStatus>$ruleBody');
          }
        }

        if (updatedRules.isNotEmpty) {
          // Join without newlines to build the exact single-line payload format
          final finalRulesSingleLine =
              updatedRules.join('').replaceAll('"', '\\"');

          await client.run(
              'echo -n "$finalRulesSingleLine" > /jffs/openvpn/vpndirector_rulelist');

          // Restart VPN Director service interface mapping daemon
          await client.run('service restart_vpndirector');
        }
      }

      client.close();
      widget.onLog(
          'Successfully wrote configuration to router. WireGuard interfaces and VPN Director rules re-applied.',
          isSuccess: true);

      // --- Fetch and Display Router Status via Local NVRAM ---
      try {
        // Re-open a brief connection to pull the applied NVRAM state safely
        final statusSocket = await SSHSocket.connect(_ipCtrl.text.trim(), 22,
            timeout: const Duration(seconds: 5));
        final statusClient = SSHClient(
          statusSocket,
          username: _userCtrl.text.trim(),
          onPasswordRequest: () => _passCtrl.text,
        );

        // 1. Fetch the local tunnel IP address
        final localIpResult =
            await statusClient.run('nvram get wgc${slot}_addr');
        final localIp = utf8.decode(localIpResult).trim();

        // 2. Fetch the public IP address tracked by the interface
        final publicIpResult =
            await statusClient.run('nvram get wgc${slot}_rip');
        var publicIp = utf8.decode(publicIpResult).trim();

        if (publicIp.isEmpty) {
          publicIp = 'Activating...';
        }

        statusClient.close();

        // 3. Print the final combined status message with description
        widget.onLog(
          'Router VPN now connected via $newDesc (local: $localIp - public: $publicIp)',
          isSuccess: true,
        );
      } catch (statusError) {
        widget.onLog(
          'Router configuration applied, but local status verification failed.',
          isError: false,
        );
      }

      if (mounted) Navigator.pop(context);
    } catch (e) {
      widget.onLog('Failed to complete router alignment operations: $e',
          isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Wrap with SingleChildScrollView so the keyboard doesn't cause overflow when typing credentials
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(
            24.0), // Standardized uniform padding for a centered dialog box
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _step == 0 ? 'ROUTER SSH LOGIN' : 'WRITE TO WIREGUARD SLOT',
              style: const TextStyle(
                  color: Color(0xFF00D4AA),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5),
            ),
            const SizedBox(height: 20),

            if (_step == 0) ...[
              TextFormField(
                controller: _ipCtrl,
                style: const TextStyle(
                    color: Color(0xFFE8EAF0), fontFamily: 'monospace'),
                decoration: const InputDecoration(
                    labelText: 'Router IP',
                    prefixIcon:
                        Icon(Icons.router, color: Color(0xFF8892A4), size: 18)),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _userCtrl,
                style: const TextStyle(
                    color: Color(0xFFE8EAF0), fontFamily: 'monospace'),
                decoration: const InputDecoration(
                    labelText: 'SSH Username',
                    prefixIcon:
                        Icon(Icons.person, color: Color(0xFF8892A4), size: 18)),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passCtrl,
                obscureText: true,
                style: const TextStyle(
                    color: Color(0xFFE8EAF0), fontFamily: 'monospace'),
                decoration: const InputDecoration(
                    labelText: 'SSH Password',
                    prefixIcon:
                        Icon(Icons.lock, color: Color(0xFF8892A4), size: 18)),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loading ? null : _fetchSlots,
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF12141A)))
                    : const Text('CONNECT'),
              ),
            ] else ...[
              Container(
                decoration: BoxDecoration(
                    color: const Color(0xFF1E2128),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF2E3240))),
                child: Column(
                  children: _slots.entries.map((entry) {
                    final slotNum = entry.key;
                    final desc =
                        entry.value.isEmpty ? '(Empty Slot)' : entry.value;

                    return InkWell(
                      onTap: () => setState(() => _selectedSlot = slotNum),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 12, horizontal: 16),
                        child: Row(
                          children: [
                            Icon(
                              _selectedSlot == slotNum
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              color: const Color(0xFF00D4AA),
                              size: 20,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('wgc$slotNum',
                                      style: const TextStyle(
                                          color: Color(0xFF00D4AA),
                                          fontFamily: 'monospace',
                                          fontWeight: FontWeight.bold)),
                                  Text(desc,
                                      style: const TextStyle(
                                          color: Color(0xFF8892A4),
                                          fontSize: 12)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed:
                    (_loading || _selectedSlot == -1) ? null : _pushToRouter,
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF12141A)))
                    : const Text('CONFIRM WRITE TO ROUTER'),
              ),
            ],
            // Removed the extra spacer or variable bottom viewport padding needed by bottom sheets
          ],
        ),
      ),
    );
  }
}
