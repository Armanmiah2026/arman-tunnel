import 'dart:convert';

/// Build-specific secrets/URLs, XOR-obfuscated so they never appear as plain
/// strings in the release APK's string table.
///
/// *** SELLER-STRIPPED BUILD ***
/// Every value below ships EMPTY. Fill them in for YOUR deployment before
/// shipping: encode each string with the same XOR scheme, e.g. run this once
/// on any machine with Dart:
///
///   dart run tool/obf_encode.dart "https://cdn.yourdomain.com/configs"
///
/// ...and paste the printed base64 into the matching getter below. See
/// README.md §7 for which value feeds what. `githubConfigKey` is the legacy
/// v1 XOR fallback — leave it empty if you only publish v2/v3 bundles.
class Obf {
  /// 2026-10 sale build ships a neutral key; change it together with every
  /// encoded value (encoder and decoder share this key).
  static const String _key = 'SnSeiTnL::2026::cfgK';

  static String dec(String obfuscatedBase64) {
    try {
      final decodedBytes = base64Decode(obfuscatedBase64);
      final keyBytes = utf8.encode(_key);
      final result = List<int>.filled(decodedBytes.length, 0);
      for (int i = 0; i < decodedBytes.length; i++) {
        result[i] = decodedBytes[i] ^ keyBytes[i % keyBytes.length];
      }
      return utf8.decode(result);
    } catch (e) {
      return '';
    }
  }

  /// Admin/support URL shown in-app (e.g. your dashboard or site).
  static String get adminUrl => dec('OxonFRpuQWNbXl9ZXBhZVgwTAz1hHDwcRywXNg==');

  /// Encrypted config bundle URL (the panel publishes it; see README §7).
  static String get githubConfigUrl => dec('OxonFRpuQWNbSF9RXFtTWwtUV3llQDQMHTwbLhRTXR9TRFdbDUsTPj0ANglENwEiXFNVQx1XSFcCCDgoPAA1DA4nMX4KCARvRAQUXw0F');

  /// Encrypted app-settings bundle URL (lock/force-update/branding).
  static String get githubSettingsUrl => dec('OxonFRpuQWNbSF9RXFtTWwtUV3llQDQMHTwbLhRTXR9TRFdbDUsTPj0ANglENwEiXFNVQx1XSFcCCDgqIx4MFgwgGiVUXUEeV1hZ');

  /// Raw base URL of the bundle host — per-device trial-status files
  /// (<deviceId>.json) are published there so the app reads its status from
  /// the CDN instead of hammering the admin Worker.
  static String get githubConfigBase => dec('OxonFRpuQWNbSF9RXFtTWwtUV3llQDQMHTwbLhRTXR9TRFdbDUsTPj0ANglENwEiXFNVQw==');

  /// Backup XOR key for legacy v1 bundles (kept for old configs).
  static String get githubConfigKey => dec('');

  /// Telegram link used by the support/about screens.
  static String get telegram => dec('OxonFRpuQWNOFF9VHVdIVwIIEz49ADYJ');
}
