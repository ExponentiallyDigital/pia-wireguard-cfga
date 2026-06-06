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
  final _ipCtrl = TextEditingController(text: '192.168.0.254');
  final _userCtrl = TextEditingController(text: 'admin');
  final _passCtrl = TextEditingController();

  int _step = 0; // 0 = credentials, 1 = slot selection
  bool _loading = false;
  bool _pushComplete = false;
  Map<int, String> _slots = {};
  int _selectedSlot = -1;
  bool _sshPassVisible = false;

  @override
  void dispose() {
    _ipCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchSlots() async {
    widget.onActivity?.call();
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

    SSHClient? client;
    try {
      final socket =
          await SSHSocket.connect(ip, 22, timeout: const Duration(seconds: 5));
      client = SSHClient(
        socket,
        username: user,
        onPasswordRequest: () => pass,
      );
      await client.authenticated;

      final Map<int, String> retrievedSlots = {};

      for (int i = 1; i <= 5; i++) {
        final result = await client.run('nvram get wgc${i}_desc');
        final desc = utf8.decode(result).trim();
        retrievedSlots[i] = desc;
      }

      if (retrievedSlots.values.every((d) => d.isEmpty)) {
        widget.onLog(
          'Warning: all WireGuard slots appear unconfigured. '
          'If unexpected, verify the router supports WireGuard client mode.',
        );
      }

      widget.onLog('Successfully retrieved router config.', isSuccess: true);
      setState(() {
        _slots = retrievedSlots;
        _step = 1;
      });
    } catch (e) {
      widget.onLog('Router SSH connection error: $e', isError: true);
    } finally {
      client?.close();
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

    SSHClient? client;
    bool killSwitchDisabled = false;

    try {
      final wgMap = _parseWgConfig(widget.config);
      final epParts = wgMap['Endpoint']?.split(':') ?? [];
      final epIp = epParts.isNotEmpty ? epParts[0] : '';
      final epPort = epParts.length > 1 ? epParts[1] : '1337';

      final existingDesc = _slots[slot] ?? '';
      final newDesc = existingDesc.isEmpty ? widget.regionId : existingDesc;

      final socket = await SSHSocket.connect(_ipCtrl.text.trim(), 22,
          timeout: const Duration(seconds: 5));
      client = SSHClient(
        socket,
        username: _userCtrl.text.trim(),
        onPasswordRequest: () => _passCtrl.text,
      );
      await client.authenticated;

      // --- Step 1: Disable kill switch (NVRAM only) ---
      // Do NOT call service restart_firewall here. On Merlin, restart_firewall
      // internally triggers restart_wgc, which would tear down any running tunnel
      // and process all enable flags — stopping WGC slots set to enable=0.
      // Writing enforce=0 to NVRAM is sufficient; Merlin reads it when the
      // tunnel starts in Step 4 below.
      widget.onLog('Disabling kill switch (wgc${slot}_enforce)...');
      await client.run('nvram set wgc${slot}_enforce=0');
      await client.run('nvram commit');
      killSwitchDisabled = true;
      widget.onLog('Kill switch disabled.');

      // --- Step 2: Write NVRAM variables ---
      for (int i = 1; i <= 5; i++) {
        await client.run('nvram set wgc${i}_enable="${i == slot ? "1" : "0"}"');
      }
      await client.run('nvram set wgc${slot}_desc="$newDesc"');
      await client
          .run('nvram set wgc${slot}_priv="${wgMap['PrivateKey'] ?? ''}"');
      await client.run('nvram set wgc${slot}_addr="${wgMap['Address'] ?? ''}"');
      await client.run('nvram set wgc${slot}_dns="${wgMap['DNS'] ?? ''}"');
      await client.run('nvram set wgc${slot}_mtu="${wgMap['MTU'] ?? '1420'}"');
      await client
          .run('nvram set wgc${slot}_ppub="${wgMap['PublicKey'] ?? ''}"');
      await client.run('nvram set wgc${slot}_ep_addr="$epIp"');
      await client.run('nvram set wgc${slot}_ep_port="$epPort"');
      await client.run(
          'nvram set wgc${slot}_aips="${wgMap['AllowedIPs'] ?? '0.0.0.0/0'}"');
      await client.run('nvram commit');
      widget.onLog('NVRAM written and committed.');

      // --- Step 3: Update VPN Director rulelist BEFORE starting the tunnel ---
      // Merlin reads the rulelist file at tunnel start time. Writing it here
      // ensures the correct interface (WGC$slot) is active when restart_vpnc$slot
      // fires below. Do NOT call service restart_vpndirector — that triggers
      // restart_wgc internally, which would interfere with our controlled restart.
      // Merlin applies the updated rulelist automatically when the tunnel starts.
      widget.onLog('Updating VPN Director rulelist...');
      final readResult =
          await client.run('cat /jffs/openvpn/vpndirector_rulelist');
      final rulelistString = utf8.decode(readResult).trim();

      if (rulelistString.isNotEmpty) {
        final String activeIface = 'WGC$slot';
        final ruleRegex = RegExp(r'<(\d)>([^<]+)');
        final matches = ruleRegex.allMatches(rulelistString);
        final List<String> updatedRules = [];

        for (var match in matches) {
          final existingStatus = match.group(1);
          final ruleBody = match.group(2) ?? '';
          if (ruleBody.endsWith('>WGC1') ||
              ruleBody.endsWith('>WGC2') ||
              ruleBody.endsWith('>WGC3') ||
              ruleBody.endsWith('>WGC4') ||
              ruleBody.endsWith('>WGC5')) {
            updatedRules.add(ruleBody.endsWith('>$activeIface')
                ? '<1>$ruleBody'
                : '<0>$ruleBody');
          } else {
            updatedRules.add('<$existingStatus>$ruleBody');
          }
        }

        if (updatedRules.isNotEmpty) {
          final finalRulesSingleLine =
              updatedRules.join('').replaceAll('"', '\\"');
          await client.run(
              'echo -n "$finalRulesSingleLine" > /jffs/openvpn/vpndirector_rulelist');
          widget.onLog('VPN Director rulelist updated.');
        }
      } else {
        widget.onLog('VPN Director rulelist empty or not found — skipping.');
      }

      // --- Step 4: Start the tunnel ---
      // Merlin reads enforce, enable flags, and the VPN Director rulelist at
      // this point and applies everything in one pass.
      widget.onLog('Starting VPN tunnel (restart_vpnc$slot)...');
      await client.run('service restart_vpnc$slot');
      await Future.delayed(const Duration(seconds: 3));

      // --- Step 5: Poll for handshake confirmation via wgcN_rip ---
      // Clear any stale value from a previous session first to prevent
      // a leftover IP from giving a false positive on check 1.
      await client.run('nvram set wgc${slot}_rip=""');
      widget.onLog('Waiting for WireGuard handshake (up to 30s)...');
      String publicIp = '';
      for (int retry = 0; retry < 15; retry++) {
        widget.onActivity?.call();
        await Future.delayed(const Duration(seconds: 2));
        final result = await client.run('nvram get wgc${slot}_rip');
        publicIp = utf8.decode(result).trim();
        widget.onLog(
            '  Check ${retry + 1}/15: ${publicIp.isEmpty ? "(waiting)" : publicIp}');
        if (publicIp.isNotEmpty && publicIp != '0.0.0.0') break;
      }

      if (publicIp.isEmpty || publicIp == '0.0.0.0') {
        throw Exception(
          'Handshake not confirmed after 30 seconds. '
          'Kill switch has NOT been re-enabled. '
          'Check tunnel status via SSH: wg show wgc$slot\n'
          'Then re-enable manually: nvram set wgc${slot}_enforce=1 && nvram commit',
        );
      }

      widget.onLog('Handshake confirmed. Public IP: $publicIp');

      // --- Step 6: Re-enable kill switch (NVRAM only) ---
      // Same reasoning as Step 1 — no restart_firewall. The enforce value is
      // now persisted and will be enforced by Merlin on any future tunnel restart.
      widget.onLog('Re-enabling kill switch...');
      await client.run('nvram set wgc${slot}_enforce=1');
      await client.run('nvram commit');
      killSwitchDisabled = false;

      final localIpResult = await client.run('nvram get wgc${slot}_addr');
      final localIp = utf8.decode(localIpResult).trim();

      widget.onLog(
        'VPN connected via $newDesc  |  local: $localIp  |  public: $publicIp',
        isSuccess: true,
      );
      widget.onLog('Kill switch re-enabled. Push complete.', isSuccess: true);
      if (mounted) setState(() => _pushComplete = true);
    } catch (e) {
      if (killSwitchDisabled) {
        widget.onLog('Error occurred. Attempting to restore kill switch...');
        try {
          await client?.run('nvram set wgc${slot}_enforce=1 && nvram commit');
          widget.onLog('Kill switch restored.');
        } catch (_) {
          widget.onLog(
            'CRITICAL: Could not restore kill switch. '
            'Run via SSH: nvram set wgc${slot}_enforce=1 && nvram commit',
            isError: true,
          );
        }
      }
      widget.onLog('Push failed: ${e.toString().replaceAll('Exception: ', '')}',
          isError: true);
    } finally {
      client?.close();
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
                obscureText: !_sshPassVisible,
                style: const TextStyle(
                    color: Color(0xFFE8EAF0), fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: 'SSH Password',
                  prefixIcon: const Icon(Icons.lock,
                      color: Color(0xFF8892A4), size: 18),
                  suffixIcon: GestureDetector(
                    onTap: () =>
                        setState(() => _sshPassVisible = !_sshPassVisible),
                    child: Icon(
                      _sshPassVisible ? Icons.visibility_off : Icons.visibility,
                      color: const Color(0xFF8892A4),
                      size: 18,
                    ),
                  ),
                ),
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
                onPressed: (_loading || _selectedSlot == -1 || _pushComplete)
                    ? null
                    : _pushToRouter,
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF12141A)))
                    : const Text('CONFIRM WRITE TO ROUTER'),
              ),
              if (_pushComplete) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.check_circle_outline, size: 16),
                  label: const Text('DONE — CLOSE'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.green,
                    side: const BorderSide(color: Colors.green),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ],
            ],
            // Removed the extra spacer or variable bottom viewport padding needed by bottom sheets
          ],
        ),
      ),
    );
  }
}
