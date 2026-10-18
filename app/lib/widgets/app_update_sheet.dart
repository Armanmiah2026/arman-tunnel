import 'package:flutter/material.dart';

import '../services/config_service.dart';
import '../utils/user_error.dart';
import '../services/vpn_service.dart';
import '../theme/sensei_theme.dart';
import 'app_toast.dart';
import 'ui/sensei_modal.dart';

/// Update dialog — the ONE updater UI for both shapes.
///
/// Forced (`updateRequiredByCode`): non-dismissible, no "Later" — the app
/// stays blocked until the user installs. Soft (`updateAvailableSoft`):
/// dismissible with "Later" — a courtesy notice, never a blocker.
///
/// Both download through `VpnService.downloadAndInstallApk` (the admin
/// panel's `updateUrl`, delivered inside the encrypted settings bundle).
Future<void> showAppUpdate(
  BuildContext context,
  ConfigService cfg, {
  required bool forced,
}) async {
  final t = context.tokens;
  var downloading = false;
  await SenseiModal.popup<void>(
    context,
    dismissible: !forced,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        icon: Icon(Icons.system_update_rounded, color: t.accent, size: 26),
        title: Text(
          cfg.latestVersion.isNotEmpty
              ? 'Update to v${cfg.latestVersion}'
              : 'Update Required',
          textAlign: TextAlign.center,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              cfg.updateMessage.isNotEmpty
                  ? cfg.updateMessage
                  : (forced
                      ? 'Install the latest Arman Tunnel version to continue.'
                      : 'A newer Arman Tunnel version is available.'),
              textAlign: TextAlign.center,
            ),
            if (downloading) ...[
              const SizedBox(height: 18),
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(
                'Saving APK to Downloads…',
                style: TextStyle(color: t.textSecondary, fontSize: 12),
              ),
            ],
          ],
        ),
        actions: [
          if (!forced)
            TextButton(
              onPressed: downloading ? null : () => Navigator.pop(ctx),
              child: Text('Later', style: TextStyle(color: t.textSecondary)),
            ),
          if (cfg.updateUrl.isNotEmpty)
            FilledButton.icon(
              onPressed: downloading
                  ? null
                  : () async {
                      setDialogState(() => downloading = true);
                      try {
                        await VpnService.downloadAndInstallApk(cfg.updateUrl);
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        if (!ctx.mounted) return;
                        setDialogState(() => downloading = false);
                        AppToast.error(
                          ctx,
                          UserError.withRaw(
                            'Update failed — try again later.',
                            UserError.showRaw ? e : null,
                          ),
                        );
                      }
                    },
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Download'),
            ),
        ],
      ),
    ),
  );
}
