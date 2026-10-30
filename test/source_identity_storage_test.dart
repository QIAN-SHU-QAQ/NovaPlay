import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/models/history_item.dart';
import 'package:nova_play/models/video_model.dart';
import 'package:nova_play/services/database_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('旧主源 ID 与备用源同号 ID 在收藏和历史中独立保存', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    for (final id in ['42', '360zy:42']) {
      await db.addFavorite(VideoModel(id: id, title: id));
      await db.saveHistory(
        HistoryItem(
          videoId: id,
          title: id,
          episodeIndex: 0,
          position: const Duration(seconds: 60),
          watchedAt: DateTime(2026, 10, 29),
        ),
      );
    }
    db.resetForTest();
    await db.init();
    expect(db.getFavorites().map((v) => v.id).toSet(), {'42', '360zy:42'});
    expect(db.getHistory().map((v) => v.videoId).toSet(), {'42', '360zy:42'});
    await db.removeFavorite('360zy:42');
    await db.removeHistory('360zy:42');
    expect(db.getFavorites().single.id, '42');
    expect(db.getHistory().single.videoId, '42');
  });
}
