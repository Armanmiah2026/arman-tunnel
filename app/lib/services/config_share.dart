import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_config.dart';
import '../theme/snapdark_theme.dart';
import '../utils/banner_renderer.dart';
import '../utils/user_error.dart';
import '../widgets/app_toast.dart';
import '../widgets/ui/snapdark_controls.dart';
import '../widgets/ui/snapdark_modal.dart';
import 'config_service.dart';
import 'vpn_service.dart';

/// THE Config Share module (v48) — builds opaque `armantunnel://<base64>`
/// shares with selectable security options.
///
/// Share flow: an options sheet with checkboxes —
///   ☐ Lock All       — read-only after import (enforced by the config layer)
///   ☐ HWID           — bound to THIS device (folded into the AES key)
///   ☐ Password       — recipient must enter it (PBKDF2, never stored)
///   ☐ Expired        — unusable after a picked date/time
///   ☐ Block Root     — refuses to import on rooted devices
///   ☐ Block App      — refuses to import when listed packages are installed
///   ☐ HTML Note      — rendered message attached to the share
/// …all optional, any combination. Two transports at the bottom:
///   Save as ".st" File · Share as Text
///
/// Everything security-critical (AES-256-GCM, key derivation, restriction
/// checks) lives in the native ShareEnvelope. This module wraps that native
/// envelope in one clean public URI so recipients never see `/base64/48/lock`.
class ConfigShare {
  const ConfigShare._();

  // ---------------------------------------------------------------------------
  // Share (export)
  // ---------------------------------------------------------------------------

  /// Share ONE config — the security/options sheet with the transports.
  /// [onDone] fires with the produced share text when the user picked a
  /// transport (used by callers that need the text); the transports
  /// themselves (save/share) run here.
  static Future<void> shareOne(BuildContext context, ServerConfig s) async {
    final out = await _collectOptions(context, s);
    if (out == null || !context.mounted) return; // cancelled
    final shareConfig = _safeShareConfig(s);
    final canDark = switch (s.protocol) {
      ProtocolType.vless ||
      ProtocolType.vmess ||
      ProtocolType.ssh ||
      ProtocolType.sshDnstt =>
        shareConfig.rawConfig != 'official:tweak',
      _ => false,
    };
    final choice = await SnapDarkModal.sheet<String>(
      context,
      builder: (ctx) => _ShareTargetSheet(
        title: 'Share ${s.displayName}',
        subtitle: 'Choose how this protected config should leave the app.',
        includeDark: canDark,
      ),
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'dark':
        final dark = shareConfig.toDarkTunnelLockedUri(
          password: out.password,
          expiresAtMs: out.expiresAt == 0 ? null : out.expiresAt,
          message: out.note,
        );
        if (dark == null) {
          AppToast.error(context, 'This config cannot be exported as .dark');
          return;
        }
        await saveTextFile(context, dark, out.fileName, ext: 'dark');
        break;
      case 'file':
        final envelope = await _buildEnvelope(context, shareConfig, out);
        if (envelope == null || !context.mounted) return;
        await saveTextFile(context, envelope, out.fileName);
        break;
      case 'text':
        final envelope = await _buildEnvelope(context, shareConfig, out);
        if (envelope == null || !context.mounted) return;
        VpnService.shareText(envelope,
            title: 'SnapDarkTunnel config (${s.displayName})');
        break;
    }
  }

  static ServerConfig _safeShareConfig(ServerConfig s) {
    final officialBacked = s.rawConfig == 'official:tweak' ||
        (s.isCustom &&
            !s.isOfficial &&
            (s.capability ?? '').trim().isNotEmpty &&
            s.serverPool.isNotEmpty);
    return officialBacked ? ConfigService.officialTweakPlaceholder(s) : s;
  }

  /// The options sheet. Returns the picked options or null (cancelled).
  static Future<_ShareOptions?> _collectOptions(
    BuildContext context,
    ServerConfig s,
  ) {
    return SnapDarkModal.popup<_ShareOptions>(
      context,
      builder: (_) => _ShareOptionsDialog(config: s),
    );
  }

  /// Options → native v48 envelope build. Returns null on failure (toast).
  static Future<String?> _buildEnvelope(
    BuildContext context,
    ServerConfig s,
    _ShareOptions out,
  ) async {
    final envelope = await VpnService.shareEnvelopeBuild(
      jsonEncode(s.toJson()),
      {
        'lock': out.lockAll,
        'hwid': out.hwid,
        'password': out.password,
        'expiresAt': out.expiresAt,
        'blockRoot': out.blockRoot,
        'blockApps': out.blockApps,
        'note': out.note,
      },
    );
    if (envelope == null || envelope.isEmpty) {
      if (context.mounted) {
        AppToast.error(context, 'Could not build the share');
      }
      return null;
    }
    return VpnService.wrapShareEnvelope(envelope);
  }

