// lib/router_push.dart
// SSH-based WireGuard config push for ASUS Merlin routers.
// Uses verified Merlin service command sequences for stop and start.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dartssh2/dartssh2.dart';

class RouterPushSheet extends StatefulWidget {
  final String config;
  final String regionId;
  final void Function(String, {bool isError, bool isSuccess}) onLog;
  final VoidCallback? onActivity;
  // Hook to inject mock SSH clients for testing
  final Future<SSHClient> Function(String ip, String user, String pass)? testClientFactory;

  const RouterPushSheet({
    super.key,
    required this.config,
    required this.regionId,
    required this.onLog,
    this.onActivity,
    this.testClientFactory,
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
  Map<int, String> _slots = {};
  Map<int, bool> _killSwitch = {};
  int? _activeSlot;
  int _selectedSlot = -1;
  bool _sshPassVisible = false;

  @override
  void dispose() {
    _ipCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  // Run an SSH command and return trimmed stdout as a String.
  Future<String> _run(SSHClient client, String cmd) async => utf8.decode(await client.run(cmd)).trim();

  // Helper method to obtain a client connection
  Future<SSHClient> _getClient(String ip, String user, String pass) async {
    if (widget.testClientFactory != null) {
      return widget.testClientFactory!(ip, user, pass);
    }
    final socket = await SSHSocket.connect(ip, 22, timeout: const Duration(seconds: 5));
    final client = SSHClient(socket, username: user, onPasswordRequest: () => pass);
    await client.authenticated;
    return client;
  }

  // ─── Fetch Slots ────────────────────────────────────────────────────────────
  Future<void> _fetchSlots() async {
    widget.onActivity?.call();
    final ip = _ipCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;

    if (ip.isEmpty || user.isEmpty || pass.isEmpty) {
      widget.onLog('Router IP, username, and password are required.', isError: true);
      return;
    }

    setState(() => _loading = true);
    widget.onLog('Connecting to router at $ip via SSH...');

    SSHClient? client;
    try {
      client = await _getClient(ip, user, pass);

      final Map<int, String> retrievedSlots = {};
      final Map<int, bool> retrievedKillSwitch = {};
      for (int i = 1; i <= 5; i++) {
        retrievedSlots[i] = await _run(client, 'nvram get wgc${i}_desc');
        retrievedKillSwitch[i] = (await _run(client, 'nvram get wgc${i}_enforce')) == '1';
      }
      final ifaceOutput = await _run(client, 'wg show interfaces');
      final activeMatch = RegExp(r'wgc(\d)').firstMatch(ifaceOutput);
      final detectedActiveSlot = activeMatch != null ? int.tryParse(activeMatch.group(1)!) : null;

      if (retrievedSlots.values.every((d) => d.isEmpty)) {
        widget.onLog(
          'All WireGuard slots are unconfigured.',
        );
      }

      widget.onLog('Successfully retrieved router config.', isSuccess: true);
      setState(() {
        _slots = retrievedSlots;
        _killSwitch = retrievedKillSwitch;
        _activeSlot = detectedActiveSlot;
        _step = 1;
      });
    } catch (e) {
      widget.onLog('Router SSH connection error: $e', isError: true);
    } finally {
      client?.close();
      setState(() => _loading = false);
    }
  }

  // ─── Config Parsing ─────────────────────────────────────────────────────────
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

  // ─── Push to Router ────────────────────────────────────────────────────────
  // router CLI's ";" mimics "&&": using ";" in router service commands"
  Future<void> _pushToRouter() async {
    if (_selectedSlot == -1) return;

    setState(() => _loading = true);
    final slot = _selectedSlot;
    widget.onLog('Preparing to push config to slot wgc$slot...');

    SSHClient? client;
    int? activeSlot;
    Map<String, String>? slotBackup;

    try {
      final wgMap = _parseWgConfig(widget.config);
      final epParts = wgMap['Endpoint']?.split(':') ?? [];
      final epIp = epParts.isNotEmpty ? epParts[0] : '';
      final epPort = epParts.length > 1 ? epParts[1] : '1337';
      final newDesc = widget.regionId;

      client = await _getClient(_ipCtrl.text.trim(), _userCtrl.text.trim(), _passCtrl.text);

      // ── Step 1: Detect currently active WireGuard interface ────────────────
      widget.onLog('Checking active WireGuard interface...');
      final ifaceOutput = await _run(client, 'wg show interfaces');
      final activeMatch = RegExp(r'wgc(\d)').firstMatch(ifaceOutput);
      activeSlot = activeMatch != null ? int.tryParse(activeMatch.group(1)!) : null;
      widget.onLog(activeSlot != null ? 'Active interface: wgc$activeSlot' : 'No active WireGuard interface found.');

      // ── Step 2: Backup currently active tunnel ─────────────────────────────
      if (_slots[slot]?.isNotEmpty == true) {
        widget.onLog('Backing up existing wgc$slot config...');
        slotBackup = {};
        for (final key in [
          'addr',
          'alive',
          'desc',
          'dns',
          'enable',
          'enforce',
          'ep_addr',
          'ep_addr_r', // added
          'ep_port',
          'fw',
          'mtu',
          'nat',
          'ppub',
          'priv',
          'psk,' // added
              'rip', // added
          'aips'
        ]) {
          slotBackup['wgc${slot}_$key'] = await _run(client, 'nvram get wgc${slot}_$key');
        }
        widget.onLog('Backup complete.');
      }

      // ── Step 3: Stop the currently active tunnel ───────────────────────────
      if (activeSlot != null) {
        widget.onLog('Stopping wgc$activeSlot...');
        await _run(client, 'nvram set wgc${activeSlot}_enforce=0');
        await _run(client, 'nvram set wgc${activeSlot}_enable=0');
        await _run(client, 'nvram commit');
        // Explicit stop command targeted at the specific slot
        await _run(client, 'service "stop_wgc $activeSlot"; service start_vpnrouting0');
        widget.onLog('wgc$activeSlot stopped. Waiting for routing to settle...');
        await Future.delayed(const Duration(seconds: 5));
      }

      // ── Step 4: Write new config to NVRAM ──────────────────────────────────
      // *all* wgc_ nvram variables are set, values which are set at tunnel start (_ap_addr_r and _rip) are set here
      // to null for safety, _ep_addr anb _ep_addr are the addresses of the server from which our wireguard tunnel starts
      widget.onLog('Writing NVRAM for wgc$slot...');
      await _run(client, 'nvram set wgc${slot}_addr="${wgMap['Address'] ?? ''}"');
      await _run(client, 'nvram set wgc${slot}_alive=25');
      await _run(client, 'nvram set wgc${slot}_desc="$newDesc"');
      await _run(client, 'nvram set wgc${slot}_dns="${wgMap['DNS'] ?? ''}"');
      await _run(client, 'nvram set wgc${slot}_enable=1');
      await _run(client, 'nvram set wgc${slot}_enforce=1');
      await _run(client, 'nvram set wgc${slot}_ep_addr="$epIp"');
      // per wireguard.c, wgc1_ep_addr_r is dynamically set from a lookup on wgcX_ep_addr and committed to NVRAM
      // therefore below it is set to null
      await _run(client, 'nvram set wgc${slot}_ep_addr_r=""');
      await _run(client, 'nvram set wgc${slot}_ep_port="$epPort"');
      await _run(client, 'nvram set wgc${slot}_fw=1');
      await _run(client, 'nvram set wgc${slot}_mtu="${wgMap['MTU'] ?? '1420'}"');
      await _run(client, 'nvram set wgc${slot}_nat=1');
      await _run(client, 'nvram set wgc${slot}_ppub="${wgMap['PublicKey'] ?? ''}"');
      await _run(client, 'nvram set wgc${slot}_priv="${wgMap['PrivateKey'] ?? ''}"');
      // PIA doesn't use, set to null
      await _run(client, 'nvram set wgc${slot}_psk=""');
      // per wireguard.c, wgc1_rip is dynamically set once the tunnel is established and traffic starts to flow
      // this is the WAN IP that websites see as the the traffic origin
      // therefore below it is set to null
      await _run(client, 'nvram set wgc${slot}_rip=""');
      await _run(client, 'nvram set wgc${slot}_aips="${wgMap['AllowedIPs'] ?? '0.0.0.0/0'}"');

      // Flash commit, single stage (previously set enforce and enable as a second commit)
      await _run(client, 'nvram commit');
      widget.onLog('NVRAM committed.');

      // ── Step 5: Start the new tunnel ───────────────────────────────────────
      widget.onLog('Starting wgc$slot...');
      // only start $slot (was restart_wgc), this matches Merlin Advanced_WireguardClient_Content.asp
      await _run(client, 'service "start_wgc $slot"; service restart_vpnrouting0');
      widget.onLog('Start sequence sent. Waiting for tunnel to come up...');
      await Future.delayed(const Duration(seconds: 10));

      // Verify wgcP is active ─────────────────────────────────────
      widget.onLog('Verifying tunnel for up to 60s...');
      bool verified = false;

      for (int retry = 0; retry < 30; retry++) {
        widget.onActivity?.call();
        await Future.delayed(const Duration(seconds: 2));

        final verifyOutput = await _run(client, 'wg show interfaces');
        if (verifyOutput.contains('wgc$slot')) {
          verified = true;
          widget.onLog('  Check ${retry + 1}/30: wgc$slot is active');
          break;
        }
        widget.onLog('  Check ${retry + 1}/30: wgc$slot not yet active');
      }

      if (!verified) {
        throw Exception(
          'wgc$slot did not appear in "wg show interfaces" after 60 seconds. '
          'Check tunnel status via SSH: wg show interfaces',
        );
      }

      // ── Success ────────────────────────────────────────────────────────────
      // Report IP to log
      widget.onLog('Checking public IP via tunnel...');
      String publicIp = '';
      // use icanhazip.com for IP lookup - hosted & now run by Cloudflare
      for (int i = 0; i < 5; i++) {
        publicIp = (await _run(
          client,
          'curl -s --max-time 5 https://ipv4.icanhazip.com/ 2>/dev/null',
        ))
            .trim();
        if (publicIp.isNotEmpty) break;
        widget.onLog('  IP check ${i + 1}/5: waiting...');
        await Future.delayed(const Duration(seconds: 3));
      }
      widget.onLog(
        'Connected via $newDesc, public IP $publicIp (pool assigned, will vary)',
        isSuccess: true,
      );
      widget.onLog('Push complete.', isSuccess: true);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      // ── Error Recovery ─────────────────────────────────────────────────────
      //
      // Fires when the target slot (wgc$slot) already held a config at push time.
      // The pre-push values were snapshotted into slotBackup before being overwritten.
      // Restores those NVRAM entries so the slot returns to its prior state.
      // Also re-enables and restarts the active tunnel if one was stopped (activeSlot != null).
      if (slotBackup != null) {
        widget.onLog('Push failed, restoring wgc$slot config...');
        try {
          for (final entry in slotBackup.entries) {
            await client?.run('nvram set ${entry.key}="${entry.value}"');
          }
          // for safety, set kill switch and slot to enabled (just in case!!)
          if (activeSlot != null) {
            await client?.run('nvram set wgc${activeSlot}_enforce=1');
            await client?.run('nvram set wgc${activeSlot}_enable=1');
          }
          await client?.run('nvram commit');
          widget.onLog('wgc$slot config restored.', isSuccess: true);
          widget.onLog('Restarting entire WireGuard service & routing ...');
          // full wireguard service restart, for safety!
          await client?.run('service restart_wgc; service start_vpnrouting0');
        } catch (_) {
          widget.onLog(
            'CRITICAL: Could not restore wgc$slot. Check router manually.',
            isError: true,
          );
        }
      }

      // Fires when a tunnel (wgc$activeSlot) was active at push start and was stopped
      // in Step 3, but the push then failed — leaving the router with no active VPN.
      // Runs independently of slotBackup: covers the case where the target slot was
      // empty (no backup taken) but a tunnel was still stopped and needs to be recovered.
      if (activeSlot != null && slotBackup == null) {
        try {
          await client?.run('nvram set wgc${activeSlot}_enforce=1');
          await client?.run('nvram set wgc${activeSlot}_enable=1');
          await client?.run('nvram commit');
          widget.onLog('Restarting wgc$activeSlot...');
          // full wireguard service restart, for safety!
          await client?.run('service "restart_wgc $activeSlot"; service start_vpnrouting0');
        } catch (_) {
          widget.onLog('CRITICAL: Could not restart wgc$activeSlot. Check router manually.', isError: true);
        }
      }

      widget.onLog(
        'Push failed: ${e.toString().replaceAll('Exception: ', '')}',
        isError: true,
      );

      if (mounted) Navigator.pop(context);
    } finally {
      client?.close();
      if (mounted) setState(() => _loading = false);
    }
  }

  // ─── Badge Helper ─────────────────────────────────────────────────────────────
  Widget _badge(String label, {required Color text, required Color border, required Color bg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border, width: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: text,
          fontSize: 10,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  // ─── Build ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _step == 0 ? 'ROUTER SSH LOGIN' : 'WRITE TO WIREGUARD SLOT',
              style: const TextStyle(color: Color(0xFF00D4AA), fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.5),
            ),
            const SizedBox(height: 20),
            if (_step == 0) ...[
              TextFormField(
                controller: _ipCtrl,
                style: const TextStyle(color: Color(0xFFE8EAF0), fontFamily: 'monospace'),
                decoration: const InputDecoration(
                    labelText: 'Router IP', prefixIcon: Icon(Icons.router, color: Color(0xFF8892A4), size: 18)),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _userCtrl,
                style: const TextStyle(color: Color(0xFFE8EAF0), fontFamily: 'monospace'),
                decoration: const InputDecoration(
                    labelText: 'SSH Username', prefixIcon: Icon(Icons.person, color: Color(0xFF8892A4), size: 18)),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passCtrl,
                obscureText: !_sshPassVisible,
                style: const TextStyle(color: Color(0xFFE8EAF0), fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: 'SSH Password',
                  prefixIcon: const Icon(Icons.lock, color: Color(0xFF8892A4), size: 18),
                  suffixIcon: GestureDetector(
                    onTap: () => setState(() => _sshPassVisible = !_sshPassVisible),
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
                        height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF12141A)))
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
                    final desc = entry.value.isEmpty ? '(Empty Slot)' : entry.value;
                    final isActive = _activeSlot == slotNum;
                    final hasKillSwitch = _killSwitch[slotNum] == true;
                    return InkWell(
                      onTap: () => setState(() => _selectedSlot = slotNum),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                        child: Row(
                          children: [
                            Icon(
                              _selectedSlot == slotNum ? Icons.radio_button_checked : Icons.radio_button_unchecked,
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
                                          color: Color(0xFF00D4AA), fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                                  Text(desc, style: const TextStyle(color: Color(0xFF8892A4), fontSize: 12)),
                                  if (isActive || hasKillSwitch) ...[
                                    const SizedBox(height: 5),
                                    Row(
                                      children: [
                                        if (isActive)
                                          _badge('● ACTIVE',
                                              text: const Color(0xFF00D4AA),
                                              border: const Color(0xFF00D4AA),
                                              bg: const Color(0xFF0F3D2E)),
                                        if (isActive && hasKillSwitch) const SizedBox(width: 6),
                                        if (hasKillSwitch)
                                          _badge('⚑ KILL SWITCH',
                                              text: const Color(0xFFEF9F27),
                                              border: const Color(0xFFEF9F27),
                                              bg: const Color(0xFF2A1F0E)),
                                      ],
                                    ),
                                  ],
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
                onPressed: (_loading || _selectedSlot == -1) ? null : _pushToRouter,
                child: _loading
                    ? const SizedBox(
                        height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF12141A)))
                    : const Text('CONFIRM WRITE TO ROUTER'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
