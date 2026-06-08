// router_push_sheet.dart
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

  // Run an SSH command and return trimmed stdout as a String.
  Future<String> _run(SSHClient client, String cmd) async =>
      utf8.decode(await client.run(cmd)).trim();

  // ─── Fetch Slots ────────────────────────────────────────────────────────────

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
        retrievedSlots[i] = await _run(client, 'nvram get wgc${i}_desc');
      }

      if (retrievedSlots.values.every((d) => d.isEmpty)) {
        widget.onLog(
          'Warning: all WireGuard slots appear unconfigured. '
          'Verify the router firmware supports WireGuard client mode.',
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
  Future<void> _pushToRouter() async {
    if (_selectedSlot == -1) return;

    setState(() => _loading = true);
    final slot = _selectedSlot;
    widget.onLog('Preparing to push config to slot wgc$slot...');

    SSHClient? client;
    int? activeSlot;

    try {
      final wgMap = _parseWgConfig(widget.config);
      final epParts = wgMap['Endpoint']?.split(':') ?? [];
      final epIp = epParts.isNotEmpty ? epParts[0] : '';
      final epPort = epParts.length > 1 ? epParts[1] : '1337';
      final newDesc =
          widget.regionId; // <-- Always use the newly selected region
      final socket = await SSHSocket.connect(
        _ipCtrl.text.trim(),
        22,
        timeout: const Duration(seconds: 5),
      );
      client = SSHClient(
        socket,
        username: _userCtrl.text.trim(),
        onPasswordRequest: () => _passCtrl.text,
      );
      await client.authenticated;

      // ── Step 1: Detect currently active WireGuard interface ────────────────
      //
      // "wg show interfaces" returns the active tunnel name, e.g. "wgc1".
      // An empty result means no tunnel is currently running.
      //
      widget.onLog('Checking active WireGuard interface...');
      final ifaceOutput = await _run(client, 'wg show interfaces');
      final activeMatch = RegExp(r'wgc(\d)').firstMatch(ifaceOutput);
      activeSlot =
          activeMatch != null ? int.tryParse(activeMatch.group(1)!) : null;
      widget.onLog(activeSlot != null
          ? 'Active interface: wgc$activeSlot'
          : 'No active WireGuard interface found.');

      // ── Steps 2–6: Stop the currently active tunnel ────────────────────────
      //
      // Merlin stop sequence:
      //   nvram set wgcN_enforce=0
      //   nvram set wgcN_enable=0
      //   nvram commit
      //   service "stop_wgc N" && service restart_firewall && service restart_vpnrouting0
      //
      // Skipped when no tunnel is running (activeSlot == null).
      //
      if (activeSlot != null) {
        widget.onLog('Stopping wgc$activeSlot...');
        await _run(client, 'nvram set wgc${activeSlot}_enforce=0');
        await _run(client, 'nvram set wgc${activeSlot}_enable=0');
        await _run(client, 'nvram commit');
        await _run(
          client,
//          'service "stop_wgc $activeSlot" && service restart_wgc && service start_vpnrouting0',
          'service restart_wgc && service start_vpnrouting0',
        );
        widget
            .onLog('wgc$activeSlot stopped. Waiting for routing to settle...');
        await Future.delayed(const Duration(seconds: 5));
      }

      // ── Write new config to NVRAM ──────────────────────────────────────────
      //
      // Write tunnel parameters for the target slot before starting it.
      // wgcP_enable and wgcP_enforce are set in the start sequence below.
      //
      widget.onLog('Writing NVRAM for wgc$slot...');
      await _run(client, 'nvram set wgc${slot}_desc="$newDesc"');
      await _run(
          client, 'nvram set wgc${slot}_priv="${wgMap['PrivateKey'] ?? ''}"');
      await _run(
          client, 'nvram set wgc${slot}_addr="${wgMap['Address'] ?? ''}"');
      await _run(client, 'nvram set wgc${slot}_dns="${wgMap['DNS'] ?? ''}"');
      await _run(
          client, 'nvram set wgc${slot}_mtu="${wgMap['MTU'] ?? '1420'}"');
      await _run(
          client, 'nvram set wgc${slot}_ppub="${wgMap['PublicKey'] ?? ''}"');
      await _run(client, 'nvram set wgc${slot}_ep_addr="$epIp"');
      await _run(client, 'nvram set wgc${slot}_ep_port="$epPort"');
      await _run(client,
          'nvram set wgc${slot}_aips="${wgMap['AllowedIPs'] ?? '0.0.0.0/0'}"');
      // additional parameters set via GUI
      await _run(client, 'nvram set wgc${slot}_fw=1');
      await _run(client, 'nvram set wgc${slot}_nat=1');
      await _run(client, 'nvram set wgc${slot}_alive=25');
      // end - additional parameters set via GUI
      await _run(client, 'nvram commit');
      widget.onLog('NVRAM written and committed.');

      // ── Steps 7–10: Start the new tunnel ───────────────────────────────────
      //
      // Merlin start sequence:
      //   nvram set wgcP_enforce=1
      //   nvram set wgcP_enable=1
      //   nvram commit
      //   service "start_wgc P" && service restart_firewall && service restart_vpnrouting0
      //
      // ???? do we actually need to restart all of these or just
      //        "service restart_wgc; service start_vpnrouting0"
      //
      widget.onLog('Starting wgc$slot...');
      await _run(client, 'nvram set wgc${slot}_enforce=1');
      await _run(client, 'nvram set wgc${slot}_enable=1');
      await _run(client, 'nvram commit');
      await _run(
        client,
//        'service "start_wgc $activeSlot" && restart_wgc && service start_vpnrouting0',
        'service restart_wgc && service start_vpnrouting0',
      );
      widget.onLog('Start sequence sent. Waiting for tunnel to come up...');
      await Future.delayed(const Duration(seconds: 10));

      // ── Step 11: Verify wgcP is active ─────────────────────────────────────
      //
      // "wg show interfaces" must return "wgcP". Poll for up to 90 seconds.
      //
      widget.onLog('Verifying tunnel (up to 90s)...');
      bool verified = false;

      for (int retry = 0; retry < 45; retry++) {
        widget.onActivity?.call();
        await Future.delayed(const Duration(seconds: 2));

        final verifyOutput = await _run(client, 'wg show interfaces');
        if (verifyOutput.contains('wgc$slot')) {
          verified = true;
          widget.onLog('  Check ${retry + 1}/45: wgc$slot is active');
          break;
        }
        widget.onLog('  Check ${retry + 1}/45: wgc$slot not yet active');
      }

      if (!verified) {
        throw Exception(
          'wgc$slot did not appear in "wg show interfaces" after 90 seconds. '
          'Check tunnel status via SSH: wg show interfaces',
        );
      }

      // ── Success ─────────────────────────────────────────────────────────────
      final localIp = await _run(client, 'nvram get wgc${slot}_addr');
      final publiclIp = await _run(client, 'nvram get wgc${slot}_rip');
      widget.onLog(
        'Connected via $newDesc | local: $localIp - Public: $publiclIp',
        isSuccess: true,
      );
      widget.onLog('Push complete.', isSuccess: true);
      // Automatically close the window instead of setting a flag
      if (mounted) Navigator.pop(context);
    } catch (e) {
      // ── Error Recovery ───────────────────────────────────────────────────────
      //
      // If the slot active before the push is known, attempt to restore it using
      // the new start sequence, putting the router back in a known-good state.
      //
      if (activeSlot != null) {
        widget.onLog('Push failed — attempting to restore wgc$activeSlot...');
        try {
          await client?.run('nvram set wgc${activeSlot}_enforce=1');
          await client?.run('nvram set wgc${activeSlot}_enable=1');
          await client?.run('nvram commit');
          await client?.run(
//            'service restart_wgc && service restart_firewall && service start_vpnrouting0',
            'service restart_wgc && service start_vpnrouting0',
          );
          widget.onLog('wgc$activeSlot restored.', isSuccess: true);
        } catch (_) {
          widget.onLog(
            'CRITICAL: Could not restore wgc$activeSlot. '
            'Check router state manually via SSH.',
            isError: true,
          );
        }
      }

      widget.onLog(
        'Push failed: ${e.toString().replaceAll('Exception: ', '')}',
        isError: true,
      );

      // Close the dialog so the main screen log (already auto-scrolled) is visible.
      if (mounted) Navigator.pop(context);
    } finally {
      client?.close();
      if (mounted) setState(() => _loading = false);
    }
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
          ],
        ),
      ),
    );
  }
}
