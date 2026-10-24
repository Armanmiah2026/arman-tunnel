import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapdark_tunnel/theme/snapdark_theme.dart';
import 'package:snapdark_tunnel/widgets/snapdark/golden_lion_background.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// The golden-lion backdrop must be bullet-proof in every environment: in
/// widget tests (and on any device that cannot play the bundled loop) the
/// video platform layer fails, and the widget has to sit on its still poster
/// + painterly golden-jungle net — never a red screen, never a stuck ticker
/// after the test ends. The flip side (a platform that CAN play) proves the
/// owner's rule: NOTHING plays until Connect is pressed — then the loop runs
/// (sound on, Settings volume live), freezes on disconnect, resumes on
/// reconnect, pauses while backgrounded, and is released exactly once.
void main() {
  testWidgets(
      'disconnected background shows the still poster over the painterly '
      'net — no video attempt, no red screen', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SnapDarkTheme.dark,
        home: const Scaffold(body: GoldenLionBackground()),
      ),
    );
    // Give async image resolution a couple of frames to settle.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('goldenLionPoster')), findsOneWidget);
    expect(find.byKey(const Key('goldenLionFallback')), findsOneWidget);
    // No platform player is ever touched while disconnected.
    expect(find.byKey(const Key('goldenLionVideoSurface')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'shockwave stays idle until the connect-success edge, then sweeps without throwing',
      (tester) async {
    const sceneKey = Key('shockwave-scene');

    Widget scene(bool connected) => MaterialApp(
          theme: SnapDarkTheme.dark,
          home: Scaffold(
            body: GoldenLionShockwaveOverlay(
              key: sceneKey,
              isConnected: connected,
            ),
          ),
        );

    // Disconnected: idle box, no animation running.
    await tester.pumpWidget(scene(false));
    expect(find.byType(GoldenLionShockwaveOverlay), findsOneWidget);
    expect(tester.takeException(), isNull);

    // THE moment: the tunnel comes up → the boom fires and paints.
    await tester.pumpWidget(scene(true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    // Let the one-shot finish so no ticker outlives the test.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reconnecting fires a fresh shockwave each time', (tester) async {
    Widget scene(bool connected) => MaterialApp(
          theme: SnapDarkTheme.dark,
          home: Scaffold(
            body: GoldenLionShockwaveOverlay(isConnected: connected),
          ),
        );

    await tester.pumpWidget(scene(false));
    await tester.pumpWidget(scene(true));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    // Drop the connection and connect again — second boom must not throw.
    await tester.pumpWidget(scene(false));
    await tester.pumpWidget(scene(true));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the golden lion video starts ONLY on Connect: looped, sound on, '
      'frozen on disconnect, resumed on reconnect, released exactly once '
      'on dispose', (tester) async {
    final previous = VideoPlayerPlatform.instance;
    final fake = _FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = fake;
    addTearDown(() => VideoPlayerPlatform.instance = previous);

    Widget scene({bool connected = false, double soundVolume = 1.0}) =>
        MaterialApp(
          theme: SnapDarkTheme.dark,
          home: Scaffold(
            body: GoldenLionBackground(
              isConnected: connected,
              soundVolume: soundVolume,
            ),
          ),
        );

    // App open (disconnected): the still poster IS the background and the
    // platform layer is not touched — no player is even created.
    await tester.pumpWidget(scene());
    await tester.pump(const Duration(milliseconds: 50));
    expect(fake.calls, isEmpty);
    expect(find.byKey(const Key('goldenLionPoster')), findsOneWidget);
    expect(find.byKey(const Key('goldenLionVideoSurface')), findsNothing);

    // TAP CONNECT → the loop boots: create → initialized event → loop /
    // volume → play → setState(_ready). Bounded pumps only while the video
    // plays: the controller runs a 100ms position timer whose updates the
    // VideoPlayer widget repaints, so pumpAndSettle would never settle.
    await tester.pumpWidget(scene(connected: true));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // The VIDEO layer renders over the poster — playing exactly the bundled
    // asset, looping, at full volume (the owner's roar/music ships with it).
    expect(fake.calls, contains('create:${GoldenLionBackground.videoAsset}'));
    expect(fake.looping, isTrue);
    expect(fake.volume, 1.0);
    expect(fake.playing, isTrue);
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(find.byKey(const Key('goldenLionVideoSurface')), findsOneWidget);

    // Settings → Background Sound −/+ takes effect live on the player.
    await tester.pumpWidget(scene(connected: true, soundVolume: 0.4));
    await tester.pump();
    expect(fake.volume, 0.4);

    // DISCONNECT → playback freezes (the still poster takes over).
    await tester.pumpWidget(scene());
    await tester.pump();
    expect(fake.playing, isFalse);

    // RECONNECT → the same player resumes; no second one is ever created.
    await tester.pumpWidget(scene(connected: true));
    await tester.pump();
    expect(fake.playing, isTrue);
    expect(fake.calls.where((c) => c.startsWith('create:')).length, 1);

    // App backgrounded → playback stops (no sound, no battery burn in the
    // background); back to foreground → it resumes.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(fake.playing, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(fake.playing, isTrue);

    expect(tester.takeException(), isNull);

    // Unmount → the platform player is released exactly once, taking the
    // position timer with it so no timer outlives the test. The controller's
    // teardown awaits subscription.cancel(), whose completion is scheduled
    // in the ROOT zone — FakeAsync never flushes it — so turn the real event
    // loop until the platform player is actually released.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      for (var i = 0; i < 50 && fake.disposeCount == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    expect(fake.disposeCount, 1);
    expect(tester.takeException(), isNull);
  });
}

/// A platform player that WORKS — the test double for video_player_android:
/// every call the widget's play path makes is honored and recorded.
class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final List<String> calls = <String>[];
  bool looping = false;
  double? volume;
  double? speed;
  bool playing = false;
  int disposeCount = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    calls.add('create:${options.dataSource.asset}');
    return 7;
  }

  final StreamController<VideoEvent> _events = StreamController<VideoEvent>();
  bool _emitted = false;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    // Exactly one `initialized` event — what the real platform sends —
    // buffered until the controller listens. A StreamController (instead of
    // Stream.fromIterable) gives the video_player controller a cancel()
    // future that actually completes, so dispose() can finish.
    if (!_emitted) {
      _emitted = true;
      _events.add(VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 13, milliseconds: 833),
        size: const Size(1080, 1920),
      ));
    }
    return _events.stream;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {
    this.looping = looping;
    calls.add('setLooping:$looping');
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {
    this.volume = volume;
    calls.add('setVolume:$volume');
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    this.speed = speed;
    calls.add('setPlaybackSpeed:$speed');
  }

  @override
  Future<void> play(int playerId) async {
    playing = true;
    calls.add('play');
  }

  @override
  Future<void> pause(int playerId) async {
    playing = false;
    calls.add('pause');
  }

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> dispose(int playerId) async {
    disposeCount += 1;
    calls.add('dispose');
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox(key: Key('goldenLionVideoSurface'));
}
