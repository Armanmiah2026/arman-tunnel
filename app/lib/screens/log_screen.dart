import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/location_service.dart';
import '../services/log_service.dart';
import '../theme/snapdark_theme.dart';
import '../utils/banner_renderer.dart';
import '../widgets/app_toast.dart';
import '../widgets/ui/snapdark_controls.dart';
import 'main_shell.dart';

/// Severity buckets used to colour log lines.
enum LogType { normal, success, warning, error, banner }

/// Classify a raw engine log line.
///
/// Banner-style blocks are detected first: they are multi-line HTML / box-drawing
/// blobs from the server (an SSH MOTD, or a bug host's HTTP response) and belong
/// in their own card, not as one coloured log line.
LogType classifyLog(String log) {
  final l = log.toLowerCase();
  final looksLikeBanner = l.contains('server message') ||
      l.contains('upstream replied:') ||
      (l.contains('proxy replied:') && l.contains('<font')) ||
      log.contains('╭') ||
      log.contains('╰') ||
      log.contains('═') ||
      l.contains('powered by') ||
      l.contains('no ddos') ||
      l.contains('no hacking') ||
      l.contains('vps script') ||
      l.contains('server reboot');
  if (looksLikeBanner) return LogType.banner;
  if (l.contains('error') || l.contains('fail') || l.contains('err:')) {
    return LogType.error;
  }
  if (l.contains('warn')) return LogType.warning;
  if (l.contains('connected') ||
      l.contains('auth complete') ||
      l.contains('ready') ||
      l.contains('success') ||
      l.contains('handshaked') ||
      l.contains('complete')) {
    return LogType.success;
  }
  return LogType.normal;
}