  // ---------------------------------------------------------------------------
  // Primitives
  // ---------------------------------------------------------------------------

  /// SAF "Create document" — writes the share text as a `.st` (or `.dark`)
  /// file.
  static Future<void> saveTextFile(
    BuildContext context,
    String content,
    String fileName, {
    String ext = 'st',
  }) async {
    try {
      final safeName = _safeFileName(fileName);
      final withExt = safeName.endsWith('.$ext') ? safeName : '$safeName.$ext';
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save share (.$ext)',
        fileName: withExt,
        type: FileType.any,
        bytes: utf8.encode(content),
      );
      if (!context.mounted) return;
      if (path == null) return; // user cancelled
      try {
        File(path).writeAsStringSync(content, flush: true);
      } catch (_) {/* content:// URI — plugin already wrote the bytes */}
      AppToast.success(context, 'Saved $withExt');
    } catch (e) {
      if (context.mounted) {
        AppToast.error(
          context,
          UserError.withRaw(
              'Could not save the file.', UserError.showRaw ? e : null),
        );
      }
    }
  }

  static String _safeFileName(String raw) => raw
      .replaceAll(RegExp(r'[/\\<>:"|?*]'), '-')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');

  /// Export ALL custom configs — one `.st` file of opaque v48 OPEN shares (one
  /// `armantunnel://<base64>` line each, importable line-by-line;
  /// per-config security is applied per share, not to the whole file).
  /// Used by the Configs overflow menu and the drawer.
  static Future<void> exportAll(BuildContext context) async {
    final cfg = context.read<ConfigService>();
    final customs = cfg.customServers.where((s) => !s.locked).toList();
    final hidden = cfg.customServers.length - customs.length;
    if (customs.isEmpty) {
      AppToast.error(
        context,
        hidden > 0
              ? 'All $hidden config(s) are locked — share each one from its card.'
            : 'No custom configs to export.',
      );
      return;
    }
    final lines = <String>[];
    for (final c in customs) {
      final env =
          await VpnService.shareEnvelopeBuild(jsonEncode(c.toJson()), const {});
      if (env != null && env.isNotEmpty) {
        lines.add(VpnService.wrapShareEnvelope(env));
      }
    }
    if (lines.isEmpty) {
      if (context.mounted) {
        AppToast.error(context, 'Could not build the export');
      }
      return;
    }
    if (!context.mounted) return;
    final choice = await SnapDarkModal.sheet<String>(
      context,
      builder: (ctx) => _ShareTargetSheet(
        title: 'Export ${customs.length} config(s)',
        subtitle: hidden > 0
            ? '$hidden locked config(s) skipped to avoid leaking protected fields.'
            : 'Exports one importable .st bundle with your custom configs.',
      ),
    );
    if (choice == null || !context.mounted) return;
    final text = lines.join('\n');
    switch (choice) {
      case 'file':
        final n = customs.length;
        final name = n == 1
            ? '${_safeFileName(customs.first.displayName)}.st'
            : 'snapdarktunnel-configs-${DateTime.now().millisecondsSinceEpoch}.st';
        await saveTextFile(context, text, name);
        break;
      case 'text':
        VpnService.shareText(text, title: 'SnapDarkTunnel configs (.st)');
        break;
    }
  }
}

/// Collected share options.
class _ShareOptions {
  final bool lockAll;
  final bool hwid;
  final String password;
  final int expiresAt; // epoch ms, 0 = off
  final bool blockRoot;
  final List<String> blockApps;
  final String note;
  final String fileName;

  const _ShareOptions({
    this.lockAll = false,
    this.hwid = false,
    this.password = '',
    this.expiresAt = 0,
    this.blockRoot = false,
    this.blockApps = const [],
    this.note = '',
    this.fileName = '',
  });
}

/// The share options dialog — every option is a checkbox, all optional.
class _ShareOptionsDialog extends StatefulWidget {
  final ServerConfig config;
  const _ShareOptionsDialog({required this.config});

  @override
  State<_ShareOptionsDialog> createState() => _ShareOptionsDialogState();
}

class _ShareOptionsDialogState extends State<_ShareOptionsDialog> {
  bool _lockAll = false;
  bool _hwid = false;
  bool _usePassword = false;
  bool _useExpiry = false;
  bool _blockRoot = false;
  bool _blockApps = false;
  bool _useNote = false;

