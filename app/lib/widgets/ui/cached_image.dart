import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../services/config_service.dart';
import '../../services/tunnel_http_client.dart';
import '../../theme/sensei_theme.dart';

/// The load state of ONE logo image (keyed by URL), shared by every surface
/// that renders it — the configs list, the home dashboard, anywhere.
///
/// Sharing is the point: the instant a download finishes, every widget reads
/// this same entry, so no screen can keep spinning while another already
/// shows the image. State lives process-wide in [SenseiLogoCache], never in a
/// per-widget field that a disposed/recycled element could strand.
class LogoEntry {
  /// The cached file to render when the image is ready.
  final File? file;

  /// The image already failed at least once → render the fallback glyph
  /// instead of keeping the spinner (or hammering the network).
  final bool failed;

  bool get loaded => file != null;

  const LogoEntry({this.file, this.failed = false});
}

/// Process-wide logo cache + reactive state bus.
///
/// · Cache: one download per URL (shared in-flight future), written to
///   `<docs>/sensei_img_cache/<url-hash>.png` the moment it arrives.
/// · State: one [LogoEntry] per URL. Every change fires [notifyListeners()]
///   so all listening widgets rebuild immediately — no app restart needed.
/// · Failures: recorded as a `failed` entry so fallback glyphs render once,
///   instead of the loader spinning forever.
class SenseiLogoCache extends ChangeNotifier {
  SenseiLogoCache._();

  static final SenseiLogoCache instance = SenseiLogoCache._();

  final Map<String, LogoEntry> _entries = {};
  final Map<String, Future<LogoEntry>> _inFlight = {};

  /// Current state for [url] (an unloaded placeholder if we know nothing yet).
  /// Pure read — safe to call during build.
  LogoEntry entryFor(String url) => _entries[url] ?? const LogoEntry();

  /// Make sure [url] is loaded, or at least has a download in flight. Never
  /// re-downloads an entry that is already loaded or already failed. Call
  /// from lifecycle methods (not build); completion reaches widgets via
  /// [notifyListeners] and this notifier.
  void watch(String url, int cachePx) {
    final entry = _entries[url];
    if (entry != null && (entry.loaded || entry.failed)) return;
    if (_inFlight.containsKey(url)) return;
    _inFlight[url] = _resolve(url, cachePx);
  }

  /// Cache hit → loaded instantly. Miss → download → decimate + write file →
  /// loaded. Any failure → `failed` entry. Always notifies when the final
  /// state is known so whichever widget asked gets rebuilt out of its loader.
  Future<LogoEntry> _resolve(String url, int cachePx) async {
    LogoEntry entry;

    // 1. Local file already on disk (previous session or a parallel load).
    try {
      final dir = await SenseiCachedImage.cacheDirPath();
      final f = File('$dir/${SenseiCachedImage.hash(url)}.png');
      if (await f.exists()) {
        entry = LogoEntry(file: f);
        _entries[url] = entry;
        notifyListeners();
        return entry;
      }
    } catch (_) {/* fall through to a network load */}

    // 2. Download + store.
    final file = await SenseiCachedImage.fetchAndCache(url, cachePx);
    entry = file != null
        ? LogoEntry(file: file)
        : const LogoEntry(failed: true);
    _entries[url] = entry;
    notifyListeners();
    return entry;
  }

  /// Manual-refresh path: drop the current entry, park the old file as
  /// `.bak`, and re-download. If the refresh fails the parked file is handed
  /// back so the avatar never blanks because a refresh was attempted.
  Future<void> revalidate(String url, int cachePx) async {
    if (_inFlight.containsKey(url)) return; // a reload is already running
    var dir = '';
    var backedUp = false;
    try {
      dir = await SenseiCachedImage.cacheDirPath();
      final f = File('$dir/${SenseiCachedImage.hash(url)}.png');
      final backup = File('$dir/${SenseiCachedImage.hash(url)}.bak');
      if (await f.exists()) {
        try {
          if (await backup.exists()) await backup.delete();
          await f.rename(backup.path);
          backedUp = true;
        } catch (_) {/* nothing to park — just re-resolve from scratch */}
      }
    } catch (_) {}

    _entries.remove(url);
    notifyListeners();

    final entry = await _resolve(url, cachePx);

    if (backedUp) {
      final f = File('$dir/${SenseiCachedImage.hash(url)}.png');
      final backup = File('$dir/${SenseiCachedImage.hash(url)}.bak');
      if (entry.failed) {
        try {
          await backup.rename(f.path);
          _entries[url] = LogoEntry(file: f);
          notifyListeners();
        } catch (_) {/* backup unreadable — keep the fallback glyph */}
      } else {
        try {
          await backup.delete();
        } catch (_) {/* orphaned backup is harmless */}
      }
    }
  }
}

