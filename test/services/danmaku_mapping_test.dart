import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/services/database_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('R5：手动匹配弹幕的映射持久化后可读取、可删除', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);

    final entryKey = DatabaseService.danmakuMappingEntryKey('v1', 1);
    expect(db.getDanmakuMapping(entryKey), isNull);

    await db.setDanmakuMapping(entryKey, {
      'episodeId': 777,
      'animeTitle': 'QA Sample',
      'episodeTitle': '第1话',
    });
    expect(db.getDanmakuMapping(entryKey)?['episodeId'], 777);
    expect(db.getDanmakuMapping(entryKey)?['animeTitle'], 'QA Sample');

    // 模拟进程重启：重新读取仍存在。
    db.resetForTest();
    await db.init();
    expect(db.getDanmakuMapping(entryKey)?['episodeId'], 777);

    await db.removeDanmakuMapping(entryKey);
    expect(db.getDanmakuMapping(entryKey), isNull);
  });

  test('R5：主进程应用远程 danmaku.map 操作', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);

    final entryKey = DatabaseService.danmakuMappingEntryKey('v2', 0);
    await db.applyRemoteOps([
      {
        'op': 'danmaku.map.set',
        'key': entryKey,
        'value': {
          'episodeId': 888,
          'animeTitle': 'QA Sample 2',
          'episodeTitle': '第2话',
        },
      },
    ]);
    expect(db.getDanmakuMapping(entryKey)?['episodeId'], 888);

    await db.applyRemoteOps([
      {'op': 'danmaku.map.remove', 'key': entryKey},
    ]);
    expect(db.getDanmakuMapping(entryKey), isNull);
  });
}
