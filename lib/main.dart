// main.dart
// Core UI Presentation layer optimized for lower layout overhead and cleaner flow handling.
//

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'pia_service.dart';
import 'router_push.dart';

void main() => runApp(const PiaWgApp());

const _kHighlight = Color(0xFF00D4AA);

class PiaWgApp extends StatelessWidget {
  const PiaWgApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PIA WireGuard Config',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          primary: _kHighlight,
          secondary: Color(0xFF00A882),
          surface: Color(0xFF1A1D23),
          error: Color(0xFFFF5C5C),
          onPrimary: Color(0xFF12141A),
          onSurface: Color(0xFFE8EAF0),
        ),
        useMaterial3: true,
        fontFamily: 'monospace',
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1E2128),
          border:
              OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF2E3240))),
          enabledBorder:
              OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF2E3240))),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _kHighlight, width: 1.5)),
          labelStyle: const TextStyle(color: Color(0xFF8892A4)),
          hintStyle: const TextStyle(color: Color(0xFF4A5268)),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _kHighlight,
            foregroundColor: const Color(0xFF12141A),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 0.5),
          ),
        ),
      ),
      home: const MainScreen(),
    );
  }
}

class _LogEntry {
  final String message;
  final bool isError, isSuccess;
  _LogEntry(this.message, {this.isError = false, this.isSuccess = false});
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  final _service = PiaService();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _regionCtrl = TextEditingController();
  final _dnsCtrl = TextEditingController(text: '9.9.9.9, 149.112.112.112');
  final _scrollCtrl = ScrollController();

  bool _passwordVisible = false, _loading = false, _loadingRegions = false;
  String? _generatedConfig;
  List<Region> _regions = [];
  final List<_LogEntry> _log = [];

  Timer? _wipeTimer;
  DateTime? _wipeDeadline;
  int _secondsRemaining = 0;

  Timer? _clipboardTimer;
  DateTime? _clipboardWipeDeadline;
  int _clipboardSecondsRemaining = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wipeTimer?.cancel();
    _clipboardTimer?.cancel();
    for (var controller in [_usernameCtrl, _passwordCtrl, _regionCtrl, _dnsCtrl, _scrollCtrl]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_wipeDeadline != null && _generatedConfig != null) {
        final remaining = _wipeDeadline!.difference(DateTime.now()).inSeconds;
        if (remaining <= 0) {
          _clearSession();
        } else {
          setState(() => _secondsRemaining = remaining);
        }
      }

