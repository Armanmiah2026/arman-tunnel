import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sensei_tunnel/services/settings_provider.dart';

/// A real, tiny PNG. Fixed base64 so only the codec (which works in this
/// tester) is exercised — never the render pipeline (`picture.toImage`
/// hangs under the Termux flutter_tester).
const _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  late Uint8List pngBytes;

  setUp(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
    docs = await Directory.systemTemp.createTemp('sensei_wall_apply');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docs.path;
        }
        return null;
      },
    );
    pngBytes = base64Decode(_tinyPngBase64);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  /// Seed the image cache the same way every real renderer does it — an
  /// `Image.file` WITH a decode hint, which Flutter keys as a
  /// `ResizeImage(FileImage, width)`, i.e. NOT a bare FileImage. This is the
  /// exact entry the old `evict(FileImage(file))` could never purge.
  ///
  /// The decode happens through the engine (`ui.instantiateImageCodec`) so we
  /// get real pixel bytes and a real cache entry without doing a render.
  Future<void> pumpResizeDecodedImage(WidgetTester tester, String path) async {
    ui.Image? img;
    await tester.runAsync(() async {
      final codec =
          await ui.instantiateImageCodec(pngBytes, targetWidth: 300);
      final frame = await codec.getNextFrame();
      img = frame.image;
    });
    final provider = ResizeImage(FileImage(File(path)), width: 300);
    final completer = OneFrameImageStreamCompleter(
      Future.value(ImageInfo(image: img!)),
    );
    PaintingBinding.instance.imageCache.putIfAbsent(provider, () => completer);
    // Attach a listener so the completer emits and the entry lands in the
    // sized cache.
    await tester.pumpWidget(
      MaterialApp(
        home: Image(
          image: provider,
          width: 64,
          height: 64,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(imageCache.currentSize, greaterThan(0),
        reason: 'precondition: a ResizeImage-keyed decode must be resident');
  }

  testWidgets('applying a wallpaper purges the stale decode immediately — no '
      'restart needed', (tester) async {
    final file = File('${docs.path}/sensei_wallpaper.png');
    await tester.runAsync(() {
      return file.writeAsBytes(pngBytes, flush: true);
    });

    // A thumbnail / preview has already decoded this path with a resize hint.
    await pumpResizeDecodedImage(tester, file.path);

    final settings = SettingsProvider();
    await tester.pumpAndSettle();

    await tester.runAsync(() => settings.setWallpaperBytes(pngBytes));

    // Old behaviour: the bare-FileImage evict missed the resident ResizeImage
    // entry, so the layer kept painting the OLD decode until the process died.
    // After the fix the cache carries nothing, so the notify-triggered rebuild
    // must re-decode the freshly written file. (liveImageCount is irrelevant
    // here: the mounted test widget still LISTENS to its completer, and the
    // cache deliberately keeps live refs until listeners detach.)
    expect(imageCache.currentSize, 0,
        reason: 'apply must drop every decode variant of the old bytes');
    expect(settings.wallpaperPath, file.path);
  });

  testWidgets('clearing the wallpaper empties the decode cache too',
      (tester) async {
    final file = File('${docs.path}/sensei_wallpaper.png');
    await tester.runAsync(
        () => file.writeAsBytes(pngBytes, flush: true));
    await pumpResizeDecodedImage(tester, file.path);

    // An applied wallpaper records its path in prefs — that is what makes
    // `clearWallpaper` take the "really clear" branch.
    SharedPreferences.setMockInitialValues(
        {'sensei_wallpaper_path': file.path});
    final settings = SettingsProvider();
    await tester.pumpAndSettle();
    await tester.runAsync(() => settings.clearWallpaper());

    expect(imageCache.currentSize, 0);
    expect(settings.hasWallpaper, isFalse);
    expect(await tester.runAsync(() => file.exists()), isFalse);
  });

  testWidgets('applying from an existing file (admin pick) also clears the '
      'cache', (tester) async {
    final source = File('${docs.path}/admin_0.png');
    final target = File('${docs.path}/sensei_wallpaper.png');
    await tester.runAsync(() async {
      await source.writeAsBytes(pngBytes, flush: true);
      await target.writeAsBytes(pngBytes, flush: true);
    });
    await pumpResizeDecodedImage(tester, target.path);

    final settings = SettingsProvider();
    await tester.pumpAndSettle();
    await tester.runAsync(() => settings.setWallpaperFile(source));

    expect(imageCache.currentSize, 0);
    expect(settings.wallpaperPath, target.path);
  });
}