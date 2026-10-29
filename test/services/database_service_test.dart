import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nova_play/models/history_item.dart';
import 'package:nova_play/models/video_model.dart';
import 'package:nova_play/services/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService();
    db.resetForTest();
    await db.init();
  });

  VideoModel video(String id, [String title = '测试视频']) =>
      VideoModel(id: id, title: title);

  HistoryItem history(
    String videoId, {
    int episodeIndex = 0,
    int positionSec = 60,
    DateTime? watchedAt,
  }) =>
      HistoryItem(
        videoId: videoId,
        title: '视频-$videoId',
        episodes: [
          EpisodeModel(id: 'ep_1', title: '第 1 集', url: 'https://a/1.m3u8', index: 0),
          EpisodeModel(id: 'ep_2', title: '第 2 集', url: 'https://a/2.m3u8', index: 1),
        ],
        episodeIndex: episodeIndex,
        position: Duration(seconds: positionSec),
        duration: const Duration(seconds: 1440),
        watchedAt: watchedAt ?? DateTime.now(),
      );

  group('收藏', () {
    test('添加收藏并置顶、可查询', () async {
      final db = DatabaseService();
      await db.addFavorite(video('v1'));
      await db.addFavorite(video('v2'));

      final favorites = db.getFavorites();
      expect(favorites.length, 2);
      expect(favorites.first.id, 'v2'); // 后添加的置顶
      expect(db.isFavorite('v1'), isTrue);
      expect(db.isFavorite('v404'), isFalse);
    });

    test('重复添加去重并置顶', () async {
      final db = DatabaseService();
      await db.addFavorite(video('v1'));
      await db.addFavorite(video('v2'));
      await db.addFavorite(video('v1'));

      final favorites = db.getFavorites();
      expect(favorites.length, 2);
      expect(favorites.first.id, 'v1');
    });

    test('移除收藏', () async {
      final db = DatabaseService();
      await db.addFavorite(video('v1'));
      await db.removeFavorite('v1');

      expect(db.getFavorites(), isEmpty);
      expect(db.isFavorite('v1'), isFalse);
    });
  });

  group('观看历史', () {
    test('保存并按时间倒序', () async {
      final db = DatabaseService();
      final base = DateTime(2026, 9, 29, 12);
      await db.saveHistory(history('v1', watchedAt: base));
      await db.saveHistory(history('v2', watchedAt: base.add(const Duration(hours: 1))));

      final items = db.getHistory();
      expect(items.length, 2);
      expect(items.first.videoId, 'v2'); // 更晚的在前
    });

    test('同一视频 upsert：只留一条并更新进度', () async {
      final db = DatabaseService();
      await db.saveHistory(history('v1', positionSec: 10));
      await db.saveHistory(history('v1', episodeIndex: 1, positionSec: 700));

      final items = db.getHistory();
      expect(items.length, 1);
      expect(items.first.episodeIndex, 1);
      expect(items.first.position, const Duration(seconds: 700));
    });

    test('封顶 100 条', () async {
      final db = DatabaseService();
      for (int i = 0; i < 105; i++) {
        await db.saveHistory(history('v$i'));
      }
      final items = db.getHistory();
      expect(items.length, 100);
      expect(items.any((h) => h.videoId == 'v0'), isFalse); // 最早的被淘汰
    });

    test('单条删除与全部清除', () async {
      final db = DatabaseService();
      await db.saveHistory(history('v1'));
      await db.saveHistory(history('v2'));

      await db.removeHistory('v1');
      expect(db.getHistory().map((h) => h.videoId), ['v2']);

      await db.clearHistory();
      expect(db.getHistory(), isEmpty);
    });

    test('进度计算', () {
      final item = history('v1', positionSec: 720); // 一半
      expect(item.progress, closeTo(0.5, 0.01));

      final unknown = HistoryItem(
        videoId: 'v2',
        title: 't',
        episodeIndex: 0,
        position: const Duration(seconds: 10),
        watchedAt: DateTime.now(),
      );
      expect(unknown.progress, 0.0); // 时长未知
    });
  });

  group('搜索历史', () {
    test('去重置顶、封顶 20 条', () async {
      final db = DatabaseService();
      for (int i = 0; i < 25; i++) {
        await db.addSearchHistory('关键词$i');
      }
      await db.addSearchHistory('关键词24'); // 已存在，应置顶而非重复

      final list = db.getSearchHistory();
      expect(list.length, 20);
      expect(list.first, '关键词24');
      expect(db.getSearchHistory().where((e) => e == '关键词24').length, 1);
    });

    test('清除', () async {
      final db = DatabaseService();
      await db.addSearchHistory('abc');
      await db.clearSearchHistory();
      expect(db.getSearchHistory(), isEmpty);
    });
  });

  group('主题模式', () {
    test('默认跟随系统，写入后可读回', () async {
      final db = DatabaseService();
      expect(db.getThemeMode(), 0);

      await db.setThemeMode(1);
      expect(db.getThemeMode(), 1);

      await db.setThemeMode(2);
      expect(db.getThemeMode(), 2);
    });

    test('兼容旧 dark_mode 键：true 视为深色', () async {
      await SharedPreferences.getInstance()
          .then((p) => p.setBool('dark_mode', true));
      final db = DatabaseService();
      db.resetForTest();
      await db.init();
      expect(db.getThemeMode(), 2);
    });

    test('越界值收敛到 0-2', () async {
      final db = DatabaseService();
      await db.setThemeMode(9);
      expect(db.getThemeMode(), 2);
    });
  });
}
