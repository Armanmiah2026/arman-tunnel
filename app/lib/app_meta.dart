/// App identity — the SINGLE source for version strings/numbers.
///
/// Bumping the version means updating:
///   · these two constants,
///   · pubspec.yaml (`version:`),
///   · android/local.properties (flutter.versionName / flutter.versionCode).
/// Screens and services must import this file instead of hardcoding literals.
const String kAppVersion = '1.0.55';

/// The base build number from pubspec (`+59`). HOW ANDROID REPORTS IT:
/// split-ABI APKs override the installed versionCode to `base*10+2` (arm64) /
/// `base*10+1` (armv7) — see `android/app/build.gradle`
/// `versionCodeOverride` — so a split install reports **591/592**, NOT 59.
/// Only a non-split (single-file) APK installs as 59. The force-update gate in
/// `ConfigService.updateRequiredByCode` therefore compares against the runtime
/// code from `installedPackageInfo` (see `ConfigService.primeInstallInfo`); do
/// NOT wire this constant back into that comparison.
const int kAppBuildNumber = 61;
