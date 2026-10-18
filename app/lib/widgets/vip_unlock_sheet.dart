import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_config.dart';
import '../services/ad_service.dart';
import '../services/device_trial.dart';
import '../services/settings_provider.dart';
import '../theme/sensei_theme.dart';
import 'app_toast.dart';
import 'ui/sensei_controls.dart';
import 'ui/sensei_modal.dart';

/// VIP rewarded-ad unlock flow.
///
/// A config published with the admin panel's VIP flag is locked behind a
/// rewarded ad: tapping it opens this sheet, the user watches an ad, and the
/// config unlocks for `vipUnlockHours` hours (default 2) — persisted by
/// [SettingsProvider] so it survives app restarts.
///
/// Returns true when the server may proceed (not VIP, or freshly unlocked).
/// Non-VIP configs pass through instantly with no UI.
Future<bool> ensureVipUnlocked(
  BuildContext context,
  ServerConfig server,
) async {
  if (!server.vip) return true;
  final settings = context.read<SettingsProvider>();
  if (settings.vipUnlockExpiry(server.id) != null) return true;
  // Admin-granted VIP DEVICE (panel "Grant VIP") = paid access — never put
  // it behind the rewarded-ad wall. Mint a local ticket quietly so vaulted
  // endpoint resolution and ping pings behave exactly like a watched-ad
  // unlock; failure is harmless (the Worker also trusts the device id).
  if (DeviceTrial.instance.isVipDevice) {
    await settings.unlockVip(server.id, server.vipUnlockDuration);
    if (context.mounted) {
      AppToast.success(context, '${server.displayName} — open for your VIP device');
    }
    return true;
  }
  // Ads are OFF until the Play Store launch (AdConfig.adsEnabled) — the
  // rewarded-ad gate cannot run, so VIP servers stay unlocked. Flip the
  // switch and the gate returns for every VIP config.
  if (!AdConfig.adsEnabled) return true;

  final unlocked = await SenseiModal.sheet<bool>(
    context,
    scrollable: false,
    maxHeightFactor: 0.8,
    builder: (ctx) => _VipUnlockSheet(server: server, onUnlocked: () {
      Navigator.of(ctx).pop(true);
    }),
  );
  if (!context.mounted) return unlocked == true;

  // Sheet said yes → record the unlock; everything else leaves it locked.
  if (unlocked == true) {
    final stored = await settings.unlockVip(server.id, server.vipUnlockDuration);
    if (!context.mounted) return stored;
    if (stored) {
      final hours = server.vipUnlockHours ?? 2;
      AppToast.success(
        context,
        '${server.displayName} unlocked (${hours}h)',
      );
    } else {
      // The ad was watched but the native ticket could not be minted
      // (integrity gate / no crypto) — report it instead of silently
      // leaving the config locked after the user paid for the ad.
      AppToast.error(context, 'Unlock failed — integrity check blocked it');
    }
  }
  return unlocked == true && settings.vipUnlockExpiry(server.id) != null;
}

class _VipUnlockSheet extends StatefulWidget {
  final ServerConfig server;
  final VoidCallback onUnlocked;
  const _VipUnlockSheet({required this.server, required this.onUnlocked});

  @override
  State<_VipUnlockSheet> createState() => _VipUnlockSheetState();
}

class _VipUnlockSheetState extends State<_VipUnlockSheet> {
  bool _busy = false;

  Future<void> _watch() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // Load can be async-fresh; showRewarded returns null when nothing is
      // ready yet, so make sure a unit is preloaded before showing.
      AdService.loadRewarded();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final granted = await AdService.showRewarded();
      if (granted == true) {
        widget.onUnlocked();
        return;
      }
      if (mounted) {
        AppToast.warning(
          context,
          granted == null
              ? 'Ad not ready — try again in a moment'
              : 'Watch the ad to the end to unlock',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hours = widget.server.vipUnlockHours ?? 2;
    final note = (widget.server.vipNote ?? '').trim();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(color: t.accent.withValues(alpha: 0.4)),
                // Soft brand glow behind the crown — the sheet's peak moment
                // is the unlock itself; the ring should already feel premium.
                boxShadow: [
                  BoxShadow(
                    color: t.accent.withValues(alpha: 0.22),
                    blurRadius: 26,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Icon(Icons.workspace_premium_rounded,
                  color: t.lime, size: 32),
            ),
          ),
          const SizedBox(height: SenseiTokens.gapMd),
          Text(
            'VIP Server',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: t.text,
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${widget.server.displayName} is a VIP tunnel.\n'
            'Watch one short reward ad to unlock it for '
            '${hours}h.',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.textMuted, fontSize: 13.5, height: 1.45),
          ),
          const SizedBox(height: SenseiTokens.gapMd),
          // What the unlock actually buys — scannable, not a paragraph.
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              const _Pill(label: 'Instant access'),
              _Pill(label: '$hours h per ad'),
              const _Pill(label: 'Re-watch anytime'),
            ],
          ),
          if (note.isNotEmpty) ...[
            const SizedBox(height: SenseiTokens.gapMd),
            // Admin's VIP note (panel → vipNote).
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.accent.withValues(alpha: 0.18)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded,
                      color: t.accent, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      note,
                      style: TextStyle(
                        color: t.textSecondary,
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: SenseiTokens.gapLg),
          SenseiPrimaryButton(
            label: 'Watch ad to unlock',
            icon: Icons.play_circle_fill_rounded,
            busy: _busy,
            onPressed: _watch,
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: _busy
                ? null
                : () => Navigator.of(context).pop(false),
            child: Text(
              'Not now',
              style: TextStyle(color: t.textMuted, fontSize: 13),
            ),
          ),
          // Paid members should never feel trapped behind the ad wall.
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'Already a VIP member? VIP servers open automatically — '
              'check My Access.',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.textMuted, fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  const _Pill({required this.label});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: t.accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: t.accent.withValues(alpha: 0.22)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: t.textSecondary,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}