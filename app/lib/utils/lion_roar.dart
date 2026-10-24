import 'package:audioplayers/audioplayers.dart';

/// The connect-dial roar (owner request: "lion sound right after tapping
/// Connect").
///
/// A dedicated low-latency [AudioPlayer] fires `assets/audio/lion_roar.m4a`
/// — a public-domain lion recording (Wikimedia Commons, Tamil Nadu) trimmed
/// to the roar and loudness-normalised. Everything here is best-effort: a
/// missing asset, a busy audio focus or a platform without a player must
/// never break or delay the connect flow, so every failure is swallowed.
class LionRoar {
  LionRoar._();
  static final LionRoar instance = LionRoar._();

  AudioPlayer? _player;

  Future<void> play() async {
    try {
      final p = _player ??= AudioPlayer()..setReleaseMode(ReleaseMode.stop);
      await p.stop();
      await p.play(
        AssetSource('audio/lion_roar.m4a'),
        volume: 1.0,
        mode: PlayerMode.lowLatency,
      );
    } catch (_) {
      // Best effort only — the tunnel must dial regardless of audio state.
    }
  }

  Future<void> dispose() async {
    try {
      await _player?.dispose();
    } catch (_) {}
    _player = null;
  }
}
