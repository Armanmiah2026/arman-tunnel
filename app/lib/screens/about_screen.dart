import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/config_service.dart';
import '../services/obf.dart';
import '../services/vpn_service.dart';
import '../theme/snapdark_theme.dart';
import '../widgets/app_toast.dart';
import '../widgets/app_update_sheet.dart';
import '../widgets/snapdark_logo.dart';
import '../widgets/ui/snapdark_controls.dart';
import 'main_shell.dart';

/// About: brand mark, build facts, engine list, panel-published provider
/// branding and credits.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final cfg = context.watch<ConfigService>();
    // Panel-published branding wins; the built-in contact is the fallback.
    final contact =
        cfg.providerContact.isNotEmpty ? cfg.providerContact : Obf.telegram;
    final whatsapp = cfg.providerWhatsapp;
    final provider = cfg.providerName.isNotEmpty &&
        cfg.providerName != 'SnapDark Tunnel'
        ? cfg.providerName
        : '';
    return Scaffold(
      backgroundColor: t.scaffoldBg,
      appBar: AppBar(title: const Text('About')),
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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  SnapDarkTokens.pageInset,
                  SnapDarkTokens.gapLg,
                  SnapDarkTokens.pageInset,
                  SnapDarkTokens.gapXxl,
                ),
                children: [
                  const Center(
                    child: SnapDarkLogo(size: 112),
                  ),
                  const SizedBox(height: SnapDarkTokens.gapLg),
                  Center(
                    child: Text(
                      'SnapDark Tunnel',
                      style: TextStyle(
                        color: t.text,
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      'v$kAppVersion',
                      style: t.mono(size: 13, color: t.textMuted),
                    ),
                  ),
                  if (provider.isNotEmpty) ...[
                    const SizedBox(height: SnapDarkTokens.gapSm),
                    Center(
                      child: Text(
                        provider,
                        style: TextStyle(
                          color: t.accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                  if (cfg.providerDescription.isNotEmpty) ...[
                    const SizedBox(height: SnapDarkTokens.gapXs),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: SnapDarkTokens.pageInset,
                      ),
                      child: Center(
                        child: Text(
                          cfg.providerDescription,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: t.textMuted,
                            fontSize: 12,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: SnapDarkTokens.gapXl),
                  SnapDarkSection(
                    title: 'Build',
                    icon: Icons.badge_outlined,
                    padding: EdgeInsets.zero,
                    divided: false,
                    children: [
                      const SnapDarkStatRow(
                        label: 'Version',
                        value: kAppVersion,
                        mono: true,
                      ),
                      SnapDarkStatRow(
                        label: 'Version code',
                        value: '${VpnService.installInfo?.versionCode ?? kAppBuildNumber}',
                        mono: true,
                      ),
                      // Soft update notice: a newer build exists (admin-set
                      // latest version), but it is not forced — tapping it
                      // opens the same update dialog in its dismissible
                      // shape. The forced path never reaches here.
                      if (cfg.updateAvailableSoft)
                        SnapDarkStatRow(
                          label: 'Update',
                          value: 'v${cfg.latestVersion} available',
                          valueColor: t.accent,
                        ),
                      const SnapDarkStatRow(
                        label: 'Package',
                        value: 'com.snapdark.tunnel',
                        mono: true,
                        selectable: true,
                      ),
                      SnapDarkStatRow(
                        label: 'ABI',
                        value: VpnService.installInfo?.abiLabel ?? 'arm64-v8a',
                        mono: true,
                        valueColor: VpnService.installInfo?.is64Bit == false
                            ? t.warning
                            : null,
                      ),
                      SnapDarkStatRow(
                        label: 'Developer',
                        value: 'Arman Miah',
                        valueColor: t.accent,
                      ),
                      // Soft update action: opens the dismissible update
                      // dialog (admin panel's updateUrl). Never forced here.
                      if (cfg.updateAvailableSoft)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: FilledButton.icon(
                            onPressed: () =>
                                showAppUpdate(context, cfg, forced: false),
                            icon: const Icon(Icons.download_rounded, size: 18),
                            label: Text(
                              'Update to v${cfg.latestVersion}',
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: SnapDarkTokens.gapLg),
                  const SnapDarkSection(
                    title: 'Engines',
                    icon: Icons.memory_rounded,
                    caption: 'Native cores shipped inside the APK',
                    padding: EdgeInsets.zero,
                    divided: false,
                    children: [
                      SnapDarkStatRow(
                        label: 'Xray-core',
                        value: 'VLESS / VMess / Trojan / SS',
                      ),
                      SnapDarkStatRow(
                        label: 'tun2socks',
                        value: 'TUN ↔ SOCKS bridge',
                      ),
                      SnapDarkStatRow(
                        label: 'Trilead SSH2',
                        value: 'SSH + payload inject',
                      ),
                      SnapDarkStatRow(
                        label: 'DNSTT',
                        value: 'SSH over DNS (SlowDNS)',
                      ),
                      SnapDarkStatRow(
                        label: 'OpenVPN3',
                        value: '.ovpn profiles via JNI',
                      ),
                    ],
                  ),
                  const SizedBox(height: SnapDarkTokens.gapLg),
                  SnapDarkSection(
                    title: 'Contact',
                    icon: Icons.support_agent_rounded,
                    children: [
                      SnapDarkTile(
                        icon: Icons.person_outline_rounded,
                        title: 'App owner',
                        subtitle: '@armantunnel',
                        onTap: () => _open(context, 'https://t.me/armantunnel'),
                      ),
                      SnapDarkTile(
                        icon: Icons.handshake_outlined,
                        title: 'Contributing friend',
                        subtitle: '@ImranKhan_0_0',
                        onTap: () =>
                            _open(context, 'https://t.me/ImranKhan_0_0'),
                      ),
                      if (contact.isNotEmpty)
                        SnapDarkTile(
                          icon: Icons.send_rounded,
                          title: 'Telegram',
                          subtitle: contact,
                          onTap: () => _open(context, contact),
                        ),
                      if (whatsapp.isNotEmpty)
                        SnapDarkTile(
                          icon: Icons.chat_rounded,
                          title: 'WhatsApp',
                          subtitle: whatsapp,
                          onTap: () => _open(
                            context,
                            whatsapp.startsWith('http')
                                ? whatsapp
                                : 'https://wa.me/${whatsapp.replaceAll(RegExp(r'[^0-9]'), '')}',
                          ),
                        ),
                      if (provider.isNotEmpty)
                        SnapDarkTile(
                          icon: Icons.storefront_rounded,
                          title: 'Provider',
                          subtitle: provider,
                        ),
                      SnapDarkTile(
                        icon: Icons.copy_rounded,
                        title: 'Copy contact',
                        subtitle: 'Put the Telegram handle on the clipboard',
                        onTap: () async {
                          await Clipboard.setData(
                            ClipboardData(text: contact),
                          );
                          if (context.mounted) {
                            AppToast.success(context, 'Contact copied');
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: SnapDarkTokens.gapLg),
                  SnapDarkSection(
                    title: 'Legal',
                    icon: Icons.gavel_outlined,
                    children: [
                      SnapDarkTile(
                        icon: Icons.privacy_tip_outlined,
                        title: 'Privacy Policy',
                        subtitle: 'How your data is handled',
                        onTap: () => _open(
                            context, '${Obf.adminUrl}/privacy'),
                      ),
                      SnapDarkTile(
                        icon: Icons.description_outlined,
                        title: 'Terms of Service',
                        subtitle: 'Rules for using SnapDark Tunnel',
                        onTap: () => _open(
                            context, '${Obf.adminUrl}/terms'),
                      ),
                    ],
                  ),
                  const SizedBox(height: SnapDarkTokens.gapXl),
                  Center(
                    child: Text(
                      'Built with care',
                      style: TextStyle(color: t.textMuted, fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) AppToast.warning(context, 'Could not open link');
    }
  }
}