/// Network image with a PERMANENT low-quality local cache and a reactive,
/// shared load state (see [SenseiLogoCache]).
///
/// Widgets never own their `loading/image/error` flags — they subscribe to
/// the URL's entry, so the moment the download lands (or a cached file is
/// found) every surface renders the image on the next frame. No more
/// "image visible on Home but the Configs list still spins" divergence, and
/// no app restart needed to pick up a freshly-loaded logo.
class SenseiCachedImage extends StatefulWidget {
  final String url;

  /// Logical render size (both edges — avatars are square).
  final double size;

  /// Error fallback builder (receives the box it must fill).
  final WidgetBuilder errorBuilder;

  const SenseiCachedImage({
    super.key,
    required this.url,
    required this.size,
    required this.errorBuilder,
  });

  @override
  State<SenseiCachedImage> createState() => _SenseiCachedImageState();

  static Future<String> cacheDirPath() async =>
      '${(await getApplicationDocumentsDirectory()).path}/sensei_img_cache';

  /// Stable FNV-1a 64-bit hash of the URL — the cache file name.
  static String hash(String url) {
    var h = 0xcbf29ce484222325;
    for (final b in url.codeUnits) {
      h ^= b;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }

  /// Download → downsample → PNG → cache file. Null on any failure.
  static Future<File?> fetchAndCache(String url, int cachePx) async {
    try {
      final res = await TunnelHttpClient.get(
        Uri.parse(url),
        timeout: const Duration(seconds: 15),
      );
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      final codec = await ui.instantiateImageCodec(
        Uint8List.fromList(res.bodyBytes),
        targetWidth: cachePx,
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      if (data == null) return null;
      final dir = Directory(await cacheDirPath());
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}/${hash(url)}.png');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return file;
    } catch (_) {
      return null;
    }
  }
}

class _SenseiCachedImageState extends State<SenseiCachedImage> {
  int _seenRefresh = 0;

  int get _cachePx => (widget.size * 2).round();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _seenRefresh = context.read<ConfigService>().logoCacheEpoch;
    SenseiLogoCache.instance.watch(widget.url, _cachePx);
  }

  @override
  void didUpdateWidget(SenseiCachedImage old) {
    super.didUpdateWidget(old);
    final epoch = context.read<ConfigService>().logoCacheEpoch;
    final epochChanged = epoch != _seenRefresh;
    _seenRefresh = epoch;
    if (old.url != widget.url) {
      SenseiLogoCache.instance.watch(widget.url, _cachePx);
    } else if (epochChanged) {
      // Manual config refresh: the cache is keyed ONLY by URL, so a logo the
      // admin swapped while keeping the same imgbb URL would otherwise stay
      // frozen at the first download. Re-download the CURRENT url once per
      // successful manual refresh; failures keep the old image.
      unawaited(SenseiLogoCache.instance.revalidate(widget.url, _cachePx));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final size = widget.size;

    return ListenableBuilder(
      listenable: SenseiLogoCache.instance,
      builder: (context, _) {
        final entry = SenseiLogoCache.instance.entryFor(widget.url);

        // Loaded → render the cached file (instant, offline-safe).
        if (entry.file != null) {
          return Image.file(
            entry.file!,
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: _cachePx,
            errorBuilder: (_, __, ___) => widget.errorBuilder(context),
          );
        }

        // Failed → fallback glyph right away; never a forever-spinner.
        if (entry.failed) {
          return widget.errorBuilder(context);
        }

        // Loading placeholder — muted spinner box until the shared entry
        // flips to loaded/failed on the next frame after the download.
        return Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.accentWash,
            borderRadius: SenseiTokens.brSm,
          ),
          child: SizedBox(
            width: size * 0.33,
            height: size * 0.33,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: t.accent,
            ),
          ),
        );
      },
    );
  }
}