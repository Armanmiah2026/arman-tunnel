# Arman Tunnel — Android VPN Client (source build guide)

Flutter VPN client with a native Kotlin engine. This zip is the **app only**;
the admin panel (which produces the config feed this app consumes) ships as a
separate package. You are free to build, modify and rebrand this code.

Tunnel engines (all produce a local SOCKS5/HTTP pair the TUN feeds):

| Engine | Path | Notes |
|---|---|---|
| VLESS / VMess / Trojan / Shadowsocks | xray-core binary (`libxray.so`) | exec'd, config generated in Dart (`ServerConfig.toXrayConfig`) |
| Hysteria 2 (QUIC/UDP) | `libhysteria.so` | exec'd, SOCKS5 mode |
| SSH | vendored trilead-ssh2 (pure Java/Kotlin) | payload/SNI/proxy injection supported |
| SSH over DNS (DNSTT) | `libh2.so` + DNSTT | carries SSH inside DNS queries |
| OpenVPN | ovpn3 JNI (`libovpncli.so`, bindings in `android/app/src/main/java/ph/yooh`) | profile pasted/`remote` parsed in Kotlin |
| WireGuard | `WireGuardEngine.kt` ready | wg-go binary integration is a documented TODO (clean error until added) |
| SOCKS5 / HTTP proxy node | in-app bridge | plain proxy node |
| Psiphon | `PsiphonEngine.kt` | public-network CONNECT bridge, region hint |

Plus: DPI payload injector (`PayloadInjector.kt` — HTTP front/payload/SNI
obfuscation for SSH/OVPN/V2Ray), split tunnel, kill switch, liveness probe,
VIP/ad-gate, device trial, share links (incl. password-locked), update/lock
feed. Full architecture notes are in this README (there are intentionally no
other doc files).

## 1. Requirements (your PC)

- **Flutter 3.32+** — CI used **3.47.4** (16 KB-page-aligned engine required by
  Play for Android 15+). Local dev on 3.29 also works.
- **JDK 17**, **Android SDK**: `compileSdk/targetSdk 36`, build-tools 35,
  **NDK 25.1.8937393** + **CMake 3.22.1** (for `libsenseicrypto.so`).
- Gradle 8.11.1 / AGP 8.7.3 / Kotlin 2.0.21 — all pinned in the project.
- Go 1.24+ **only if** you want to rebuild the Hysteria binary (§5).
- `minSdk 24`. Signed release needs a real keystore you generate (§4).

## 2. First build (debug)

```bash
cd <this folder>
flutter pub get
flutter analyze          # must be clean
flutter test             # unit/widget tests
flutter run              # a physical arm64 phone is strongly recommended
```

Debug APK (dual ABI):

```bash
flutter build apk --debug --target-platform android-arm,android-arm64 --split-per-abi
# → build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk / app-armeabi-v7a-debug.apk
```

Do **not** run a bare `flutter build apk --debug` — without
`--split-per-abi --target-platform` you get an x86-flavored APK without the
native crypto lib (see `android/app/build.gradle` `splits.abi`).

## 3. Toolchain wiring files

- `android/local.properties` — machine-specific; a sample ships as
  `android/local.properties.example`. Copy it and adjust:

```properties
sdk.dir=/path/to/Android/sdk
flutter.sdk=/path/to/flutter
# app version fallback (normally injected by `flutter build`):
flutter.versionName=1.0.0
flutter.versionCode=1
# signing (read by android/app/build.gradle):
sensei.storeFile=upload-keystore.jks
sensei.storePassword=<your store password>
sensei.keyAlias=<your alias>
sensei.keyPassword=<your key password>
sensei.expectedCertSha256=<your cert SHA-256, lowercase hex, no colons>
```

  Every `sensei.*` key also has an env-var form (`SENSEI_STORE_FILE`,
  `SENSEI_STORE_PASSWORD`, `SENSEI_KEY_ALIAS`, `SENSEI_KEY_PASSWORD`,
  `SENSEI_EXPECTED_CERT_SHA256`) used by CI.

- `android/app/src/main/cpp/` builds `libsenseicrypto.so` via CMake. It takes
  `-DSENSEI_EXPECTED_CERT_SHA256=...` from Gradle (env / local.properties).
  While that value is **blank**, the native integrity gate is off (dev
  mode). When set, the config feed only decrypts when the APK signing cert
  matches — a wrong value makes the whole feed fail on purpose.

## 4. Signing keystore (generate your own)

