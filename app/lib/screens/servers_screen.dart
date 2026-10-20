import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import '../models/server_config.dart';
import '../models/vpn_state.dart';
import '../services/config_service.dart';
import '../services/config_share.dart';
import '../services/device_trial.dart';
import '../services/server_ping_cache.dart';
import '../services/settings_provider.dart';
import '../utils/banner_renderer.dart';
import '../theme/snapdark_theme.dart';
import '../utils/format.dart';
import '../widgets/app_toast.dart';
import '../widgets/hacker_loader.dart';
import '../widgets/server_card.dart';
import '../widgets/ui/snapdark_controls.dart';
import '../widgets/ui/snapdark_modal.dart';
import '../widgets/vip_unlock_sheet.dart';
import 'add_config_screen.dart';

/// The Configs list: one section per Tweak category published by the admin
/// panel (with the category's flag), plus the user's own "My Configs".
///
/// "My Configs" floats to the TOP while it has entries (the user's own
/// imports matter most) and drops to the bottom when empty.
///
/// Used both as a pushed route and as the "Configs" tab of `MainShell`; see
/// [onServerSelected] for why that distinction matters.
class ServersScreen extends StatefulWidget {
  /// Called after a config is picked.
  ///
  /// As a pushed route the screen closes itself. Inside the shell's IndexedStack
  /// there is no route above the shell, so popping would tear down the shell —
  /// the host passes a callback (e.g. "switch to Home") instead.
  final VoidCallback? onServerSelected;

  const ServersScreen({super.key, this.onServerSelected});

  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  String _query = '';

