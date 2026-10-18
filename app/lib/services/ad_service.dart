import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// AdMob unit IDs.
///
/// Test units are Google's official Test Ad Unit IDs, so every interaction
/// works without a live account. `useProduction` is the single switch: set it
/// to true to serve the real units, and false to fall back to test (useful
/// while developing, since AdMob does not serve real ads to debug builds).
class AdConfig {
  /// Real AdMob App ID. Publisher prefix is `3158058385417964` (16 digits —
  /// AdMob publisher IDs are ALWAYS 16). An earlier revision shipped a
  /// 15-digit prefix (`315805835417964`, one `8` short); the SDK treats that
  /// as a malformed APPLICATION_ID and CRASHES the app at startup — the
  /// reported "app crashes after recent changes". Keep the prefix exactly as
  /// the AdMob console shows it, and keep it in sync with the manifest's
  /// com.google.android.gms.ads.APPLICATION_ID.
  static const String appId = 'ca-app-pub-3158058385417964~9807182108';

  // Test ad unit IDs (Google official)
  static const String bannerTestUnitId = 'ca-app-pub-3940256099942544/6300978111';
  static const String interstitialTestUnitId = 'ca-app-pub-3940256099942544/1033173712';
  static const String rewardedTestUnitId = 'ca-app-pub-3940256099942544/5224354917';

  // Production ad unit IDs — all three are the REAL live units (publisher
  // 3158058385417964), so rewarded VIP unlocks earn a real impression.
  static const String bannerProdUnitId = 'ca-app-pub-3158058385417964/8400843509';
  static const String interstitialProdUnitId = 'ca-app-pub-3158058385417964/1625439759';
  static const String rewardedProdUnitId = 'ca-app-pub-3158058385417964/4646193061';

  /// Master switch: ads are OFF until the Play Store launch (user decision —
  /// Play review takes months; test ads would just clutter the UI until then).
  /// Flip to true when the store listing is ready. `useProduction` then picks
  /// test vs real units.
  static bool adsEnabled = false;

  /// Serve the real ad units. Debug builds keep test units on, since AdMob
  /// does not serve real ads from a debug-signed package anyway.
  static bool useProduction = false;

  static String get bannerUnitId => useProduction ? bannerProdUnitId : bannerTestUnitId;
  static String get interstitialUnitId => useProduction ? interstitialProdUnitId : interstitialTestUnitId;
  static String get rewardedUnitId => useProduction ? rewardedProdUnitId : rewardedTestUnitId;
}

class AdService {
  static bool _initialized = false;
  static InterstitialAd? _interstitialAd;
  static RewardedAd? _rewardedAd;
  static DateTime? _lastInterstitialShown;
  static const Duration _interstitialCooldown = Duration(minutes: 3);

  static Future<void> initialize() async {
    if (_initialized) return;
    if (!AdConfig.adsEnabled) return;
    try {
      // HARD TIMEOUT: main() awaits this before runApp — on devices where
      // Play services can never bind (old ROMs without GMS) the SDK's init
      // future may never complete, and an unbounded await freezes the app
      // on the splash frame — indistinguishable from a crash to users.
      await MobileAds.instance
          .initialize()
          .timeout(const Duration(seconds: 8));
      _initialized = true;
      // Preload both formats so the interstit (on disconnect) and the VIP
      // rewarded sheet (on tap) are ready immediately.
      loadInterstitial();
      loadRewarded();
    } catch (e) {
      debugPrint('AdMob init failed: $e');
      _initialized = false;
    }
  }

  // ── Interstitial ──────────────────────────────────────────────────────────

  static void loadInterstitial() {
    if (!_initialized || !AdConfig.adsEnabled) return;
    if (_interstitialAd != null) return;
    InterstitialAd.load(
      adUnitId: AdConfig.interstitialUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _interstitialAd = ad;
          _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (ad) {
              ad.dispose();
              _interstitialAd = null;
              loadInterstitial();
            },
            onAdFailedToShowFullScreenContent: (ad, error) {
              ad.dispose();
              _interstitialAd = null;
            },
          );
        },
        onAdFailedToLoad: (error) {
          _interstitialAd = null;
        },
      ),
    );
  }

  static bool get canShowInterstitial {
    if (_interstitialAd == null) return false;
    if (_lastInterstitialShown == null) return true;
    return DateTime.now().difference(_lastInterstitialShown!) >= _interstitialCooldown;
  }

  static void showInterstitial() {
    if (!canShowInterstitial) return;
    _lastInterstitialShown = DateTime.now();
    _interstitialAd!.show();
    _interstitialAd = null;
  }

  // ── Rewarded ──────────────────────────────────────────────────────────────

  static void loadRewarded() {
    if (!_initialized || !AdConfig.adsEnabled) return;
    if (_rewardedAd != null) return;
    RewardedAd.load(
      adUnitId: AdConfig.rewardedUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _rewardedAd = ad;
          _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (ad) {
              ad.dispose();
              _rewardedAd = null;
              loadRewarded();
            },
            onAdFailedToShowFullScreenContent: (ad, error) {
              ad.dispose();
              _rewardedAd = null;
            },
          );
        },
        onAdFailedToLoad: (error) {
          _rewardedAd = null;
        },
      ),
    );
  }

  static bool get hasRewardedAd => _rewardedAd != null;

  /// Shows the preloaded rewarded ad and resolves `true` only when the user
  /// watched to the reward point; `false` when they bailed before getting it
  /// or the ad could not be shown. Returns `null` when nothing was loaded.
  static Future<bool?> showRewarded() {
    if (!AdConfig.adsEnabled) return Future.value(null);
    final ad = _rewardedAd;
    if (ad == null) return Future.value(null);
    _rewardedAd = null;
    final completer = Completer<bool?>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        if (!completer.isCompleted) completer.complete(false);
      },
      onAdFailedToShowFullScreenContent: (a, error) {
        if (!completer.isCompleted) completer.complete(false);
      },
    );
    ad.show(
      onUserEarnedReward: (rewardAd, rewardItem) {
        if (!completer.isCompleted) completer.complete(true);
      },
    );
    return completer.future;
  }

  static void dispose() {
    _interstitialAd?.dispose();
    _interstitialAd = null;
    _rewardedAd?.dispose();
    _rewardedAd = null;
  }
}