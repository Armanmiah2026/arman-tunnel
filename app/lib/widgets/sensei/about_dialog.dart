import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/obf.dart';
import '../../theme/sensei_theme.dart';
import '../sensei_logo.dart';
import '../ui/sensei_controls.dart';

/// About dialog. Mirrors the About screen content in a compact form.
class SenseiAboutDialog extends StatelessWidget {
  final String version;
  const SenseiAboutDialog({super.key, required this.version});

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
      borderRadius: BorderRadius.circular(SenseiTokens.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SenseiTokens.gapLg,
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
      insetPadding: const EdgeInsets.all(SenseiTokens.gapLg),
      child: Padding(
        padding: const EdgeInsets.all(SenseiTokens.gapLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SenseiLogo(size: 78),
            const SizedBox(height: SenseiTokens.gap),
            Text(
              'Arman Tunnel',
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
            const SizedBox(height: SenseiTokens.gapLg),
            SenseiCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(SenseiTokens.gap),
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
                  const SenseiStatRow(
                    label: 'Developer',
                    value: 'Arman Miah',
                  ),
                  SenseiStatRow(label: 'Contact', value: Obf.telegram),
                  const SenseiStatRow(
                    label: 'Engines',
                    value: 'Xray • SSH • DNSTT • OpenVPN',
                  ),
                  const SenseiStatRow(
                    label: 'Package',
                    value: 'com.sensei.tunnel',
                    mono: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: SenseiTokens.gap),
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
