// router_push_sheet.dart
// SSH-based WireGuard config push for ASUS Merlin routers.
// Uses verified Merlin service command sequences for stop and start.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dartssh2/dartssh2.dart';

// Full service restart chain required after any WireGuard state change on Merlin.
// Reloads WAN, firewall, and VPN routing so the new tunnel state is applied.
// Must run after both stop and start sequences.
const _kRestartChain = 'service restart_wan && service restart_firewall && '
    'service restart_vpnclient1 && service restart_vpnclient2 && '
    'service restart_vpnrouting0';

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

  // ─── Push to Router ─────────────────────────────────────────────────────────

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
      final existingDesc = _slots[slot] ?? '';
      final newDesc = existingDesc.isEmpty ? widget.regionId : existingDesc;

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

      // ── Find currently active slot ──────────────────────────────────────────
      for (int i = 1; i <= 5; i++) {
        if (await _run(client, 'nvram get wgc${i}_enable') == '1') {
          activeSlot = i;
          break;
        }
      }
      widget.onLog(activeSlot != null
          ? 'Active interface: wgc$activeSlot'
          : 'No active WireGuard interface found.');

      // ── Step 1: Stop the currently active tunnel ────────────────────────────
      //
      // Verified Merlin stop sequence:
      //   nvram set wgcN_enforce=0
      //   nvram set wgcN_enable=0
      //   nvram commit
      //   service stop_wgcN
      //   service restart_wan && restart_firewall && restart_vpnclient1 && restart_vpnclient2 && restart_vpnrouting0
      //
      if (activeSlot != null) {
        widget.onLog('Stopping wgc$activeSlot...');
        await _run(client, 'nvram set wgc${activeSlot}_enforce=0');
        await _run(client, 'nvram set wgc${activeSlot}_enable=0');
        await _run(client, 'nvram commit');
        await _run(client, 'service stop_wgc$activeSlot');
        await _run(client, _kRestartChain);
        widget
            .onLog('wgc$activeSlot stopped. Waiting for routing to settle...');
        // Give routing services time to finish after the restart chain.
        await Future.delayed(const Duration(seconds: 8));
      }

      // ── Step 2: Write new config to NVRAM ──────────────────────────────────
      //
      // wgcN_enable and wgcN_enforce for the target slot are set in Step 4
      // (the start sequence), AFTER the VPN Director rules are written.
      // Setting them here too early risks Merlin picking up the new slot
      // before the VPN Director file is ready.
      //
      widget.onLog('Writing NVRAM for wgc$slot...');
      for (int i = 1; i <= 5; i++) {
        if (i != slot) {
          await _run(client, 'nvram set wgc${i}_enable=0');
          await _run(client, 'nvram set wgc${i}_enforce=0');
        }
      }
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
      await _run(client, 'nvram commit');
      widget.onLog('NVRAM written and committed.');

      // ── Step 3: Update VPN Director rulelist ───────────────────────────────
      //
      // Must be done BEFORE starting the tunnel. Merlin reads this file at
      // tunnel start time. Do NOT call service restart_vpndirector here —
      // that triggers restart_wgc internally. The file is picked up
      // automatically when service start_wgcN runs in Step 4.
      //
      widget.onLog('Updating VPN Director rulelist...');
      final rulelistRaw =
          await _run(client, 'cat /jffs/openvpn/vpndirector_rulelist');

      if (rulelistRaw.isNotEmpty) {
        final activeIface = 'WGC$slot';
        final ruleRegex = RegExp(r'<(\d)>([^<]+)');

        // Enable only the two rules for the target slot; disable all others.
        // Non-WireGuard rules (OpenVPN, WAN) are left unchanged.
        final updatedRules = ruleRegex.allMatches(rulelistRaw).map((m) {
          final body = m.group(2) ?? '';
          final isWgRule = RegExp(r'>WGC[1-5]$').hasMatch(body);
          if (!isWgRule) return '<${m.group(1)}>$body';
          return body.endsWith('>$activeIface') ? '<1>$body' : '<0>$body';
        }).join('');

        // Escape double quotes so the shell does not misparse the echo argument.
        final escaped = updatedRules.replaceAll('"', '\\"');
        await _run(
            client, 'echo -n "$escaped" > /jffs/openvpn/vpndirector_rulelist');
        widget.onLog('VPN Director rulelist updated.');
      } else {
        widget.onLog('VPN Director rulelist not found — skipping.');
      }

      // ── Step 4: Start the new tunnel ───────────────────────────────────────
      //
      // Verified Merlin start sequence:
      //   nvram set wgcN_enable=1
      //   nvram set wgcN_enforce=1
      //   nvram commit
      //   service start_wgcN
      //   service restart_wan && restart_firewall && restart_vpnclient1 && restart_vpnclient2 && restart_vpnrouting0
      //
      // Note: the restart chain runs AFTER start_wgcN. This is correct — Merlin
      // reloads all routing rules as part of the chain, which briefly restarts
      // WireGuard. WireGuard's PersistentKeepalive retries the handshake once
      // WAN is back up. The 90-second poll window in Step 5 accommodates this.
      //
      widget.onLog('Starting wgc$slot...');
      await _run(client, 'nvram set wgc${slot}_enable=1');
      await _run(client, 'nvram set wgc${slot}_enforce=1');
      await _run(client, 'nvram commit');
      await _run(client, 'service start_wgc$slot');
      await _run(client, _kRestartChain);
      widget.onLog(
          'Start sequence sent. Waiting for WAN and tunnel to come up...');
      // Give WAN time to reconnect after restart_wan, and WireGuard time to
      // complete its initial handshake via PersistentKeepalive.
      await Future.delayed(const Duration(seconds: 15));

      // ── Step 5: Verify the tunnel is up ────────────────────────────────────
      //
      // Two checks must both pass:
      //   1. ifconfig wgcN shows an inet address (interface is up)
      //   2. wg show wgcN latest-handshakes returns a non-zero Unix timestamp
      //
      // ifconfig output when up:
      //   inet addr:x.x.x.x  P-t-P:x.x.x.x  Mask:255.255.255.255
      //
      // wg show output when handshake confirmed:
      //   <server-pubkey>    <unix-timestamp>
      //
      widget.onLog('Verifying tunnel (up to 90s)...');
      bool verified = false;

      for (int retry = 0; retry < 45; retry++) {
        widget.onActivity?.call();
        await Future.delayed(const Duration(seconds: 2));

        // Check 1: interface has an inet address.
        final ifOutput = await _run(
          client,
          'ifconfig wgc$slot 2>/dev/null | grep "inet " || echo "NOT_UP"',
        );
        if (ifOutput.contains('NOT_UP')) {
          widget.onLog('  Check ${retry + 1}/45: interface not yet up');
          continue;
        }

        // Check 2: WireGuard has a confirmed handshake (non-zero timestamp).
        final hsRaw = await _run(
          client,
          'wg show wgc$slot latest-handshakes 2>/dev/null',
        );
        final hsParts = hsRaw.split(RegExp(r'\s+'));
        final hsTs = hsParts.length >= 2 ? int.tryParse(hsParts.last) ?? 0 : 0;

        if (hsTs > 0) {
          verified = true;
          widget.onLog('  Check ${retry + 1}/45: handshake confirmed');
          break;
        }

        widget
            .onLog('  Check ${retry + 1}/45: interface up, awaiting handshake');
      }

      if (!verified) {
        throw Exception(
          'WireGuard handshake not detected after 90 seconds. '
          'Check tunnel status via SSH: wg show wgc$slot',
        );
      }

      // ── Success ─────────────────────────────────────────────────────────────
      final localIp = await _run(client, 'nvram get wgc${slot}_addr');
      widget.onLog(
        'Connected via $newDesc  |  local: $localIp',
        isSuccess: true,
      );
      widget.onLog('Push complete.', isSuccess: true);
      if (mounted) setState(() => _pushComplete = true);
    } catch (e) {
      // ── Error Recovery ───────────────────────────────────────────────────────
      //
      // If we know which slot was active before the push started, attempt to
      // restore it using the verified start sequence. This puts the router back
      // in its prior known-good state rather than leaving it with no active VPN.
      //
      if (activeSlot != null) {
        widget.onLog('Push failed — attempting to restore wgc$activeSlot...');
        try {
          await client?.run('nvram set wgc${activeSlot}_enable=1');
          await client?.run('nvram set wgc${activeSlot}_enforce=1');
          await client?.run('nvram commit');
          await client?.run('service start_wgc$activeSlot');
          await client?.run(_kRestartChain);
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
          ],
        ),
      ),
    );
  }
}