/// Connection log tab: device/session facts on top, live engine log below.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final _scroll = ScrollController();
  late Future<String> _localIps;
  bool _showInfo = true;

  /// When true, new lines pin the view to the bottom. Scrolling up releases it.
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    _localIps = _readLocalIps();
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom =
        _scroll.offset >= _scroll.position.maxScrollExtent - 40;
    if (atBottom != _follow) setState(() => _follow = atBottom);
  }

  /// Non-loopback IPv4 addresses of the device (LAN / hotspot / tunnel).
  Future<String> _readLocalIps() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final ips = <String>[];
      for (final i in ifaces) {
        for (final a in i.addresses) {
          ips.add('${a.address} (${i.name})');
        }
      }
      return ips.isEmpty ? 'n/a' : ips.join('\n');
    } catch (_) {
      return 'n/a';
    }
  }

  void _scrollToEndSoon() {
    if (!_follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _copyAll() async {
    final logs = context.read<LogService>().entries.join('\n');
    if (logs.isEmpty) {
      AppToast.warning(context, 'Nothing to copy');
      return;
    }
    await Clipboard.setData(ClipboardData(text: logs));
    if (mounted) AppToast.success(context, 'Logs copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.scaffoldBg,
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            tooltip: _showInfo ? 'Hide device info' : 'Show device info',
            icon: Icon(
              _showInfo ? Icons.smartphone_rounded : Icons.info_outline_rounded,
            ),
            onPressed: () => setState(() => _showInfo = !_showInfo),
          ),
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_rounded),
            onPressed: _copyAll,
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => context.read<LogService>().clear(),
          ),
          const SizedBox(width: SnapDarkTokens.gapXs),
        ],
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: t.pageGradient,
          ),
        ),
        child: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: SnapDarkTokens.maxContentWidth,
              ),
              // The cap MUST be computed from the Column's own slot: RenderFlex
              // hands non-flex children an INFINITE max height (that is exactly
              // why the fixed card used to overflow instead of compress), so a
              // LayoutBuilder INSIDE the column sees ∞ and never caps
              // anything. Outside, box.maxHeight is the real body height.
              child: LayoutBuilder(
                builder: (context, box) => Column(
                  children: [
                    // The device card is a stack of fixed-height stat rows and
                    // used to claim its FULL intrinsic height: on a high-density
                    // phone (288x568 logical at 400 dpi) the rows alone exceeded
                    // the body and threw "BOTTOM overflowed by 269 pixels",
                    // clipping the log list to zero. Cap it at 45% of the body
                    // (large screens: unchanged, the natural height fits) and
                    // let it scroll internally when squeezed — the log list
                    // always keeps the rest.
                    if (_showInfo)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: box.maxHeight * 0.45,
                        ),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(
                            SnapDarkTokens.pageInset,
                            SnapDarkTokens.gapSm,
                            SnapDarkTokens.pageInset,
                            SnapDarkTokens.gapSm,
                          ),
                          child: _deviceCard(),
                        ),
                      ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        SnapDarkTokens.pageInset,
                        SnapDarkTokens.gapXs,
                        SnapDarkTokens.pageInset,
                        SnapDarkTokens.gapXxl * 2,
                      ),
                      child: Consumer<LogService>(
                        builder: (_, logService, __) {
                          final entries = logService.entries;
                          if (entries.isEmpty) {
                            return const SnapDarkEmptyState(
                              icon: Icons.terminal_rounded,
                              title: 'No logs yet',
                              message:
                                  'Engine output appears here as soon as you '
                                  'start a connection.',
                            );
                          }
                          _scrollToEndSoon();
                          return SnapDarkCard(
                            padding: const EdgeInsets.symmetric(
                              horizontal: SnapDarkTokens.gapMd,
                              vertical: SnapDarkTokens.gapSm,
                            ),
                            child: ListView.builder(
                              controller: _scroll,
                              padding: EdgeInsets.zero,
                              itemCount: entries.length,
                              itemBuilder: (_, i) => _LogLine(
                                log: entries[i],
                                type: classifyLog(entries[i]),
                              ),
                            ),
                          );
                        },
                      ),
                     ),
                   ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _deviceCard() {
    final t = context.tokens;
    final loc = context.watch<LocationService>();
    final info = loc.info;
    final publicIp = loc.loading
        ? 'detecting…'
        : (info?.ip.isNotEmpty == true ? info!.ip : 'n/a');
    final place = info == null
        ? ''
        : [info.city, info.country].where((s) => s.isNotEmpty).join(', ');

    return SnapDarkCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SnapDarkTokens.gap,
              SnapDarkTokens.gapMd,
              SnapDarkTokens.gapSm,
              SnapDarkTokens.gapSm,
            ),
            child: Row(
              children: [
                Icon(Icons.smartphone_rounded, color: t.accent, size: 16),
                const SizedBox(width: SnapDarkTokens.gapSm),
                Expanded(
                  child: Text('DEVICE & SESSION', style: t.overline),
                ),
                IconButton(
                  tooltip: 'Re-detect',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.refresh_rounded, color: t.textMuted, size: 17),
                  onPressed: () {
                    loc.detect();
                    setState(() => _localIps = _readLocalIps());
                  },
                ),
              ],
            ),
          ),
          Divider(height: 1, color: t.border),
          const SnapDarkStatRow(
            label: 'App',
            value: 'SnapDark Tunnel v$kAppVersion',
          ),
          SnapDarkStatRow(
            label: 'System',
            value:
                '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
            mono: true,
          ),
          FutureBuilder<String>(
            future: _localIps,
            builder: (_, snap) => SnapDarkStatRow(
              label: 'Local IP',
              value: snap.data ?? '…',
              mono: true,
              selectable: true,
            ),
          ),
          SnapDarkStatRow(
            label: 'Public IP',
            value: publicIp,
            mono: true,
            selectable: true,
          ),
          if (place.isNotEmpty) SnapDarkStatRow(label: 'Location', value: place),
          if (info?.isp.isNotEmpty == true)
            SnapDarkStatRow(label: 'ISP', value: info!.isp),
          const SizedBox(height: SnapDarkTokens.gapSm),
        ],
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  final String log;
  final LogType type;

  const _LogLine({required this.log, required this.type});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    if (type == LogType.banner) {
      // Strip our own prefix so the server's own layout is preserved, and label
      // the card by what produced it.
      String html = log;
      var heading = 'SERVER MESSAGE';
      for (final entry in const {
        'Server Message:': 'SERVER MESSAGE',
        'Proxy replied:': 'PROXY REPLY',
        'upstream replied:': 'UPSTREAM REPLY',
      }.entries) {
        final i = log.indexOf(entry.key);
        if (i >= 0) {
          html = log.substring(i + entry.key.length).trim();
          heading = entry.value;
          break;
        }
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: SnapDarkTokens.gapSm),
        child: Container(
          padding: const EdgeInsets.all(SnapDarkTokens.gapMd),
          decoration: BoxDecoration(
            color: t.accentWash,
            borderRadius: SnapDarkTokens.brSm,
            border: Border.all(color: t.accent.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.campaign_rounded, size: 13, color: t.accent),
                  const SizedBox(width: 6),
                  Text(heading, style: t.overline),
                ],
              ),
              const SizedBox(height: SnapDarkTokens.gapSm),
              buildBannerWidget(context, html),
            ],
          ),
        ),
      );
    }

    final (Color color, IconData? icon) = switch (type) {
      LogType.success => (t.accent, Icons.check_circle_rounded),
      LogType.warning => (t.warning, Icons.warning_amber_rounded),
      LogType.error => (t.alert, Icons.error_rounded),
      LogType.normal => (t.textSecondary, null),
      LogType.banner => (t.accent, null),
    };

    final baseStyle = t.mono(
      size: 11.5,
      weight: FontWeight.w500,
      color: color,
      height: 1.45,
    );

    // Any line carrying markup is rendered, not printed as tag soup: proxies
    // and SSH servers put coloured HTML in ordinary replies too, and only the
    // MOTD banner used to get formatted. The timestamp prefix our own logger
    // adds stays plain text so the line still reads like a log entry.
    Widget body;
    if (looksLikeHtml(log)) {
      final m = RegExp(r'^\[\d{2}:\d{2}:\d{2}\]\s*').firstMatch(log);
      final prefix = m?.group(0) ?? '';
      final rest = log.substring(prefix.length);
      body = Text.rich(
        TextSpan(
          children: [
            if (prefix.isNotEmpty)
              TextSpan(
                text: prefix,
                style: baseStyle.copyWith(color: t.textMuted),
              ),
            ...buildHtmlSpans(context, rest, baseStyle),
          ],
        ),
      );
    } else {
      body = Text(log, style: baseStyle);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            child: icon == null
                ? Text('›', style: t.mono(size: 11.5, color: t.textMuted))
                : Icon(icon, size: 12, color: color),
          ),
          const SizedBox(width: 4),
          Expanded(child: body),
        ],
      ),
    );
  }
}