      // Check if clipboard deadline passed while app was in background
      if (_clipboardWipeDeadline != null) {
        final remaining = _clipboardWipeDeadline!.difference(DateTime.now()).inSeconds;
        if (remaining <= 0) {
          _clearClipboard();
        } else {
          setState(() => _clipboardSecondsRemaining = remaining);
        }
      }
    }
  }

  void _logEntry(String msg, {bool isError = false, bool isSuccess = false}) {
    if (!mounted) {
      return;
    }
    final now = DateTime.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
//    if (_log.isEmpty && !msg.contains('Starting') && !_loading) return; // fix for erratic log clearing
    setState(() => _log.add(_LogEntry('[$ts] $msg', isError: isError, isSuccess: isSuccess)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  void _clearSession() {
    _wipeTimer?.cancel();
    _wipeTimer = null;
    _wipeDeadline = null;
    _usernameCtrl.clear();
    _passwordCtrl.clear();
    _clearClipboard();
    setState(() {
      _generatedConfig = null;
      _secondsRemaining = 0;
      _passwordVisible = false;
    });
    _logEntry('Session cleared.');
  }

  void _startOrResetTimer() {
    _wipeTimer?.cancel();
    _wipeDeadline = DateTime.now().add(const Duration(seconds: 180));
    _secondsRemaining = 180;

    _wipeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        return timer.cancel();
      }
      final remaining = _wipeDeadline!.difference(DateTime.now()).inSeconds;
      if (remaining <= 0) {
        timer.cancel();
        _clearSession();
      } else {
        setState(() => _secondsRemaining = remaining);
      }
    });
  }

  Future<void> _loadRegions() async {
    setState(() => _loadingRegions = true);
    _logEntry('Loading regions...');
    try {
      final regions = await _service.fetchRegions(onProgress: _logEntry);
      if (!mounted) {
        return;
      }
      setState(() => _regions = regions);
      final totalServers = regions.fold<int>(0, (sum, r) => sum + r.wgServers.length);
      _logEntry('Loaded ${regions.length} regions ($totalServers servers).');
      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF1A1D23),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        isScrollControlled: true,
        builder: (ctx) => _RegionPickerSheet(regions: _regions, onSelected: (id) => setState(() => _regionCtrl.text = id)),
      );
    } catch (e) {
      _logEntry('Failed to load regions: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _loadingRegions = false);
      }
    }
  }

  Future<void> _generate() async {
    final region = _regionCtrl.text.trim(),
        username = _usernameCtrl.text.trim(),
        password = _passwordCtrl.text.trim(),
        dns = _dnsCtrl.text.trim();
    if (region.isEmpty || username.isEmpty || password.isEmpty) {
      return _logEntry('Region, username, and password required.', isError: true);
    }

    setState(() {
      _loading = true;
      _generatedConfig = null;
    });
    _logEntry('Starting...');

    try {
      final config =
          await _service.generateConfig(region: region, username: username, password: password, dns: dns, onProgress: _logEntry);
      if (!mounted) {
        return;
      }
      setState(() => _generatedConfig = config);
      _logEntry('Config generated successfully.', isSuccess: true);
      _startOrResetTimer();
    } catch (e) {
      final cleanMsg = e.toString().replaceAll('Exception: ', '');
      _logEntry(cleanMsg, isError: true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _shareConfig() async {
    if (_generatedConfig == null) {
      return;
    }
    final region = _regionCtrl.text.trim(), filename = 'pia-$region.conf';
    final dir = await getTemporaryDirectory();
    final tempFile = File('${dir.path}/$filename');
    try {
      await tempFile.writeAsString(_generatedConfig!, flush: true);
      await SharePlus.instance.share(
          ShareParams(files: [XFile(tempFile.path, mimeType: 'text/plain')], subject: filename, text: 'PIA Config: $region'));
    } catch (e) {
      _logEntry('Could not share file: $e', isError: true);
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  Future<void> _launchUrlStr(String urlStr) async {
    final url = Uri.parse(urlStr);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.platformDefault);
    }
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF1A1D23),
      elevation: 0,
      title: Row(
        children: [
          Container(width: 8, height: 8, decoration: const BoxDecoration(color: _kHighlight, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('PIA WireGuard Config',
                  style: TextStyle(color: Color(0xFFE8EAF0), fontSize: 16, fontWeight: FontWeight.w600)),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'by ',
                    style: TextStyle(
                      color: Color(0xFF8892A4),
                      fontSize: 10,
                    ),
                  ),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: InkWell(
                      onTap: () => _launchUrlStr('https://www.exponentiallydigital.com'),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          'Exponentially Digital',
                          style: TextStyle(
                            color: Color(0xFF8892A4),
                            fontSize: 10,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Center(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: InkWell(
                onTap: () => _launchUrlStr('https://github.com/ExponentiallyDigital/pia-wireguard-cfga'),
                child: FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (context, snap) {
                    final versionText = snap.hasData ? 'v${snap.data!.version}' : 'v...';
                    return Text(
                      versionText,
                      style: const TextStyle(
                        color: Color(0xFF8892A4),
                        fontSize: 11,
                        decoration: TextDecoration.underline,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRegionRow() {
    return Row(
      children: [
        Expanded(
          child: TextFormField(
            controller: _regionCtrl,
            style: const TextStyle(color: Color(0xFFE8EAF0), fontFamily: 'monospace'),
            decoration: const InputDecoration(
                labelText: 'Region ID',
                hintText: 'e.g. aus_melbourne',
                prefixIcon: Icon(Icons.language, color: Color(0xFF8892A4), size: 18)),
          ),
        ),
        const SizedBox(width: 10),
        _IconButton(icon: Icons.list_alt, loading: _loadingRegions, tooltip: 'Browse regions', onTap: _loadRegions),
      ],
    );
  }

  Widget _buildUsernameField() {
    return TextFormField(
      controller: _usernameCtrl,
      style: const TextStyle(color: Color(0xFFE8EAF0), fontFamily: 'monospace'),
      decoration: const InputDecoration(
          labelText: 'PIA username',
          hintText: 'e.g. p1234567',
          prefixIcon: Icon(Icons.person_outline, color: Color(0xFF8892A4), size: 18)),
      autocorrect: false,
      enableSuggestions: false,
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordCtrl,
      obscureText: !_passwordVisible,
      style: const TextStyle(color: Color(0xFFE8EAF0), fontFamily: 'monospace'),
      decoration: InputDecoration(
        labelText: 'PIA password',
        prefixIcon: const Icon(Icons.lock_outline, color: Color(0xFF8892A4), size: 18),
        suffixIcon: GestureDetector(
          onTap: () => setState(() => _passwordVisible = !_passwordVisible),
          child: Icon(_passwordVisible ? Icons.visibility_off : Icons.visibility, color: const Color(0xFF8892A4), size: 18),
        ),
      ),
      autocorrect: false,
      enableSuggestions: false,
    );
  }

  Widget _buildDnsField() {
    return TextFormField(
      controller: _dnsCtrl,
      style: const TextStyle(color: Color(0xFFE8EAF0), fontFamily: 'monospace', fontSize: 13),
      decoration: const InputDecoration(
        labelText: 'DNS servers',
        hintText: '9.9.9.9, 149.112.112.112',
        prefixIcon: Icon(Icons.dns_outlined, color: Color(0xFF8892A4), size: 18),
        helperText: 'Default: Quad9 | Cloudflare: 1.1.1.1, 1.0.0.1',
        helperStyle: TextStyle(color: _kHighlight, fontSize: 11),
      ),
    );
  }

  Widget _buildGenerateButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _loading ? null : _generate,
        child: _loading
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF12141A)))
            : const Text('GENERATE CONFIG'),
      ),
    );
  }

  void _clearClipboard() async {
    _clipboardTimer?.cancel();
    _clipboardTimer = null;
    _clipboardWipeDeadline = null;
    setState(() => _clipboardSecondsRemaining = 0);
    await Clipboard.setData(const ClipboardData(text: ''));
    _logEntry('Clipboard auto cleared.');
  }

  Future<void> _copyToClipboard() async {
    if (_generatedConfig == null) return;
    await Clipboard.setData(ClipboardData(text: _generatedConfig!));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Config copied'), backgroundColor: _kHighlight));
    }

    // Start or reset the 60-second countdown
    _clipboardTimer?.cancel();
    _clipboardWipeDeadline = DateTime.now().add(const Duration(seconds: 60));
    setState(() => _clipboardSecondsRemaining = 60);

    _clipboardTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        return timer.cancel();
      }
      final remaining = _clipboardWipeDeadline!.difference(DateTime.now()).inSeconds;
      if (remaining <= 0) {
        timer.cancel();
        _clearClipboard();
      } else {
        setState(() => _clipboardSecondsRemaining = remaining);
      }
    });
  }

  List<Widget> _buildTimerWidget() {
    final isUrgent = _secondsRemaining <= 30;
    final timerColor = isUrgent ? const Color(0xFFFF5C5C) : _kHighlight;
    return [
      Icon(Icons.timer_outlined, size: 12, color: timerColor),
      const SizedBox(width: 4),
      Text('${_secondsRemaining}s', style: TextStyle(color: timerColor, fontSize: 11)),
      const SizedBox(width: 12),
    ];
  }

  List<Widget> _buildGeneratedConfigSection() {
    return [
      const SizedBox(height: 24),
      Row(
        children: [
          const Text('GENERATED CONFIG',
              style: TextStyle(color: _kHighlight, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
          const Spacer(),
          if (_secondsRemaining > 0) ..._buildTimerWidget(),
          _ClearButton(label: 'CLEAR CREDS & CFG', icon: Icons.delete_outline, onTap: _clearSession),
        ],
      ),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: const Color(0xFF0E1016), borderRadius: BorderRadius.circular(8), border: Border.all(color: _kHighlight)),
        child: SelectableText(_generatedConfig ?? '',
            style: const TextStyle(color: _kHighlight, fontFamily: 'monospace', fontSize: 11, height: 1.6)),
      ),
      const SizedBox(height: 16),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  onPressed: _copyToClipboard,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('COPY'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _kHighlight,
                      side: const BorderSide(color: _kHighlight),
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
                if (_clipboardSecondsRemaining > 0) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Clearing clipboard in $_clipboardSecondsRemaining seconds',
                    style: const TextStyle(
                      color: Color(0xFFFF5C5C),
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _shareConfig,
              icon: const Icon(Icons.share, size: 16),
              label: const Text('SHARE / SAVE'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: _kHighlight,
                  side: const BorderSide(color: _kHighlight),
                  padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _showRouterPushSheet,
          icon: const Icon(Icons.router, size: 16),
          label: const Text('PUSH CONFIG TO ROUTER...'),
          style: OutlinedButton.styleFrom(
              foregroundColor: _kHighlight,
              side: const BorderSide(color: _kHighlight),
              padding: const EdgeInsets.symmetric(vertical: 14)),
        ),
      ),
    ];
  }

  void _showRouterPushSheet() {
    // Reset timer immediately when opening the workflow
    _startOrResetTimer();

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF1A1D23),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            // Every time the user interacts with the dialog screen, refresh the session timer
            _startOrResetTimer();
          },
          child: RouterPushSheet(
            config: _generatedConfig!,
            regionId: _regionCtrl.text.trim(),
            onLog: _logEntry,
            onActivity: _startOrResetTimer, // Hooks programmatic tasks to your keepalive mechanism
          ),
        ),
      ),
    );
  }

  Widget _buildLogSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_log.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8), // Clean spacing above the box
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end, // Pushes everything to the far right
              mainAxisSize: MainAxisSize.max,
              children: [
                _ClearButton(label: 'CLEAR LOG', icon: Icons.delete_outline, onTap: () => setState(() => _log.clear())),
              ],
            ),
          ),
        InputDecorator(
          decoration: const InputDecoration(
            labelText: 'LOG',
          ),
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _LogPanel(entries: _log, onClearLog: () => setState(() => _log.clear())),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final shouldResetTimer = _generatedConfig != null && _wipeTimer != null;

    return Listener(
      onPointerDown: (_) => shouldResetTimer ? _startOrResetTimer() : null,
      behavior: HitTestBehavior.translucent,
      child: Scaffold(
        backgroundColor: const Color(0xFF12141A),
        appBar: _buildAppBar(),
        body: SafeArea(
          child: SingleChildScrollView(
            controller: _scrollCtrl,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildRegionRow(),
                const SizedBox(height: 16),
                _buildUsernameField(),
                const SizedBox(height: 12),
                _buildPasswordField(),
                const SizedBox(height: 16),
                _buildDnsField(),
                const SizedBox(height: 28),
                _buildGenerateButton(),
                if (_generatedConfig != null) ..._buildGeneratedConfigSection(),
                const SizedBox(height: 32),
                _buildLogSection(),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ClearButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _ClearButton({required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
//      behavior: HitTestBehavior.opaque, // <-- fix for erratic behaviour
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: const Color(0xFF2A1515),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFFFF5C5C).withAlpha(128))),
        child: Row(
          children: [
            Icon(icon, size: 12, color: const Color(0xFFFF5C5C)),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(color: Color(0xFFFF5C5C), fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
          ],
        ),
      ),
    );
  }
}

class _RegionPickerSheet extends StatefulWidget {
  final List<Region> regions;
  final void Function(String) onSelected;
  const _RegionPickerSheet({required this.regions, required this.onSelected});
  @override
  State<_RegionPickerSheet> createState() => _RegionPickerSheetState();
}

class _RegionPickerSheetState extends State<_RegionPickerSheet> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.regions.where((r) => r.id.toLowerCase().contains(_filter.toLowerCase())).toList();
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (ctx, scrollCtrl) => Column(
        children: [
          const SizedBox(height: 12),
          Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: const Color(0xFF2E3240), borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              autofocus: true,
              style: const TextStyle(color: Color(0xFFE8EAF0), fontFamily: 'monospace'),
              decoration: const InputDecoration(
                  hintText: 'Filter regions...', prefixIcon: Icon(Icons.search, color: Color(0xFF8892A4), size: 18)),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              controller: scrollCtrl,
              itemCount: filtered.length,
              itemBuilder: (ctx, i) {
                final r = filtered[i];
                return InkWell(
                  onTap: () {
                    widget.onSelected(r.id);
                    Navigator.pop(ctx);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    child: Row(
                      children: [
                        const Icon(Icons.chevron_right, color: _kHighlight, size: 16),
                        const SizedBox(width: 10),
                        Expanded(
                            child: Text(r.id,
                                style: const TextStyle(color: Color(0xFFE8EAF0), fontFamily: 'monospace', fontSize: 13))),
                        Text('${r.wgServers.length} server${r.wgServers.length == 1 ? '' : 's'}',
                            style: const TextStyle(color: Color(0xFF4A5268), fontSize: 11)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  final IconData icon;
  final bool loading;
  final String tooltip;
  final VoidCallback onTap;
  const _IconButton({required this.icon, required this.loading, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: loading ? null : onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
                color: const Color(0xFF1E2128),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF2E3240))),
            child: loading
                ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2, color: _kHighlight))
                : Icon(icon, color: _kHighlight, size: 20),
          ),
        ),
      );
}

class _LogPanel extends StatelessWidget {
  final List<_LogEntry> entries;
  final VoidCallback onClearLog;
  const _LogPanel({required this.entries, required this.onClearLog});

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (entries.isEmpty)
            const Text('Ready.', style: TextStyle(color: _kHighlight, fontSize: 11, fontFamily: 'monospace'))
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: entries.map((e) {
                final Color color;
                if (e.isSuccess) {
                  color = Colors.white;
                } else if (e.isError) {
                  color = const Color(0xFFFF5C5C);
                } else {
                  color = _kHighlight;
                }

                final IconData icon;
                if (e.isSuccess) {
                  icon = Icons.check_circle_outline;
                } else if (e.isError) {
                  icon = Icons.error_outline;
                } else {
                  icon = Icons.info_outline;
                }

                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, size: 12, color: color),
                      const SizedBox(width: 6),
                      Expanded(
                          child: Text(e.message,
                              style: TextStyle(color: color, fontSize: 11, fontFamily: 'monospace', height: 1.4))),
                    ],
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}