```bash
keytool -genkeypair -v -keystore android/app/upload-keystore.jks \
  -alias myalias -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass 'YOUR_PASSWORD' -keypass 'YOUR_PASSWORD' \
  -dname "CN=You, OU=Dev, O=You, L=City, C=US"

keytool -list -v -keystore android/app/upload-keystore.jks \
  -storepass 'YOUR_PASSWORD' -alias myalias | grep SHA256
```

Put the printed SHA-256 (colons removed, lowercase) into
`sensei.expectedCertSha256` AND into the admin Worker's `APP_CERT_SHA256` var
(admin package §5). No keystore file is included — **never reuse anyone else's**;
the config feed encryption and VIP tickets are cryptographically bound to this
cert.

## 5. Native binaries (`android/app/src/main/jniLibs/<abi>/`)

Already included (track them in git with binary handling, e.g.
`*.so -text`): `libtun2socks.so`, `libh2.so` (DNSTT), `libopenvpn.so`,
`libovpncli.so`, `libovpnexec.so` (OpenVPN engine).

**Not included — put them in place before release builds:**

| File | Source |
|---|---|
| `arm64-v8a/libxray.so` | https://github.com/XTLS/Xray-core/releases/download/v25.5.16/Xray-android-arm64-v8a.zip → unzip, rename the `xray` binary to `libxray.so`, `chmod +x` |
| `armeabi-v7a/libxray.so` | same release, `Xray-linux-arm32-v7a.zip` — a **static Linux/ARM** Go build on purpose: upstream ships no Android arm32 asset, and static binaries exec fine from `nativeLibraryDir` |
| `arm64-v8a/libhysteria.so` + `armeabi-v7a/libhysteria.so` | build apernet/hysteria (pinned commit `4849cda3ea1fae81003f9c597d9c6b8af0fb5a7c`), see below |

Hysteria build (on Linux, with Android NDK env):

```bash
git init -q hysteria-src && cd hysteria-src
git remote add origin https://github.com/apernet/hysteria.git
git fetch -q --depth 1 origin 4849cda3ea1fae81003f9c597d9c6b8af0fb5a7c
git checkout -q FETCH_HEAD && cd app

# anet v0.0.5 patch: its //go:linkname zoneCache breaks the armv7 link on Go 1.24+.
git clone -q --depth 1 --branch v0.0.5 https://github.com/wlynxg/anet.git ../../anet-patched
sed -i '/^\/\/go:linkname zoneCache/d' ../../anet-patched/interface_android.go
go mod edit -replace github.com/wlynxg/anet=../../anet-patched

CGO_ENABLED=0 GOOS=android GOARCH=arm64 go build -trimpath -ldflags="-s -w" \
  -o ../../android/app/src/main/jniLibs/arm64-v8a/libhysteria.so .

CC=$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi21-clang \
CXX=${CC}++ CGO_ENABLED=1 GOOS=android GOARCH=arm GOARM=7 \
go build -trimpath -ldflags="-s -w" \
  -o ../../android/app/src/main/jniLibs/armeabi-v7a/libhysteria.so .

chmod +x ../../android/app/src/main/jniLibs/*/libhysteria.so
```

Gotchas: `libxray.so`/`libhysteria.so`/`libtun2socks.so`/`libh2.so` are
**exec'd, not linked** — `packagingOptions doNotStrip` covers them and they
keep `.so` names so the installer ships them. `libovpncli.so` is a **JNI lib,
never exec** (driven from `ph/yooh/novpn` SWIG bindings). The Gradle env var
`SENSEI_ABIS` (default `arm64-v8a,armeabi-v7a`) filters the CMake build.
WireGuard (`libwireguard.so`) has no upstream Android release — the engine
errors cleanly until you integrate wg-go with a JNI TUN handoff.

## 6. Release build

```bash
flutter build apk --release --obfuscate \
  --split-debug-info=build/app/outputs/symbols --split-per-abi \
  --target-platform android-arm,android-arm64
```

Release = `minifyEnabled` + `shrinkResources`: if you add JNI/SWIG/
reflection-reached classes, add ProGuard keep rules
(`proguard-rules.pro` keeps the vendored SSH + ovpn3 + eddsa classes — release
used to break on `Key exchange was not finished` until that rule existed).
Universal (fat) APKs need a **two-pass** build (native pass binds the Dart AOT
hashes); a single pass can ship a mismatched pair.

