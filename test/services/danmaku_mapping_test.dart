import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/services/database_service.dart';
import 'package:nova_play/services/prefs_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('R5：手动匹配弹幕的映射持久化后可读取、可删除', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);

    final entryKey = DatabaseService.danmakuMappingEntryKey('v1', 'ep-1');
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

    final entryKey = DatabaseService.danmakuMappingEntryKey('v2', 'ep-2');
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

  test('R5：桥写入后本进程立即读到手选/解除状态', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_map_cache_');
    final endpoint = File(
      '${tempDir.path}${Platform.pathSeparator}bridge_endpoint.json',
    );
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final receivedOps = <Map<String, dynamic>>[];
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) async {},
      onRemove: (key) async {},
      onOps: (ops) async {
        receivedOps.addAll(ops);
        return const <String>[];
      },
      validatePayload: (payload) async => db.validateRemotePayload(payload),
      endpointFile: endpoint,
    );
    addTearDown(() async {
      db.resetForTest();
      await server?.dispose();
    });
    db.attachBridge(
      PrefsBridgeClient(server!.port, endpointFile: endpoint),
      journalDir: tempDir,
    );

    final entryKey = DatabaseService.danmakuMappingEntryKey('v1', 'ep2');
    expect(db.getDanmakuMapping(entryKey), isNull);

    await db.setDanmakuMapping(entryKey, {
      'episodeId': 777,
      'animeTitle': 'QA Sample',
      'episodeTitle': '第2话',
    });
    // 不重启播放器、不重新读盘，立即能读到新关联。
    expect(db.getDanmakuMapping(entryKey)?['episodeId'], 777);
    expect(receivedOps.map((op) => op['op']), contains('danmaku.map.set'));

    await db.removeDanmakuMapping(entryKey);
    // 解除后立即读不到旧关联（启动时的 prefs 快照里可能仍有旧值）。
    expect(db.getDanmakuMapping(entryKey), isNull);
    expect(receivedOps.map((op) => op['op']), contains('danmaku.map.remove'));
  });

  test('R5：剧集重排后按稳定剧集身份命中，不再依赖列表位置', () {
    final reorderedKeys = [
      DatabaseService.danmakuMappingEntryKey('v1', 'ep2'),
      DatabaseService.danmakuMappingEntryKey('v1', 'ep1'),
    ];
    expect(
      reorderedKeys.first,
      DatabaseService.danmakuMappingEntryKey('v1', 'ep2'),
    );
    expect(reorderedKeys.first, isNot(reorderedKeys.last));
  });

  test('R7：手动资料关联按完整视频 ID 隔离，同名作品互不影响', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);

    await db.setBangumiMapping('old-1', {'subjectId': 11, 'name': 'QA 样本（旧作）'});
    expect(db.getBangumiMapping('old-1')?['subjectId'], 11);
    // 同名重制版有不同视频 ID，不能读到旧作的关联。
    expect(db.getBangumiMapping('remake-2'), isNull);

    // 旧版本（未发布）留下的标题键数据不会被当作用户 ID 的关联使用。
    SharedPreferences.setMockInitialValues({
      'bangumi_subject_map_v1': jsonEncode({
        'QA 样本': {'subjectId': 11, 'name': 'QA 样本'},
      }),
    });
    db.resetForTest();
    await db.init();
    expect(db.getBangumiMapping('legacy-video-id'), isNull);
  });
}