  final _passwordCtrl = TextEditingController();
  final _appsCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _fileNameCtrl = TextEditingController();
  DateTime _expiry = DateTime.now().add(const Duration(days: 30));

  /// Any protection option (besides Lock All itself) that makes the share a
  /// locked envelope. When any is on, Lock All auto-enables — a protected
  /// share must not be editable after import.
  bool get _anyRestrictive =>
      _hwid || _usePassword || _useExpiry || _blockRoot || _blockApps || _useNote;

  /// What the Lock All checkbox should show: the user's own choice OR the
  /// auto-enable from any restrictive option.
  bool get _effectiveLockAll => _lockAll || _anyRestrictive;

  @override
  void initState() {
    super.initState();
    _fileNameCtrl.text = ConfigShare._safeFileName(widget.config.displayName);
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _appsCtrl.dispose();
    _noteCtrl.dispose();
    _fileNameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.pop(
      context,
      _ShareOptions(
        lockAll: _effectiveLockAll,
        hwid: _hwid,
        password: _usePassword ? _passwordCtrl.text : '',
        expiresAt: _useExpiry ? _expiry.millisecondsSinceEpoch : 0,
        blockRoot: _blockRoot,
        blockApps: _blockApps
            ? _appsCtrl.text
                .split(RegExp(r'[\s,]+'))
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList()
            : const [],
        note: _useNote ? _noteCtrl.text : '',
        fileName: ConfigShare._safeFileName(_fileNameCtrl.text.trim()).isEmpty
            ? ConfigShare._safeFileName(widget.config.displayName)
            : ConfigShare._safeFileName(_fileNameCtrl.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AlertDialog(
      title: Text('Share "${widget.config.displayName}"',
          textAlign: TextAlign.center),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'All options are optional — pick any combination.',
                style: TextStyle(color: t.textMuted, fontSize: 12),
              ),
              const SizedBox(height: SnapDarkTokens.gapMd),
              SnapDarkField(
                label: 'File name (without extension)',
                controller: _fileNameCtrl,
                hint: 'My config',
              ),
              const SizedBox(height: SnapDarkTokens.gapSm),
              _check(
                  'Lock All',
                  _anyRestrictive
                      ? 'Auto-enabled: a protection option makes it read-only'
                      : 'Read-only after import — fields cannot be edited',
                  _effectiveLockAll,
                  (v) => setState(() {
                        // Can't drop Lock All while another protection option
                        // still needs it (locked envelope guarantees it).
                        if (_anyRestrictive) return;
                        _lockAll = v;
                      })),
              _check(
                  'HWID',
                  'Bound to this device only — other devices cannot open it',
                  _hwid,
                  (v) => setState(() {
                    _hwid = v;
                    if (v) _lockAll = true;
                  })),
              _check('Password', 'Recipient must enter it to import',
                  _usePassword, (v) => setState(() {
                    _usePassword = v;
                    if (v) _lockAll = true;
                  })),
              if (_usePassword)
                Padding(
                  padding: const EdgeInsets.only(
                      left: SnapDarkTokens.gapXl, top: SnapDarkTokens.gapXs),
                  child: SnapDarkField(
                    label: 'Password',
                    controller: _passwordCtrl,
                    obscure: true,
                    hint: 'share password',
                  ),
                ),
              _check('Expired', 'Unusable after the picked date', _useExpiry,
                  (v) => setState(() {
                    _useExpiry = v;
                    if (v) _lockAll = true;
                  })),
              if (_useExpiry)
                Padding(
                  padding: const EdgeInsets.only(
                      left: SnapDarkTokens.gapXl, top: SnapDarkTokens.gapSm),
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          final d = await showDatePicker(
                            context: context,
                            initialDate: _expiry,
                            firstDate: DateTime.now(),
                            lastDate:
                                DateTime.now().add(const Duration(days: 3650)),
                          );
                          if (d != null) setState(() => _expiry = d);
                        },
                        icon: Icon(Icons.calendar_month_rounded,
                            size: 18, color: t.accent),
                        label: Text(
                          '${_expiry.year}-${_expiry.month.toString().padLeft(2, '0')}-${_expiry.day.toString().padLeft(2, '0')}',
                          style: t.mono(size: 12.5, color: t.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
              _check('Block Root', 'Refuses to import on rooted devices',
                  _blockRoot, (v) => setState(() {
                    _blockRoot = v;
                    if (v) _lockAll = true;
                  })),
              _check(
                  'Block Application',
                  'Refuses to import when listed packages are installed',
                  _blockApps,
                  (v) => setState(() {
                    _blockApps = v;
                    if (v) _lockAll = true;
                  })),
              if (_blockApps)
                Padding(
                  padding: const EdgeInsets.only(
                      left: SnapDarkTokens.gapXl, top: SnapDarkTokens.gapXs),
                  child: SnapDarkField(
                    label: 'Package names (one per line)',
                    controller: _appsCtrl,
                    maxLines: 3,
                    mono: true,
                    hint: 'com.example.app',
                  ),
                ),
              _check('HTML Note', 'A rendered message travels with the share',
                  _useNote, (v) => setState(() {
                    _useNote = v;
                    if (v) _lockAll = true;
                  })),
              if (_useNote)
                Padding(
                  padding: const EdgeInsets.only(
                      left: SnapDarkTokens.gapXl, top: SnapDarkTokens.gapXs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SnapDarkField(
                        label: 'Note (HTML supported)',
                        controller: _noteCtrl,
                        maxLines: 4,
                        hint:
                            '<b>bold</b>, <font color="#C084FC">colour</font>…',
                      ),
                      // Live rendered preview of the note as the receiver
                      // will see it (brand-clamped HTML walker).
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _noteCtrl,
                        builder: (ctx, v, _) {
                          final txt = v.text.trim();
                          if (txt.isEmpty) return const SizedBox.shrink();
                          return Container(
                            width: double.infinity,
                            margin:
                                const EdgeInsets.only(top: SnapDarkTokens.gapXs),
                            padding: const EdgeInsets.all(SnapDarkTokens.gapMd),
                            decoration: BoxDecoration(
                              color: t.surfaceAltFill,
                              borderRadius: SnapDarkTokens.brMd,
                              border: Border.all(color: t.border),
                            ),
                            child: buildShareNotePreview(context, txt),
                          );
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Continue'),
        ),
      ],
    );
  }

  Widget _check(
      String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    final t = context.tokens;
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: SnapDarkTokens.brSm,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                  value: value, onChanged: (v) => onChanged(v ?? false)),
            ),
            const SizedBox(width: SnapDarkTokens.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: t.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(color: t.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareTargetSheet extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool includeDark;

  const _ShareTargetSheet({
    required this.title,
    required this.subtitle,
    this.includeDark = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    Widget box(
      IconData icon,
      String label,
      String subtitle,
      String id,
    ) =>
        _ShareBox(
          icon: icon,
          label: label,
          subtitle: subtitle,
          onTap: () => Navigator.pop(context, id),
        );

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
              child: Icon(Icons.ios_share_rounded, color: t.accent, size: 21),
            ),
            const SizedBox(width: SnapDarkTokens.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
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
                    subtitle,
                    style: TextStyle(
                      color: t.textMuted,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: SnapDarkTokens.gapLg),
        Row(
          children: [
            Expanded(
              child: box(
                Icons.save_alt_rounded,
                'Save File',
                'Create an importable .st file',
                'file',
              ),
            ),
            const SizedBox(width: SnapDarkTokens.gapMd),
            Expanded(
              child: box(
                Icons.text_snippet_rounded,
                'Share Text',
                'Send through chat or notes',
                'text',
              ),
            ),
          ],
        ),
        if (includeDark) ...[
          const SizedBox(height: SnapDarkTokens.gapMd),
          box(
            Icons.lock_rounded,
            'Save DarkTunnel File',
            'Export compatible locked .dark format',
            'dark',
          ),
        ],
      ],
    );
  }
}

/// A selectable option box for the transports.
class _ShareBox extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  const _ShareBox({
    required this.icon,
    required this.label,
    required this.subtitle,
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
                  color: t.bg.withValues(alpha: 0.35),
                  borderRadius: SnapDarkTokens.brSm,
                  border: Border.all(color: t.accent.withValues(alpha: 0.28)),
                ),
                child: Icon(icon, color: t.accent, size: 20),
              ),
              const SizedBox(width: SnapDarkTokens.gapSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.textMuted,
                        fontSize: 10.5,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders a share's HTML note (sanitized through the brand-clamped HTML
/// walker the app uses everywhere).
Widget buildShareNotePreview(BuildContext context, String html) {
  final t = context.tokens;
  return RichText(
    text: TextSpan(
      children: buildHtmlSpans(
        context,
        html,
        TextStyle(color: t.text, fontSize: 13.5, height: 1.45),
      ),
    ),
  );
}