Version bump places (keep in sync): `lib/app_meta.dart`
(`kAppVersion`/`kAppBuildNumber`), `pubspec.yaml` (`version: X+Y`),
`android/local.properties`. Split-ABI builds override versionCode as
`base*10 + 2` (arm64) / `+1` (armv7) — force-update checks compare against
that inflated code.

## 7. App backend configuration (`lib/services/obf.dart`) — REQUIRED

The feed URLs/keys are XOR-obfuscated (`tool/obf_encode.dart` encodes; `_key`
in `obf.dart` decodes). All values ship **empty** in this zip — fill them or
the app runs but never receives official servers:

| Getter | Value |
|---|---|
| `githubConfigUrl` | URL of the encrypted **configs bundle** (the admin panel publishes `arman_configs_2026_v2.enc` into your configs repo / GitHub Pages or any static host) |
| `githubSettingsUrl` | URL of the encrypted **settings bundle** (lock/force-update/branding/wallpapers) |
| `githubConfigBase` | base URL for per-device trial-status files (`<deviceId>.json`) |
| `githubConfigKey` | legacy v1 XOR key (leave empty if you only publish v2/v3) |
| `adminUrl`, `telegram` | support links shown in About/Support |

Encoding: `dart run tool/obf_encode.dart "https://your.host/configs.enc"` →
paste output into `dec('...')`.

**Shared seed strings (change ALL together, or none):** the branding seeds
`ArmanTunnel:Armanmiah2026:*` appear in
`MainActivity.kt` (lockKeySeed), `ShareEnvelope.kt` (APP_SEED),
`cpp/senseicrypto.c` (obfuscated OB_V2_SEED / OB_V1_KEY / OB_VIP_SEED /
OB_V3_PEPPER) **and** the admin Worker (`crypto.js` V2_SEED / VIP_SEED /
V3_PEPPER_DEFAULT). If you rename, change every copy in the same release —
`python3 tool/rotate_seeds.py --rotate` does it atomically and re-verifies the
native arrays — or locked shares, VIP tickets and the config feed stop
matching.

Replace the UI contact placeholders: search `armantunnel` / `Arman Miah` in
`lib/`. Package identity: `applicationId`/`namespace` `com.sensei.tunnel`
(`android/app/build.gradle`) + matching paths in
`android/app/src/main/kotlin/com/sensei/tunnel/`; `google-services.json` only
if you enable AdMob (currently optional, `ad_service.dart` handles absence).

Brand assets (launcher icons, splash lockup, logos) are generated from ONE
source by `python3 tool/rebrand_assets.py` — re-run it after logo changes
instead of editing PNGs by hand.

## 8. Maintainer rules (learned the hard way)

- **Per-connect flags need THREE places**: `vpn_service.dart` channel args →
  `MainActivity.launchService()` `putExtra` → `SenseiTunnelVpnService
  .onStartCommand` read. Missing one = feature silently dead.
  (`routeRules`/`sniOverride` are Dart-side exceptions — folded into the xray
  JSON, no native extras.)
- Hardcoded local ports are duplicated in Dart AND Kotlin — change together:
  SOCKS `10808` / HTTP `10809`, payload-injector `8089`, DNS-over-TCP gateway
  `7353`, DNSTT local `7301`.
- The app's own traffic stays on the **physical** network (never
  `bindProcessToNetwork(vpnNetwork)`) — probes dial the tunnel explicitly via
  the local SOCKS proxy. The speed-test sheet is the only exception.
- Liveness probes use multiple targets (204 on :80 + TLS :443) and only kill
  after consecutive FULL-sweep failures; a single failing target never kills a
  session/engine death uses the kill-switch-aware `cleanup(keepTun)` +
  generation token.
- `pingHost` must never run on the main thread (blocking sockets).
- Vendored/generated dirs — do not reformat: `android/app/src/main/java/
  {com/trilead, net/sourceforge, com/cbtunnel, ph/yooh, io/flutter}`.
- User-facing errors must go through `UserError` (release shows CATEGORY only;
  raw details in logs/debug).
- UI palette is strictly violet/lavender (`lib/theme/sensei_tokens.dart`); errors
  amber. Tabs live in an `IndexedStack` — never `Navigator.pop` to switch tabs.

## 9. Verification commands

```bash
flutter analyze          # primary gate — keep clean
flutter test             # works clean on desktop Linux/Windows/macOS
cd android && ./gradlew :app:compileDebugKotlin   # after touching Kotlin
```