  /// Per-card latency badges: sweep while this list is on screen, stop the
  /// timer when it goes away so nothing probes in the background.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startPings());
  }

  @override
  void dispose() {
    ServerPingCache.instance.stop();
    super.dispose();
  }

  void _startPings() {
    if (!mounted) return;
    final servers = context.read<ConfigService>().officialServers;
    if (servers.isEmpty) return;
    ServerPingCache.instance.start(
      servers,
      // Needed to resolve vaulted VIP endpoints — a locked one is skipped, an
      // unlocked one gets its real address (and a badge) from the Worker.
      settings: context.read<SettingsProvider>(),
      config: context.read<ConfigService>(),
    );
  }

  /// Which top tab is active: 'mine' (My Configs), 'official' (category
  /// groups) or 'vip' (VIP Servers). My Configs leads by default when it
  /// has entries; otherwise Official.
  String _tab = 'official';

  /// Collapsed group titles. Groups are open by default; the set tracks the
  /// exceptions so a fresh install shows everything.
  final _collapsed = <String>{};

  /// Leave the picker after a selection: pop when we were pushed, otherwise
  /// hand control back to the shell.
  void _finishSelection() {
    if (widget.onServerSelected != null) {
      widget.onServerSelected!();
      return;
    }
    if (Navigator.of(context).canPop()) Navigator.pop(context);
  }

  bool _matches(ServerConfig s) {
    if (_query.isEmpty) return true;
    // Locked configs are not matched by their server identity — searching for
    // an IP must not reveal that a locked node lives on it.
    final searchable = s.locked
        ? '${s.name} ${s.note} ${s.protocolLabel}'
        : '${s.name} ${s.note} ${s.address} ${s.protocolLabel}';
    return searchable.toLowerCase().contains(_query);
  }

  Future<void> _refresh() async {
    final cfg = context.read<ConfigService>();
    await HackerLoader.run(
      context,
      () => cfg.loadServers(manual: true),
      title: 'FETCHING CONFIGS',
    );
    if (!mounted) return;
    if (cfg.lastRefreshFailed) {
      AppToast.warning(context, 'Update failed — showing cached configs');
    } else {
      AppToast.success(context, 'Configs updated (${cfg.officialServers.length})');
    }
  }

  void _select(ServerConfig s) {
    if (s.locked) {
      AppToast.error(context, s.lockMessage ?? 'Locked by admin');
      return;
    }
    if (s.isExpired) {
      AppToast.error(context, s.blockedReason);
      return;
    }
    if (s.vip) {
      // VIP: rewarded-ad gate. This is async — the user might watch the ad
      // and unlock, or back out (then nothing is selected).
      _selectWithVipGate(s);
      return;
    }
    context.read<ConfigService>().selectServer(s);
    AppToast.success(context, '${s.displayName} selected');
    _finishSelection();
  }

  Future<void> _selectWithVipGate(ServerConfig s) async {
    final unlocked = await ensureVipUnlocked(context, s);
    if (!mounted || !unlocked) return;
    context.read<ConfigService>().selectServer(s);
    AppToast.success(context, '${s.displayName} selected');
    _finishSelection();
  }

  Future<void> _delete(ServerConfig s) async {
    final ok = await SnapDarkModal.confirm(
      context,
      title: 'Delete config?',
      message: '"${s.displayName}" will be removed from this device.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (!ok || !mounted) return;
    await context.read<ConfigService>().removeServer(s.id);
    if (mounted) AppToast.success(context, 'Config deleted');
  }

  /// Share one config — ALL of the channels (locked-aware) live in
  /// [ConfigShare], the single source of share/export logic.
  void _share(ServerConfig s) => ConfigShare.shareOne(context, s);

  /// Per-config actions in ONE branded bottom sheet (the card kebab). A
  /// locked share offers only note + delete — sharing or editing it would
  /// leak the sharer's protected fields.
  Future<void> _showActions(ServerConfig s) async {
    final action = await SnapDarkModal.sheet<_CardAction>(
      context,
      builder: (ctx) => _CardActionSheet(server: s),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _CardAction.note:
        _showNote(s);
      case _CardAction.share:
        _share(s);
      case _CardAction.edit:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AddConfigScreen(editConfig: s)),
        );
      case _CardAction.delete:
        _delete(s);
    }
  }

  /// Import / export behind the app-bar action — same sheet design as the
  /// card menu, replacing the stock PopupMenu dropdown.
  Future<void> _importExportSheet() async {
    final action = await SnapDarkModal.sheet<String>(
      context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetAction(
            icon: Icons.file_open_outlined,
            title: 'Import from file',
            subtitle: '.st / .cfg / .ovpn / backup',
            color: context.tokens.lime,
            onTap: () => Navigator.pop(ctx, 'import'),
          ),
          const SizedBox(height: SnapDarkTokens.gapSm),
          _SheetAction(
            icon: Icons.ios_share_rounded,
            title: 'Export configs…',
            subtitle: 'One .st bundle of your custom configs',
            color: context.tokens.accent,
            onTap: () => Navigator.pop(ctx, 'export'),
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'import') _importFile();
    if (action == 'export') ConfigShare.exportAll(context);
  }

  /// The config note popup. Notes render through the same HTML walker the
  /// log view uses, so a sharer can colour/style the message (brand palette
  /// clamps everything to green/lime/amber) and it reads as intended.
  void _showNote(ServerConfig s) {
    final t = context.tokens;
    final parts = <String>[
      if ((s.lockMessage ?? '').trim().isNotEmpty) s.lockMessage!.trim(),
      if (s.note.trim().isNotEmpty && s.note.trim() != s.name)
        s.note.trim(),
    ];
    final body = parts.isEmpty ? 'No note on this config.' : parts.join('\n\n');
    final meta = <String>[
      if ((s.author ?? '').trim().isNotEmpty) 'By ${s.author!.trim()}',
      if (s.expiresAt != null)
        'Expires: ${DateTime.fromMillisecondsSinceEpoch(s.expiresAt!).toLocal()}'
            .split('.').first,
      if (s.locked) 'This config is locked — fields are hidden.',
    ];
    SnapDarkModal.popup<void>(
      context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.sticky_note_2_outlined, color: t.accent, size: 26),
        title: Text(s.displayName, textAlign: TextAlign.center),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: TextSpan(
                  children: buildHtmlSpans(
                    ctx,
                    body,
                    TextStyle(color: t.text, fontSize: 13.5, height: 1.45),
                  ),
                ),
              ),
              if (meta.isNotEmpty) ...[
                const SizedBox(height: SnapDarkTokens.gapMd),
                Text(
                  meta.join('\n'),
                  style: TextStyle(color: t.textMuted, fontSize: 11.5),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Ask for the PIN of a user-locked share before importing it.
  Future<String?> _askLockPin(String text) {
    return SnapDarkModal.edit(
      context,
      title: 'Locked config',
      description: 'This config is locked by its sharer. Enter the PIN they '
          'gave you to open it.',
      fields: const [
        SnapDarkModalField(label: 'Lock PIN', hint: 'required'),
      ],
      saveLabel: 'Unlock & import',
    ).then((out) => (out == null || out.isEmpty) ? null : out.first.trim());
  }

  /// Import from a picked file: .cfg/.txt (key=value share text or a
  /// armantunnel:// backup), or an .ovpn profile. Uses the same
  /// [ConfigService.importFromText] path as clipboard imports, so every format
  /// stays in one place.
  /// Import from a picked file. ALL format logic lives in
  /// [ConfigService.importFromText] — the one parser every entry point uses
  /// (.st single/multi-section, armantunnel:// links, protocol links,
  /// .ovpn bodies, locked envelopes, raw JSON).
  Future<void> _importFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (res == null || res.files.isEmpty || !mounted) return;
      final f = res.files.first;
      String content;
      if (f.bytes != null) {
        content = utf8.decode(f.bytes!, allowMalformed: true);
      } else if (f.path != null) {
        content = await File(f.path!).readAsString();
      } else {
        return;
      }
      content = content.trim();
      if (!mounted) return;
      if (content.isEmpty) {
        AppToast.error(context, 'File is empty.');
        return;
      }
      // A user-locked share (.v2p envelope) needs the sharer's PIN.
      String? lockPin;
      if (isPinLockedText(content)) {
        final pin = await _askLockPin(content);
        if (pin == null || pin.isEmpty || !mounted) return;
        lockPin = pin;
      }
      ImportResult r;
      try {
        r = await context
            .read<ConfigService>()
            .importFromText(content, lockPin: lockPin);
      } on LockPinRequired {
        final pin = await _askLockPin(content);
        if (pin == null || pin.isEmpty || !mounted) return;
        r = await context
            .read<ConfigService>()
            .importFromText(content, lockPin: pin);
      }
      if (!mounted) return;
      if (r.count > 0) {
        AppToast.success(
            context, 'Imported ${r.count} config(s) from ${f.name}');
      } else {
        AppToast.error(context, 'Could not import ${f.name}.');
      }
    } on LockPinRequired {
      if (mounted) AppToast.error(context, 'This config is PIN-locked.');
    } catch (e, st) {
      logImportError('file', e, st);
      if (mounted) AppToast.error(context, 'Could not read that file.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final cfg = context.watch<ConfigService>();
    final vpn = context.watch<VpnState>();
    final connectedName = vpn.isConnected ? vpn.connectedServerName : '';

    final official = cfg.officialServers;
    final custom = cfg.customServers;
    final hasCustom = custom.isNotEmpty;

    // The feed's official half is tweaks (joined configs) PLUS standalone
    // proxy nodes (the panel publishes socks/http_proxy/psiphon servers with
    // capability DIRECT). The split:
    //   · Tunnels tab — tweaks ONLY. A bare endpoint server has no tweak
    //     riding it and must never fill the category groups (the user saw
    //     servers without tweaks there — only proxies come tweak-less).
    //   · BDIX Servers tab — EVERY standalone proxy, VIP-flagged or not.
    //     VIP cards keep their premium badge; ads off means all unlocked.
    //
    // Proxy detection is PROTOCOL-based (mirror of the panel's isProxyNode in
    // config-schema.js): a bare socks/http_proxy/psiphon server IS its own
    // node. The old capability=='DIRECT' check let VLESS tweaks leak in —
    // a tweak whose capability type was removed in the panel (or a
    // method-less tweak that infers DIRECT) carries capability DIRECT while
    // its protocol is still vless, and showed up under BDIX Servers.
    bool isProxyNode(ServerConfig s) {
      final p = s.protocol;
      return p == ProtocolType.socks ||
          p == ProtocolType.httpProxy ||
          p == ProtocolType.psiphon;
    }
    final proxies = official.where(isProxyNode).toList();
    final tweaks = official.where((s) => !isProxyNode(s)).toList();
    final hasVip = proxies.isNotEmpty;

    // One group per published category, in panel order. Configs whose
    // category has no section (legacy leftovers) fall into a trailing
    // "Other" group so nothing ever disappears.
    final sections = <_Section>[];
    final matched = <String>{};
    for (final cat in cfg.displayCategories) {
      final items = tweaks
          .where((s) => s.category.toLowerCase() == cat.name.toLowerCase())
          .toList();
      matched.addAll(items.map((s) => s.id));
      sections.add(_Section(
        title: cat.name,
        // Section flag: the category's REAL flag emoji (same convention as
        // the cards — GeoGlyph's ISO chip read as a letter pair).
        flag: Text(
          normalizeCountryCode(cat.country) == null
              ? '🌐'
              : String.fromCharCodes(
                  normalizeCountryCode(cat.country)!.codeUnits
                      .map((u) => 0x1F1E6 + (u - 0x41)),
                ),
          style: const TextStyle(fontSize: 15),
        ),
        servers: items,
      ));
    }
    final orphans = tweaks.where((s) => !matched.contains(s.id)).toList();
    if (orphans.isNotEmpty) {
      sections.add(_Section(
        title: 'Other',
        flag: const Icon(Icons.public_rounded, size: 15),
        servers: orphans,
      ));
    }

    final customSection = _Section(
      title: 'My Configs',
      flag: const Icon(Icons.person_rounded, size: 15),
      servers: custom,
      isCustom: true,
      emptyHint: 'Nothing imported yet — use + above.',
    );
    final vipSection = _Section(
      title: 'BDIX Servers',
      flag: const Icon(Icons.workspace_premium_rounded, size: 15),
      servers: proxies,
    );

    // Three-tab layout: My Configs (only when the user has own configs),
    // Tunnels (tweaks, always), BDIX Servers (standalone proxies, only when
    // any exist). The active tab decides which single page renders — no
    // proxy node ever fills a category group.
    final tabs = <String>[
      if (hasCustom) 'mine',
      'official',
      if (hasVip) 'vip',
    ];
    if (!tabs.contains(_tab)) _tab = tabs.first;
    final visibleSections = switch (_tab) {
      'mine' => [customSection],
      'vip' => [vipSection],
      _ => sections,
    };

    return Scaffold(
      backgroundColor: t.scaffoldBg,
      appBar: AppBar(
        title: const Text('Configs'),
        actions: [
          IconButton(
            tooltip: 'Add config',
            icon: const Icon(Icons.add_circle_outline_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AddConfigScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Refresh configs',
            icon: const Icon(Icons.sync_rounded),
            onPressed: _refresh,
          ),
          // Import/export live behind ONE action — four inline icons had
          // accumulated here and drowned out the primary actions. Opens the
          // same branded sheet the cards use (no stock dropdown).
          IconButton(
            tooltip: 'Import / Export',
            icon: const Icon(Icons.unfold_more_rounded),
            onPressed: _importExportSheet,
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
              child: RefreshIndicator(
                onRefresh: () async {
                  final cfgService = context.read<ConfigService>();
                  final settingsProvider = context.read<SettingsProvider>();
                  await cfgService.loadServers(manual: true);
                  // Feed may have changed — re-point the sweep at the new
                  // list and re-measure right away.
                  if (!mounted) return;
                  final servers = cfgService.officialServers;
                  if (servers.isNotEmpty) {
                    ServerPingCache.instance.start(
                      servers,
                      settings: settingsProvider,
                      config: cfgService,
                    );
                    await ServerPingCache.instance.refreshNow(servers);
                  }
                },
                color: t.accent,
                backgroundColor: t.surface,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    SnapDarkTokens.pageInset,
                    SnapDarkTokens.gapSm,
                    SnapDarkTokens.pageInset,
                    SnapDarkTokens.gapXxl * 2,
                  ),
                  children: [
                    SnapDarkSearchField(
                      hint: 'Search configs…',
                      onChanged: (v) =>
                          setState(() => _query = v.trim().toLowerCase()),
                    ),
                    // Three-tab switch: My Configs (only when the user has
                    // own configs), Official (always), VIP Servers (only when
                    // VIP configs exist). Same SnapDarkSegmented chrome as
                    // before — colors, rounded corners, icons, spacing and
                    // the active-tab animation are untouched.
                    if (tabs.length > 1) ...[
                      const SizedBox(height: SnapDarkTokens.gap),
                      SnapDarkSegmented<String>(
                        values: tabs,
                        selected: _tab,
                        onChanged: (v) => setState(() => _tab = v),
                        label: (v) => switch (v) {
                          'mine' => 'My Configs',
                          'vip' => 'BDIX Servers',
                          _ => 'Tunnels',
                        },
                        iconFor: (v) => switch (v) {
                          'mine' => Icons.person_rounded,
                          'vip' => Icons.workspace_premium_rounded,
                          _ => Icons.verified_outlined,
                        },
                      ),
                    ],
                    const SizedBox(height: SnapDarkTokens.gap),
                    if (_tab == 'vip') ...[
                      const _BdixTrialBanner(),
                      const SizedBox(height: SnapDarkTokens.gap),
                    ],
                    if (official.isEmpty && custom.isEmpty)
                      Padding(
                        padding:
                            const EdgeInsets.only(top: SnapDarkTokens.gapXxl),
                        child: SnapDarkEmptyState(
                          icon: Icons.dns_rounded,
                          title: 'No configs yet',
                          message:
                              'Pull to refresh the official feed, or import a '
                              'vless:// / vmess:// / .ovpn config.',
                          actionLabel: 'Import config',
                          onAction: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const AddConfigScreen(),
                            ),
                          ),
                        ),
                      ),
                    for (final section in visibleSections)
                      _group(
                        title: section.title,
                        flag: section.flag,
                        servers: section.servers,
                        isCustom: section.isCustom,
                        emptyHint: section.emptyHint,
                        cfg: cfg,
                        connectedName: connectedName,
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

  Widget _group({
    required String title,
    required Widget flag,
    required List<ServerConfig> servers,
    required ConfigService cfg,
    required String connectedName,
    String? emptyHint,
    bool isCustom = false,
  }) {
    final filtered = servers.where(_matches).toList();
    if (filtered.isEmpty && _query.isNotEmpty) return const SizedBox.shrink();

    final t = context.tokens;
    // A search always expands the groups it matched.
    final open = _query.isNotEmpty || !_collapsed.contains(title);

    return Padding(
      padding: const EdgeInsets.only(bottom: SnapDarkTokens.gapLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() {
              if (_collapsed.contains(title)) {
                _collapsed.remove(title);
              } else {
                _collapsed.add(title);
              }
            }),
            borderRadius: SnapDarkTokens.brSm,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: SnapDarkTokens.gapXs,
                vertical: SnapDarkTokens.gapSm,
              ),
              child: Row(
                children: [
                  flag,
                  const SizedBox(width: SnapDarkTokens.gapSm),
                  Text(title.toUpperCase(), style: t.overline),
                  const SizedBox(width: SnapDarkTokens.gapSm),
                  SnapDarkBadge(label: '${filtered.length}'),
                  const Spacer(),
                  AnimatedRotation(
                    turns: open ? 0 : -0.25,
                    duration: SnapDarkTokens.fast,
                    child: Icon(
                      Icons.expand_more_rounded,
                      color: t.textMuted,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (open) ...[
            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  SnapDarkTokens.gapXs,
                  0,
                  0,
                  SnapDarkTokens.gapSm,
                ),
                child: Text(
                  emptyHint ?? 'No configs in this group',
                  style: TextStyle(color: t.textMuted, fontSize: 12),
                ),
              )
            else
              ...filtered.map((raw) {
                // An official tweak shows its RESOLVED ride (protocol/
                // transport of the server it actually joins at connect) —
                // minus the endpoint, which the tweak must never expose.
                final s = raw.isCustom && cfg.isOfficialTweak(raw)
                    ? cfg.resolveOfficialTweak(raw).copyWith(address: '')
                    : raw;
                return ServerCard(
                  server: s,
                  isSelected: cfg.selectedServer?.id == s.id,
                  isConnected:
                      connectedName.isNotEmpty && connectedName == s.displayName,
                  onTap: () => _select(raw),
                  onMenu: raw.isCustom ? () => _showActions(raw) : null,
                );
              }),
          ],
        ],
      ),
    );
  }
}

/// One collapsible section of the Configs list.
class _Section {
  final String title;
  final Widget flag;
  final List<ServerConfig> servers;
  final bool isCustom;
  final String? emptyHint;

  const _Section({
    required this.title,
    required this.flag,
    required this.servers,
    this.isCustom = false,
    this.emptyHint,
  });
}

/// Actions offered by the per-config kebab sheet.
enum _CardAction { note, share, edit, delete }

/// Branded bottom sheet listing the actions for one config. Locked shares
/// only ever see note + delete (their fields must never leave the device).
class _CardActionSheet extends StatelessWidget {
  final ServerConfig server;
  const _CardActionSheet({required this.server});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final rows = <Widget>[];
    void add(Widget row) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: SnapDarkTokens.gapSm));
      rows.add(row);
    }

    if (server.hasNoteInfo) {
      add(_SheetAction(
        icon: Icons.sticky_note_2_outlined,
        title: 'View note',
        subtitle: 'Sharer message, author & expiry',
        color: t.lime,
        onTap: () => Navigator.pop(context, _CardAction.note),
      ));
    }
    if (!server.locked) {
      add(_SheetAction(
        icon: Icons.ios_share_rounded,
        title: 'Share',
        subtitle: 'Protected share link, .st or .dark file',
        color: t.accent,
        onTap: () => Navigator.pop(context, _CardAction.share),
      ));
      add(_SheetAction(
        icon: Icons.edit_outlined,
        title: 'Edit',
        subtitle: 'Name, endpoint & DPI options',
        color: t.textSecondary,
        onTap: () => Navigator.pop(context, _CardAction.edit),
      ));
    }
    add(_SheetAction(
      icon: Icons.delete_outline_rounded,
      title: 'Delete',
      subtitle: 'Remove from this device',
      color: t.alert,
      onTap: () => Navigator.pop(context, _CardAction.delete),
    ));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: t.accentWashStrong,
                border: Border.all(color: t.accent.withValues(alpha: 0.45)),
              ),
              child: Icon(
                server.locked ? Icons.lock_rounded : Icons.tune_rounded,
                color: server.locked ? t.alert : t.accent,
                size: 21,
              ),
            ),
            const SizedBox(width: SnapDarkTokens.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    server.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.text,
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    server.locked
                        ? 'Locked share — note and delete only'
                        : '${server.protocolLabel} · ${server.transportLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: SnapDarkTokens.gapLg),
        ...rows,
      ],
    );
  }
}

