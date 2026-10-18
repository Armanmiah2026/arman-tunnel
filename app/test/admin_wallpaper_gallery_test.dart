import 'package:flutter_test/flutter_test.dart';

import 'package:sensei_tunnel/services/config_service.dart';

void main() {
  group('parseWallpaperEntries', () {
    test('titled {url,title} objects survive untouched, deduped by url', () {
      final e = ConfigService.parseWallpaperEntries([
        {'url': 'https://i.ibb.co/a/1.png', 'title': 'Boy'},
        {'url': 'https://i.ibb.co/b/2.png', 'title': 'Grills'},
        {'url': 'https://i.ibb.co/a/1.png', 'title': 'dup'},
      ]);
      expect(e.length, 2);
      expect(e[0].title, 'Boy');
      expect(e[1].title, 'Grills');
    });

    test('untitled entries get position names (Wallpaper 1/2/…)', () {
      final e = ConfigService.parseWallpaperEntries([
        {'url': 'https://x/1.png'},
        'https://x/2.png',
      ]);
      expect(e.map((w) => w.title).toList(), ['Wallpaper 1', 'Wallpaper 2']);
    });

    test('legacy single backend.wallpaper folds in FIRST', () {
      final e = ConfigService.parseWallpaperEntries(
        [
          {'url': 'https://x/2.png', 'title': 'Second'},
        ],
        legacySingle: 'https://x/1.png',
      );
      expect(e.length, 2);
      expect(e.first.url, 'https://x/1.png');
      expect(e.first.title, 'Wallpaper 1');
      expect(e[1].title, 'Second');
    });

    test('legacy single already present in the list is NOT duplicated', () {
      final e = ConfigService.parseWallpaperEntries(
        [
          {'url': 'https://x/1.png', 'title': 'One'},
        ],
        legacySingle: 'https://x/1.png',
      );
      expect(e.length, 1);
      expect(e.first.title, 'One');
    });

    test('empty / garbage payloads yield an empty gallery', () {
      expect(ConfigService.parseWallpaperEntries(null), isEmpty);
      expect(ConfigService.parseWallpaperEntries('nope'), isEmpty);
      expect(ConfigService.parseWallpaperEntries([]), isEmpty);
      expect(
        ConfigService.parseWallpaperEntries([
          {'url': '   '},
          null,
        ]),
        isEmpty,
      );
    });

    test('the LIVE panel payload parses to the published gallery', () {
      // Exactly what the Worker ships right now (admin panel → KV → bundle).
      final e = ConfigService.parseWallpaperEntries(
        [
          {
            'url': 'https://i.ibb.co/SXwx23C7/1000296865.png',
            'title': 'Boy',
          },
          {
            'url': 'https://i.ibb.co/DfHsnGgq/1000297992.png',
            'title': 'Grills',
          },
          {
            'url': 'https://i.ibb.co/KJ1fTfm/1000297991.png',
            'title': 'the nature',
          },
        ],
        legacySingle: 'https://i.ibb.co/SXwx23C7/1000296865.png',
      );
      expect(e.map((w) => w.title).toList(), ['Boy', 'Grills', 'the nature']);
    });
  });
}
