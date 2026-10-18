import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/config_service.dart';
import '../services/obf.dart';
import '../services/vpn_service.dart';
import '../theme/sensei_theme.dart';
import '../widgets/app_toast.dart';
import '../widgets/app_update_sheet.dart';
import '../widgets/sensei_logo.dart';
import '../widgets/ui/sensei_controls.dart';
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
        cfg.providerName != 'Arman Tunnel'
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
                maxWidth: SenseiTokens.maxContentWidth,
              ),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  SenseiTokens.pageInset,
                  SenseiTokens.gapLg,
                  SenseiTokens.pageInset,
                  SenseiTokens.gapXxl,
                ),
                children: [
                  const Center(
                    child: SenseiLogo(size: 112),
                  ),
                  const SizedBox(height: SenseiTokens.gapLg),
                  Center(
                    child: Text(
                      'Arman Tunnel',
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
                    const SizedBox(height: SenseiTokens.gapSm),
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
                    const SizedBox(height: SenseiTokens.gapXs),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: SenseiTokens.pageInset,
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
                  const SizedBox(height: SenseiTokens.gapXl),
                  SenseiSection(
                    title: 'Build',
                    icon: Icons.badge_outlined,
                    padding: EdgeInsets.zero,
                    divided: false,
                    children: [
                      const SenseiStatRow(
                        label: 'Version',
                        value: kAppVersion,
                        mono: true,
                      ),
                      SenseiStatRow(
                        label: 'Version code',
                        value: '${VpnService.installInfo?.versionCode ?? kAppBuildNumber}',
                        mono: true,
                      ),
                      // Soft update notice: a newer build exists (admin-set
                      // latest version), but it is not forced — tapping it
                      // opens the same update dialog in its dismissible
                      // shape. The forced path never reaches here.
                      if (cfg.updateAvailableSoft)
                        SenseiStatRow(
                          label: 'Update',
                          value: 'v${cfg.latestVersion} available',
                          valueColor: t.accent,
                        ),
                      const SenseiStatRow(
                        label: 'Package',
                        value: 'com.sensei.tunnel',
                        mono: true,
                        selectable: true,
                      ),
                      SenseiStatRow(
                        label: 'ABI',
                        value: VpnService.installInfo?.abiLabel ?? 'arm64-v8a',
                        mono: true,
                        valueColor: VpnService.installInfo?.is64Bit == false
                            ? t.warning
                            : null,
                      ),
                      SenseiStatRow(
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
                  const SizedBox(height: SenseiTokens.gapLg),
                  const SenseiSection(
                    title: 'Engines',
                    icon: Icons.memory_rounded,
                    caption: 'Native cores shipped inside the APK',
                    padding: EdgeInsets.zero,
                    divided: false,
                    children: [
                      SenseiStatRow(
                        label: 'Xray-core',
                        value: 'VLESS / VMess / Trojan / SS',
                      ),
                      SenseiStatRow(
                        label: 'tun2socks',
                        value: 'TUN ↔ SOCKS bridge',
                      ),
                      SenseiStatRow(
                        label: 'Trilead SSH2',
                        value: 'SSH + payload inject',
                      ),
                      SenseiStatRow(
                        label: 'DNSTT',
                        value: 'SSH over DNS (SlowDNS)',
                      ),
                      SenseiStatRow(
                        label: 'OpenVPN3',
                        value: '.ovpn profiles via JNI',
                      ),
                    ],
                  ),
                  const SizedBox(height: SenseiTokens.gapLg),
                  SenseiSection(
                    title: 'Contact',
                    icon: Icons.support_agent_rounded,
                    children: [
                      SenseiTile(
                        icon: Icons.person_outline_rounded,
                        title: 'App owner',
                        subtitle: '@armantunnel',
                        onTap: () => _open(context, 'https://t.me/armantunnel'),
                      ),
                      SenseiTile(
                        icon: Icons.handshake_outlined,
                        title: 'Contributing friend',
                        subtitle: '@ImranKhan_0_0',
                        onTap: () =>
                            _open(context, 'https://t.me/ImranKhan_0_0'),
                      ),
                      if (contact.isNotEmpty)
                        SenseiTile(
                          icon: Icons.send_rounded,
                          title: 'Telegram',
                          subtitle: contact,
                          onTap: () => _open(context, contact),
                        ),
                      if (whatsapp.isNotEmpty)
                        SenseiTile(
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
                        SenseiTile(
                          icon: Icons.storefront_rounded,
                          title: 'Provider',
                          subtitle: provider,
                        ),
                      SenseiTile(
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
                  const SizedBox(height: SenseiTokens.gapLg),
                  SenseiSection(
                    title: 'Legal',
                    icon: Icons.gavel_outlined,
                    children: [
                      SenseiTile(
                        icon: Icons.privacy_tip_outlined,
                        title: 'Privacy Policy',
                        subtitle: 'How your data is handled',
                        onTap: () => _open(
                            context, '${Obf.adminUrl}/privacy'),
                      ),
                      SenseiTile(
                        icon: Icons.description_outlined,
                        title: 'Terms of Service',
                        subtitle: 'Rules for using Arman Tunnel',
                        onTap: () => _open(
                            context, '${Obf.adminUrl}/terms'),
                      ),
                    ],
                  ),
                  const SizedBox(height: SenseiTokens.gapXl),
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