/// One tappable action row inside a SnapDarkModal sheet.
class _SheetAction extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _SheetAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: Colors.transparent,
      borderRadius: SnapDarkTokens.brMd,
      child: InkWell(
        onTap: onTap,
        borderRadius: SnapDarkTokens.brMd,
        child: Container(
          padding: const EdgeInsets.all(SnapDarkTokens.gapMd),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [t.surfaceAltFill, t.accentWash],
            ),
            borderRadius: SnapDarkTokens.brMd,
            border: Border.all(color: t.borderStrong.withValues(alpha: 0.72)),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.13),
                  borderRadius: SnapDarkTokens.brSm,
                  border: Border.all(color: color.withValues(alpha: 0.35)),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: SnapDarkTokens.gapSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.text,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.textMuted,
                        fontSize: 11,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: t.textMuted.withValues(alpha: 0.6),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// BDIX trial status banner shown at the top of the BDIX Servers tab. The trial
/// auto-starts on first registration; when it expires the user contacts the
/// admin (Telegram/WhatsApp) — no key input.
class _BdixTrialBanner extends StatefulWidget {
  const _BdixTrialBanner();

  @override
  State<_BdixTrialBanner> createState() => _BdixTrialBannerState();
}

class _BdixTrialBannerState extends State<_BdixTrialBanner> {
  Map<String, dynamic>? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final trial = DeviceTrial.instance;
    // Free CDN read first; the Worker (register + fresh status) only when
    // the per-device status file is missing or the CDN is unreachable.
    final status =
        await trial.refreshStatus() ?? await trial.register();
    if (mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final cfg = context.read<ConfigService>();
    final status = _status;
    final active = status?['active'] == true;
    final vip = status?['vip'] == true;
    final daysLeft = (status?['daysLeft'] as int?) ?? 0;
    final contact = cfg.providerContact.isNotEmpty
        ? cfg.providerContact
        : 'https://t.me/armantunnel';
    final whatsapp = cfg.providerWhatsapp;

    if (status == null) {
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: SnapDarkTokens.gapMd,
          vertical: SnapDarkTokens.gap,
        ),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.border),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: SnapDarkTokens.gapSm),
            Text(
              'Checking BDIX trial status…',
              style: TextStyle(color: t.textSecondary, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SnapDarkTokens.gapMd,
        vertical: SnapDarkTokens.gap,
      ),
      decoration: BoxDecoration(
        color: active ? t.accent.withValues(alpha: 0.08) : t.alert.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: active ? t.accent.withValues(alpha: 0.3) : t.alert.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            active ? Icons.check_circle_rounded : Icons.warning_rounded,
            color: active ? t.accent : t.alert,
            size: 20,
          ),
          const SizedBox(width: SnapDarkTokens.gapSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  vip
                      ? 'BDIX VIP — permanent access'
                      : active
                          ? 'BDIX Trial Active — $daysLeft day${daysLeft == 1 ? '' : 's'} left'
                          : 'BDIX Trial Expired',
                  style: TextStyle(
                    color: active ? t.accent : t.alert,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!active) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Contact the admin to extend your access.',
                    style: TextStyle(color: t.textSecondary, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          if (!active) ...[
            IconButton(
              tooltip: 'Telegram',
              icon: Icon(Icons.send_rounded, color: t.accent, size: 18),
              onPressed: () => _openContact(context, contact),
            ),
            if (whatsapp.isNotEmpty)
              IconButton(
                tooltip: 'WhatsApp',
                icon: Icon(Icons.chat_rounded, color: t.accent, size: 18),
                onPressed: () => _openContact(
                  context,
                  whatsapp.startsWith('http')
                      ? whatsapp
                      : 'https://wa.me/${whatsapp.replaceAll(RegExp(r'[^0-9]'), '')}',
                ),
              ),
            IconButton(
              tooltip: 'Refresh',
              icon: Icon(Icons.refresh_rounded, color: t.textMuted, size: 18),
              onPressed: _load,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openContact(BuildContext context, String url) async {
    try {
      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) AppToast.success(context, 'Contact link copied');
    } catch (_) {
      if (context.mounted) AppToast.error(context, 'Could not copy');
    }
  }
}
