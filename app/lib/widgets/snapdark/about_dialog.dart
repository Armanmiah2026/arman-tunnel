import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/obf.dart';
import '../../theme/snapdark_theme.dart';
import '../snapdark_logo.dart';
import '../ui/snapdark_controls.dart';

/// About dialog. Mirrors the About screen content in a compact form.
class SnapDarkAboutDialog extends StatelessWidget {
  final String version;
  const SnapDarkAboutDialog({super.key, required this.version});

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      // Surface nothing — a failed deep-link is harmless in a dialog.
    }
  }

  /// Contact row showing only the username — the whole row opens t.me.
  Widget _linkRow(
    BuildContext context,
    String label,
    String username,
    String url,
  ) {
    final t = context.tokens;
    return InkWell(
      onTap: () => _open(context, url),
      borderRadius: BorderRadius.circular(SnapDarkTokens.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SnapDarkTokens.gapLg,
          vertical: 9,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(color: t.textMuted, fontSize: 12.5),
            ),
            const SizedBox(width: 6),
            Text(
              username,
              style: TextStyle(
                color: t.accent,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Dialog(
      insetPadding: const EdgeInsets.all(SnapDarkTokens.gapLg),
      child: Padding(
        padding: const EdgeInsets.all(SnapDarkTokens.gapLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SnapDarkLogo(size: 78),
            const SizedBox(height: SnapDarkTokens.gap),
            Text(
              'SnapDark Tunnel',
              style: TextStyle(
                color: t.text,
                fontSize: 21,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              'v$version',
              style: TextStyle(color: t.textMuted, fontSize: 12.5),
            ),
            const SizedBox(height: SnapDarkTokens.gapLg),
            SnapDarkCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(SnapDarkTokens.gap),
                    child: Text(
                      'Native Xray / SSH / DNSTT / OpenVPN engine bridge with an '
                      'encrypted config feed, payload injection and admin controls.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: t.textSecondary,
                        fontSize: 12.5,
                        height: 1.5,
                      ),
                    ),
                  ),
                  Divider(height: 1, color: t.border),
                  _linkRow(
                    context,
                    'App owner',
                    '@armantunnel',
                    'https://t.me/armantunnel',
                  ),
                  Divider(height: 1, color: t.border),
                  _linkRow(
                    context,
                    'Contributing friend',
                    '@ImranKhan_0_0',
                    'https://t.me/ImranKhan_0_0',
                  ),
                  Divider(height: 1, color: t.border),
                  const SnapDarkStatRow(
                    label: 'Developer',
                    value: 'Arman Miah',
                  ),
                  SnapDarkStatRow(label: 'Contact', value: Obf.telegram),
                  const SnapDarkStatRow(
                    label: 'Engines',
                    value: 'Xray • SSH • DNSTT • OpenVPN',
                  ),
                  const SnapDarkStatRow(
                    label: 'Package',
                    value: 'com.snapdark.tunnel',
                    mono: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: SnapDarkTokens.gap),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
