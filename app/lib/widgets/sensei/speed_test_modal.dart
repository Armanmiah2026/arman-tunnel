import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/vpn_service.dart';
import '../../theme/sensei_theme.dart';
import '../app_toast.dart';

/// Speed test as a small popup WebView over fast.com (Netflix's tester).
///
/// The custom gauge was replaced on purpose: fast.com is a battle-tested,
/// trusted measurement, and with the tunnel up the WebView's traffic rides
/// it — so the number is the real tunneled throughput with zero custom math
/// to get wrong.
///
/// WebView init is NOT trusted: on some Android builds (16+ in the field)
/// the platform view fails to come up and the sheet used to die with it.
/// Any init/main-frame failure flips to a fallback panel with an
/// open-in-browser button, so the sheet always opens and the test is always
/// reachable.
class SenseiSpeedTestSheet extends StatefulWidget {
  const SenseiSpeedTestSheet({super.key});

  @override
  State<SenseiSpeedTestSheet> createState() => _SenseiSpeedTestSheetState();
}

class _SenseiSpeedTestSheetState extends State<SenseiSpeedTestSheet> {
  static const _url = 'https://fast.com';

  WebViewController? _controller;
  double _progress = 0; // 0..1
  String _title = 'fast.com';
  String? _failReason;

  @override
  void initState() {
    super.initState();
    // fast.com must measure the TUNNEL. The app's own traffic stays on the
    // physical network by design, so bind the process to the VPN network for
    // exactly this sheet's lifetime and hand it back in [dispose].
    unawaited(VpnService.setSelfThroughVpn(true));
    _boot();
  }

  @override
  void dispose() {
    // Never leave the app riding a tunnel it no longer wants to.
    unawaited(VpnService.setSelfThroughVpn(false));
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(context.tokens.bg)
        ..setNavigationDelegate(NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p / 100);
          },
          onPageFinished: (_) async {
            final title = await _controller?.getTitle();
            if (mounted && title != null && title.isNotEmpty) {
              setState(() => _title = title);
            }
          },
          onWebResourceError: (e) {
            if (!mounted) return;
            // Only the MAIN FRAME failing means the page is unreachable —
            // sub-resources (ads, trackers) fail all the time and must not
            // trip the fallback.
            if (e.isForMainFrame == true) {
              setState(() => _failReason =
                  'The embedded browser could not load fast.com');
            } else if (e.errorType == WebResourceErrorType.hostLookup) {
              AppToast.error(context, 'No internet through the tunnel');
            }
          },
        ));
      // Mount the WebView FIRST, then load. `loadRequest`'s future only
      // completes when the main frame is DONE — awaiting it before showing
      // the widget made the sheet sit on "Loading fast.com…" while the whole
      // test ran invisibly, and the user never saw a measurement.
      if (mounted) setState(() => _controller = controller);
      await controller.loadRequest(Uri.parse(_url));
    } catch (e) {
      // Controller creation / load threw (WebView provider broken or
      // blocked on this OS build) — fall back to the browser button.
      if (mounted) {
        setState(() => _failReason = 'The embedded browser failed to start');
      }
    }
  }

  Future<void> _openInBrowser() async {
    final uri = Uri.parse(_url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) AppToast.error(context, 'No browser available');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final h = MediaQuery.sizeOf(context).height;
    final controller = _controller;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Icon brightness follows the ACTIVE theme (the sheet header is
      // themed) — hardcoding .light left dark icons on the dark theme.
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            t.isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: t.glass ? Colors.transparent : t.surface,
        // Without this Android's enforced scrim greys over the transparent
        // bar on 3-button nav (same reason as the app root).
        systemNavigationBarContrastEnforced: t.glass ? false : null,
        systemNavigationBarIconBrightness:
            t.isDark ? Brightness.light : Brightness.dark,
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(24),
        ),
        child: Container(
          height: h * 0.82,
          // Transparent in glass mode so the wallpaper keeps showing behind
          // the sheet chrome (the WebView itself is unavoidably opaque).
          color: t.scaffoldBg,
          child: Column(
            children: [
              // Grab handle
              Container(
                margin: const EdgeInsets.only(top: 10),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: t.border,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  children: [
                    Icon(Icons.speed_rounded, color: t.accent, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Internet Speed Test',
                            style: TextStyle(
                              color: t.text,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'measured through your tunnel · $_title',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(color: t.textMuted, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Open in browser',
                      onPressed: () => _openInBrowser(),
                      icon: Icon(Icons.open_in_new_rounded,
                          size: 20, color: t.textSecondary),
                    ),
                    if (controller != null)
                      IconButton(
                        tooltip: 'Reload',
                        onPressed: () => controller
                            .loadRequest(Uri.parse(_url))
                            .catchError((_) {}),
                        icon: Icon(Icons.refresh_rounded,
                            size: 20, color: t.textSecondary),
                      ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close_rounded,
                          size: 20, color: t.textSecondary),
                    ),
                  ],
                ),
              ),
              // Loading progress line.
              if (controller != null && _progress > 0 && _progress < 1)
                LinearProgressIndicator(
                  value: _progress,
                  minHeight: 2,
                  backgroundColor: t.border,
                  valueColor: AlwaysStoppedAnimation(t.accent),
                ),
              Divider(height: 1, color: t.border),
              Expanded(
                child: _failReason != null || controller == null
                    ? _FallbackPanel(
                        reason: _failReason,
                        onRetry: () {
                          setState(() {
                            _failReason = null;
                            _controller = null;
                          });
                          _boot();
                        },
                        onOpenBrowser: _openInBrowser,
                      )
                    : WebViewWidget(controller: controller),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown while the WebView is booting, or instead of it when the embedded
/// browser is broken/blocked on this device: retry + guaranteed
/// open-in-browser path.
class _FallbackPanel extends StatelessWidget {
  final String? reason;
  final VoidCallback onRetry;
  final VoidCallback onOpenBrowser;

  const _FallbackPanel({
    required this.reason,
    required this.onRetry,
    required this.onOpenBrowser,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final failed = reason != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SenseiTokens.gapXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              failed ? Icons.broken_image_outlined : Icons.hourglass_top_rounded,
              size: 40,
              color: failed ? t.alert : t.textMuted,
            ),
            const SizedBox(height: SenseiTokens.gap),
            Text(
              failed ? reason! : 'Loading fast.com…',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: failed ? t.alert : t.textMuted,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: SenseiTokens.gapLg),
            if (failed) ...[
              ElevatedButton.icon(
                onPressed: onOpenBrowser,
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Open fast.com in browser'),
              ),
              const SizedBox(height: SenseiTokens.gapSm),
            ],
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
