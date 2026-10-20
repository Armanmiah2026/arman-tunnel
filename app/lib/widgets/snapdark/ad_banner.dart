import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:provider/provider.dart';

import '../../services/ad_service.dart';
import '../../services/log_service.dart';
import '../../theme/snapdark_theme.dart';

/// In-flow AdMob banner for the top of the home content area (directly below
/// the status/header block).
///
/// Layout contract:
///  - reserves EXACTLY the ad's own fixed height (anchored adaptive = content
///    width × ~50–57dp) and nothing more — never an overlay, never a push;
///  - 0 height before the first load / after a failure → no empty gap and no
///    oversized screen;
///  - the ad is requested at its REAL layout-slot width (LayoutBuilder), so
///    it can never be wider than its slot (no horizontal crop), and a width
///    change (rotation/fold) re-requests at the new width while keeping the
///    previous height reserved so the column does not jump.
class SnapDarkAdBanner extends StatefulWidget {
  const SnapDarkAdBanner({super.key});

  @override
  State<SnapDarkAdBanner> createState() => _SnapDarkAdBannerState();
}

class _SnapDarkAdBannerState extends State<SnapDarkAdBanner> {
  BannerAd? _bannerAd;
  bool _isLoaded = false;
  int _requestedWidth = 0;
  double _reservedHeight = 0;
  int _loadGen = 0;
  int _retryCount = 0;
  static const int _maxRetries = 3;
  static const Duration _retryDelay = Duration(seconds: 5);

  void _log(String message) {
    try {
      Provider.of<LogService>(context, listen: false).add(message);
    } catch (_) {}
  }

  Future<void> _loadBanner(int width) async {
    if (!mounted || width <= 0) return;
    final gen = ++_loadGen;
    _requestedWidth = width;
    // Swap the old ad out immediately: it was sized for the previous slot.
    final old = _bannerAd;
    _bannerAd = null;
    old?.dispose();
    if (_isLoaded) setState(() => _isLoaded = false);

    final size =
        await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width);
    if (!mounted || gen != _loadGen) return;
    if (size == null) {
      _log('AdBanner: no adaptive size for width=$width');
      // No adaptive size for this width → collapse the slot (never leave an
      // empty strip reserved for an ad that will never arrive).
      setState(() {
        _isLoaded = false;
        _reservedHeight = 0;
      });
      return;
    }

    final ad = BannerAd(
      adUnitId: AdConfig.bannerUnitId,
      size: size,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (!mounted || gen != _loadGen) return;
          _retryCount = 0;
          _reservedHeight = size.height.toDouble();
          _log('AdBanner: loaded ${size.width}x${size.height}');
          setState(() => _isLoaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          // Stale/superseded instance: it was already disposed at the swap
          // (or in dispose()) — disposing it again would throw.
          if (!mounted || gen != _loadGen) return;
          ad.dispose();
          _log('AdBanner: load failed (code=${error.code}) ${error.message}');
          setState(() {
            _bannerAd = null;
            _isLoaded = false;
            // A real failure collapses the slot — never a dead empty strip.
            _reservedHeight = 0;
          });
          if (_retryCount < _maxRetries) {
            _retryCount++;
            _log('AdBanner: retry $_retryCount/$_maxRetries in ${_retryDelay.inSeconds}s');
            Future.delayed(_retryDelay, () {
              if (mounted && gen == _loadGen) _loadBanner(width);
            });
          }
        },
      ),
    );
    _bannerAd = ad;
    unawaited(ad.load());
  }

  @override
  void dispose() {
    _loadGen++; // invalidate any in-flight load callback
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Ads are OFF until the Play Store launch (AdConfig.adsEnabled) — the
    // banner slot collapses to zero height, exactly like a failed load.
    if (!AdConfig.adsEnabled) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, constraints) {
      final slot = (constraints.maxWidth.isFinite && constraints.maxWidth > 0)
          ? constraints.maxWidth.floor()
          : MediaQuery.sizeOf(context).width.floor();

      // First request, or the slot width changed (rotation/fold): load with
      // the exact width this banner will occupy.
      if (_requestedWidth == 0 || (slot - _requestedWidth).abs() > 1) {
        _requestedWidth = slot; // claim synchronously — no double schedule
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadBanner(slot);
        });
      }

      if (!_isLoaded || _bannerAd == null) {
        // Before the first load: 0 height (no gap). During a width reload:
        // the previous height, so the column below does not jump.
        return SizedBox(height: _reservedHeight);
      }

      final t = context.tokens;
      final ad = _bannerAd!;
      return Center(
        child: Container(
          width: math.min(ad.size.width.toDouble(), slot.toDouble()),
          height: ad.size.height.toDouble(),
          decoration: BoxDecoration(
            color: t.surfaceFill,
            border: Border(top: BorderSide(color: t.border)),
          ),
          child: ClipRect(child: AdWidget(ad: ad)),
        ),
      );
    });
  }
}
