import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/config_service.dart';
import '../services/device_trial.dart';
import '../theme/sensei_theme.dart';
import '../widgets/app_toast.dart';
import '../widgets/ui/sensei_controls.dart';

/// My Access — the user's BDIX trial status, device id, and license keys.
///
/// The trial auto-starts on first registration (1 day). When it expires the
/// user contacts the admin (Telegram/WhatsApp) — no key input; the admin
/// extends the device from the panel. Keys redeemed on this device are shown
/// here AND in the admin panel.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  Map<String, dynamic>? _status;
  List<String> _keys = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final trial = DeviceTrial.instance;
    // Worker → GitHub → app: the CDN read first; register (the only Worker
    // call allowed here) only when the id is not on the git repo yet.
    final status =
        await trial.refreshStatus() ?? await trial.register();
    final keys = List<String>.from(
      (status?['redeemedKeys'] as List?)?.cast<String>() ?? const [],
    );
    if (mounted) {
      setState(() {
        _status = status;
        _keys = keys;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final cfg = context.watch<ConfigService>();
    final status = _status;
    final active = status?['active'] == true;
    final vip = status?['vip'] == true;
    final daysLeft = (status?['daysLeft'] as int?) ?? 0;
    final deviceId = DeviceTrial.instance.deviceId ?? '—';
    final contact = cfg.providerContact.isNotEmpty
        ? cfg.providerContact
        : 'https://t.me/armantunnel';
    final whatsapp = cfg.providerWhatsapp;

    return Scaffold(
      backgroundColor: t.scaffoldBg,
      appBar: AppBar(title: const Text('My Access')),
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
                maxWidth: SenseiTokens.maxContentWidth,
              ),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  SenseiTokens.pageInset,
                  SenseiTokens.gapSm,
                  SenseiTokens.pageInset,
                  SenseiTokens.gapXxl,
                ),
                children: [
                  SenseiSection(
                    title: 'BDIX Trial',
                    icon: Icons.workspace_premium_rounded,
                    divided: false,
                    children: [
                      if (_loading)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(SenseiTokens.gapLg),
                            child: CircularProgressIndicator(),
                          ),
                        )
                      else ...[
                        Row(
                          children: [
                            Icon(
                              vip
                                  ? Icons.workspace_premium_rounded
                                  : active
                                      ? Icons.check_circle_rounded
                                      : Icons.warning_rounded,
                              color: vip
                                  ? t.lime
                                  : active
                                      ? t.accent
                                      : t.alert,
                              size: vip ? 24 : 22,
                            ),
                            const SizedBox(width: SenseiTokens.gapSm),
                            Expanded(
                              child: Text(
                                vip
                                    ? 'VIP — permanent access'
                                    : active
                                        ? 'Active — $daysLeft day${daysLeft == 1 ? '' : 's'} left'
                                        : 'Expired',
                                style: TextStyle(
                                  color: active ? t.accent : t.alert,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Refresh',
                              icon: Icon(
                                Icons.refresh_rounded,
                                color: t.textMuted,
                                size: 20,
                              ),
                              onPressed: () {
                                setState(() => _loading = true);
                                _load();
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: SenseiTokens.gapSm),
                        Text(
                          vip
                              ? 'You have permanent VIP access. The admin granted this after your trial.'
                              : active
                                  ? 'Your BDIX trial is running. It started automatically when you first opened the app.'
                                  : 'Your 1-day trial has ended. Contact the admin to get VIP access — no key needed.',
                          style: TextStyle(
                            color: t.textSecondary,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                        if (vip) ...[
                          const SizedBox(height: SenseiTokens.gapMd),
                          const _VipPerkRow(
                              label: 'VIP servers open instantly — no ads'),
                          const _VipPerkRow(
                              label: 'Premium server pool, always included'),
                        ],
                        if (!active) ...[
                          const SizedBox(height: SenseiTokens.gapMd),
                          SenseiPrimaryButton(
                            label: 'Contact admin (Telegram)',
                            icon: Icons.send_rounded,
                            onPressed: () => _openContact(context, contact),
                          ),
                          if (whatsapp.isNotEmpty) ...[
                            const SizedBox(height: SenseiTokens.gapSm),
                            SenseiPrimaryButton(
                              label: 'Contact admin (WhatsApp)',
                              icon: Icons.chat_rounded,
                              onPressed: () => _openContact(
                                context,
                                whatsapp.startsWith('http')
                                    ? whatsapp
                                    : 'https://wa.me/${whatsapp.replaceAll(RegExp(r'[^0-9]'), '')}',
                              ),
                            ),
                          ],
                        ],
                      ],
                    ],
                  ),
                  const SizedBox(height: SenseiTokens.gapLg),
                  SenseiSection(
                    title: 'Device',
                    icon: Icons.smartphone_rounded,
                    divided: false,
                    children: [
                      _Row(
                        label: 'Device ID',
                        value: deviceId,
                        mono: true,
                        onCopy: () async {
                          await Clipboard.setData(ClipboardData(text: deviceId));
                          if (context.mounted) {
                            AppToast.success(context, 'Device ID copied');
                          }
                        },
                      ),
                      if ((_status?['deviceKey'] ?? '').toString().isNotEmpty) ...[
                        const SizedBox(height: SenseiTokens.gapSm),
                        _Row(
                          label: 'Device Key',
                          value: _status!['deviceKey'].toString(),
                          mono: true,
                          onCopy: () async {
                            await Clipboard.setData(
                              ClipboardData(text: _status!['deviceKey'].toString()),
                            );
                            if (context.mounted) {
                              AppToast.success(context, 'Device Key copied');
                            }
                          },
                        ),
                      ],
                      const SizedBox(height: SenseiTokens.gapSm),
                      Text(
                        'Tap the copy icon to send your Device ID to the admin. It is generated from your hardware and survives app delete + reinstall — a reinstall cannot farm a fresh trial.',
                        style: TextStyle(
                          color: t.textMuted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: SenseiTokens.gapLg),
                  SenseiSection(
                    title: 'License Keys',
                    icon: Icons.key_rounded,
                    divided: false,
                    children: [
                      if (_keys.isEmpty)
                        Text(
                          'No keys on this device yet. Keys are issued by the admin and shown here automatically.',
                          style: TextStyle(
                            color: t.textMuted,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        )
                      else
                        ..._keys.map(
                          (k) => Padding(
                            padding: const EdgeInsets.only(bottom: SenseiTokens.gapSm),
                            child: Row(
                              children: [
                                Icon(Icons.vpn_key_rounded, color: t.accent, size: 18),
                                const SizedBox(width: SenseiTokens.gapSm),
                                Expanded(
                                  child: Text(
                                    k,
                                    style: TextStyle(
                                      color: t.text,
                                      fontSize: 13,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Copy',
                                  icon: Icon(
                                    Icons.copy_rounded,
                                    color: t.textMuted,
                                    size: 18,
                                  ),
                                  onPressed: () async {
                                    await Clipboard.setData(ClipboardData(text: k));
                                    if (context.mounted) {
                                      AppToast.success(context, 'Key copied');
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
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

class _VipPerkRow extends StatelessWidget {
  final String label;
  const _VipPerkRow({required this.label});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: SenseiTokens.gapXs),
      child: Row(
        children: [
          Icon(Icons.verified_rounded, color: t.accent, size: 16),
          const SizedBox(width: SenseiTokens.gapSm),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: t.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  final VoidCallback? onCopy;
  const _Row({
    required this.label,
    required this.value,
    this.mono = false,
    this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      children: [
        SizedBox(
          width: 90,
          child: Text(
            label,
            style: TextStyle(color: t.textMuted, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: t.text,
              fontSize: 13,
              fontFamily: mono ? 'monospace' : null,
            ),
          ),
        ),
        if (onCopy != null)
          IconButton(
            tooltip: 'Copy',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.copy_rounded, color: t.textMuted, size: 18),
            onPressed: onCopy,
          ),
      ],
    );
  }
}
