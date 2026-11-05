import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/models/history_item.dart';
import 'package:nova_play/models/video_model.dart';
import 'package:nova_play/services/database_service.dart';
import 'package:nova_play/services/prefs_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

HistoryItem _history(
  String videoId,
  int seconds, {
  required DateTime watchedAt,
  List<EpisodeModel> episodes = const [],
}) {
  return HistoryItem(
    videoId: videoId,
    title: 'QA Sample $videoId',
    episodeIndex: 0,
    position: Duration(seconds: seconds),
    watchedAt: watchedAt,
    episodes: episodes,
  );
}

Future<int> _deadPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<Map<String, dynamic>> _rawRequest(
  int port,
  Map<String, Object?> payload,
) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  socket.write(jsonEncode(payload));
  socket.write('\n');
  await socket.flush();
  final line =
      await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
  socket.destroy();
  return (jsonDecode(line) as Map).cast<String, dynamic>();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('P1：201+ 条离线操作恢复连接后按批排空，不再永久卡死', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_batch_');
    final endpoint = File(
      '${tempDir.path}${Platform.pathSeparator}bridge_endpoint.json',
    );
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    db.attachBridge(
      PrefsBridgeClient(await _deadPort(), endpointFile: endpoint),
      journalDir: tempDir,
    );
    for (var i = 0; i < 201; i++) {
      await db.addSearchHistory('q$i');
    }
    expect(db.pendingOps.length, 201);

    final batchSizes = <int>[];
    PrefsBridgeServer? server;
    server = await PrefsBridgeServer.start(
      onSet: (key, value) => db.applyRemoteSet(key, value),
      onRemove: (key) => db.applyRemoteSet(key, null),
      onOps: (ops) async {
        batchSizes.add(ops.length);
        expect(
          ops.length,
          lessThanOrEqualTo(DatabaseService.maxOpsPerBatch),
          reason: '单批条数必须低于服务端上限',
        );
        final bytes =
            utf8
                .encode(jsonEncode({'ops': ops, 'session': server?.session}))
                .length;
        expect(
          bytes,
          lessThanOrEqualTo(PrefsBridgeServer.maxPayloadBytes),
          reason: '单批请求必须低于服务端字节上限',
        );
        return db.applyRemoteOps(ops);
      },
      validatePayload: (payload) async => db.validateRemotePayload(payload),
      endpointFile: endpoint,
    );
    addTearDown(() async {
      db.resetForTest();
      await server?.dispose();
    });

    await db.flushPendingOpsForTest();

    expect(db.pendingOps, isEmpty);
    expect(batchSizes.fold<int>(0, (sum, size) => sum + size), 201);
    expect(batchSizes.length, greaterThan(1));
    expect(db.getSearchHistory().length, lessThanOrEqualTo(20));
  });

  test('P1：大快照操作按字节切批后也能排空', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_big_');
    final endpoint = File(
      '${tempDir.path}${Platform.pathSeparator}bridge_endpoint.json',
    );
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    db.attachBridge(
      PrefsBridgeClient(await _deadPort(), endpointFile: endpoint),
      journalDir: tempDir,
    );
    final episodes = List.generate(
      400,
      (i) => EpisodeModel(
        id: 'ep$i',
        title: '第 $i 集',
        url: 'https://cdn.test/ep$i.m3u8',
      ),
    );
    for (var i = 0; i < 12; i++) {
      await db.saveHistory(
        _history(
          'v$i',
          10 + i,
          watchedAt: DateTime(2026, 11, 5, 0, 0, i),
          episodes: episodes,
        ),
      );
    }
    expect(db.pendingOps.length, 12);

    final batchSizes = <int>[];
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) => db.applyRemoteSet(key, value),
      onRemove: (key) => db.applyRemoteSet(key, null),
      onOps: (ops) async {
        batchSizes.add(ops.length);
        return db.applyRemoteOps(ops);
      },
      validatePayload: (payload) async => db.validateRemotePayload(payload),
      endpointFile: endpoint,
    );
    addTearDown(() async {
      db.resetForTest();
      await server?.dispose();
    });

    await db.flushPendingOpsForTest();

    expect(db.pendingOps, isEmpty);
    expect(batchSizes.length, greaterThan(1));
    expect(db.getHistory().length, 12);
  });

  test('P1：并发离线写入后 journal 仍有完整可恢复快照', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_concurrent_');
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    db.attachBridge(PrefsBridgeClient(await _deadPort()), journalDir: tempDir);
    await Future.wait(
      List.generate(30, (i) => db.addSearchHistory('concurrent-$i')),
    );
    expect(db.pendingOps.length, 30);

    final journal = File(
      '${tempDir.path}${Platform.pathSeparator}pending_ops.$pid.json',
    );
    expect(journal.existsSync(), isTrue, reason: '并发写入后必须保留完整日志');
    final saved = jsonDecode(journal.readAsStringSync()) as List;
    expect(saved.length, 30);

    // 模拟主进程启动回放：日志必须能被完整恢复并清空。
    db.resetForTest();
    await db.init();
    db.setJournalDirectory(tempDir);
    await db.flushPendingJournals();
    expect(db.getSearchHistory().length, greaterThan(0));
    expect(
      tempDir.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.json') || f.path.endsWith('.processing'),
      ),
      isEmpty,
    );
  });

  test('P1：旧删除操作重试不会删除更新的观看记录', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);

    final t0 = DateTime(2026, 11, 5, 8, 0, 0);
    final t1 = t0.add(const Duration(seconds: 1));
    final t2 = t0.add(const Duration(seconds: 2));
    await db.applyRemoteOps([
      {
        'op': 'history.upsert',
        'opId': 'upsert-old',
        'item': _history('v1', 10, watchedAt: t0).toJson(),
      },
    ]);
    await db.applyRemoteOps([
      {
        'op': 'history.remove',
        'opId': 'delete-1',
        'videoId': 'v1',
        'at': t1.toIso8601String(),
      },
    ]);
    await db.applyRemoteOps([
      {
        'op': 'history.upsert',
        'opId': 'upsert-new',
        'item': _history('v1', 30, watchedAt: t2).toJson(),
      },
    ]);

    // 同一 opId 重试：去重后不再写。
    await db.applyRemoteOps([
      {
        'op': 'history.remove',
        'opId': 'delete-1',
        'videoId': 'v1',
        'at': t1.toIso8601String(),
      },
    ]);
    // 不同 opId 但同样旧的删除：版本判断必须拒绝。
    await db.applyRemoteOps([
      {
        'op': 'history.remove',
        'opId': 'delete-stale',
        'videoId': 'v1',
        'at': t1.toIso8601String(),
      },
    ]);

    expect(db.getHistory().single.position, const Duration(seconds: 30));

    // 真正更新的删除仍然生效。
    await db.applyRemoteOps([
      {
        'op': 'history.remove',
        'opId': 'delete-new',
        'videoId': 'v1',
        'at': t2.add(const Duration(seconds: 1)).toIso8601String(),
      },
    ]);
    expect(db.getHistory(), isEmpty);
  });

  test('P2：畸形操作在首次写入前整批拒绝，存储不变', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) => db.applyRemoteSet(key, value),
      onRemove: (key) => db.applyRemoteSet(key, null),
      onOps: (ops) => db.applyRemoteOps(ops),
      validatePayload: (payload) async => db.validateRemotePayload(payload),
    );
    addTearDown(() async {
      db.resetForTest();
      await server?.dispose();
    });

    Future<Map<String, dynamic>> send(Map<String, Object?> payload) =>
        _rawRequest(server!.port, {...payload, 'session': server.session});

    final badHistory = {
      'op': 'history.upsert',
      'item': {
        'videoId': 'v1',
        'title': 'QA',
        'episodeIndex': 0,
        'positionMs': 'bad',
        'watchedAt': DateTime(2026, 11, 5).toIso8601String(),
      },
    };
    var reply = await send({
      'ops': [
        {'op': 'set', 'key': 'auto_play', 'value': false},
        badHistory,
      ],
    });
    expect(reply['ok'], isFalse);
    expect(reply['error'], 'bad_item');
    expect(db.getAutoPlay(), isTrue, reason: '整批预检失败时不得先写入合法部分');
    expect(db.getHistory(), isEmpty);

    reply = await send({
      'set': {'auto_play': 'wrong'},
    });
    expect(reply['ok'], isFalse);
    expect(reply['error'], 'bad_value');
    expect(db.getAutoPlay(), isTrue);

    reply = await send({
      'set': {'playback_speed': 'fast'},
    });
    expect(reply['ok'], isFalse);
    expect(db.getPlaybackSpeed(), 1.0);
  });

  test('P2：清空历史后尚未送达的旧离线记录不会复活', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);

    // 主窗口在 T+1 清空历史（本地主进程路径）。
    final clearedAt = DateTime.now();
    await db.clearHistory();
    expect(db.getHistory(), isEmpty);

    // 旧播放器在 T 时刻产生、尚未送达的记录。
    await db.applyRemoteOps([
      {
        'op': 'history.upsert',
        'opId': 'offline-old',
        'item':
            _history(
              'v1',
              10,
              watchedAt: clearedAt.subtract(const Duration(seconds: 5)),
            ).toJson(),
      },
    ]);
    expect(db.getHistory(), isEmpty, reason: '早于清空水位的旧记录不能出现');

    // 清空之后真实产生的新观看仍然保存。
    await db.applyRemoteOps([
      {
        'op': 'history.upsert',
        'opId': 'offline-new',
        'item':
            _history(
              'v2',
              20,
              watchedAt: clearedAt.add(const Duration(seconds: 5)),
            ).toJson(),
      },
    ]);
    expect(db.getHistory().single.videoId, 'v2');
  });

  test('P2：重复送达同一 opId 不会重复插入或覆盖', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);

    final item = _history('v1', 20, watchedAt: DateTime(2026, 11, 5, 8, 0, 0));
    final op = {
      'op': 'history.upsert',
      'opId': 'same-op',
      'item': item.toJson(),
    };
    await db.applyRemoteOps([op]);
    await db.applyRemoteOps([op]);
    expect(db.getHistory().length, 1);

    final favoriteOp = {
      'op': 'favorites.add',
      'opId': 'favorite-op',
      'item': VideoModel(id: 'v1', title: 'QA').toJson(),
    };
    await db.applyRemoteOps([favoriteOp]);
    await db.applyRemoteOps([favoriteOp]);
    expect(db.getFavorites().length, 1);
  });

  test('R6：danmaku.map 操作在协议白名单内，畸形值整批拒绝', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) => db.applyRemoteSet(key, value),
      onRemove: (key) => db.applyRemoteSet(key, null),
      onOps: (ops) => db.applyRemoteOps(ops),
      validatePayload: (payload) async => db.validateRemotePayload(payload),
    );
    addTearDown(() async {
      db.resetForTest();
      await server?.dispose();
    });

    Future<Map<String, dynamic>> send(Map<String, Object?> payload) =>
        _rawRequest(server!.port, {...payload, 'session': server.session});

    const entryKey = 'v1||ep2';
    var reply = await send({
      'ops': [
        {
          'op': 'danmaku.map.set',
          'key': entryKey,
          'value': {
            'episodeId': 777,
            'animeTitle': 'QA',
            'episodeTitle': '第2话',
          },
        },
      ],
    });
    expect(reply['ok'], isTrue);
    expect(db.getDanmakuMapping(entryKey)?['episodeId'], 777);

    // 畸形 value 必须在写入前整批拒绝。
    reply = await send({
      'ops': [
        {'op': 'danmaku.map.set', 'key': entryKey, 'value': 'not-a-map'},
      ],
    });
    expect(reply['ok'], isFalse);
    expect(reply['error'], 'bad_item');
    expect(db.getDanmakuMapping(entryKey)?['episodeId'], 777);

    reply = await send({
      'ops': [
        {'op': 'danmaku.map.remove', 'key': entryKey},
      ],
    });
    expect(reply['ok'], isTrue);
    expect(db.getDanmakuMapping(entryKey), isNull);
  });

  test('P1：单条超限操作不阻塞后续写入，数据保留并可回放', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_oversized_');
    final endpoint = File(
      '${tempDir.path}${Platform.pathSeparator}bridge_endpoint.json',
    );
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    db.attachBridge(
      PrefsBridgeClient(await _deadPort(), endpointFile: endpoint),
      journalDir: tempDir,
    );

    // 约 700KB 的合法历史快照：超过单条协议上限，无法经桥发送。
    final bigEpisodes = List.generate(
      2000,
      (i) => EpisodeModel(
        id: 'ep_$i',
        title: '第 $i 集',
        url: 'https://cdn.test/${List.filled(250, 'x').join()}/$i.m3u8',
      ),
    );
    await db.saveHistory(
      _history(
        'big',
        10,
        watchedAt: DateTime(2026, 11, 5, 9, 0, 0),
        episodes: bigEpisodes,
      ),
    );
    // 后续普通写入不能被超大操作堵住。
    await db.addSearchHistory('after-oversized');

    final receivedSearch = <String>[];
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) => db.applyRemoteSet(key, value),
      onRemove: (key) => db.applyRemoteSet(key, null),
      onOps: (ops) async {
        for (final op in ops) {
          if (op['op'] == 'search.upsert') {
            receivedSearch.add(op['query'] as String);
          }
        }
        return db.applyRemoteOps(ops);
      },
      validatePayload: (payload) async => db.validateRemotePayload(payload),
      endpointFile: endpoint,
    );
    addTearDown(() async {
      db.resetForTest();
      await server?.dispose();
    });

    await db.flushPendingOpsForTest();

    expect(db.oversizedOps, hasLength(1), reason: '超限操作必须被隔离保留');
    expect(db.pendingOps, isEmpty);
    expect(db.lastSyncError, isNotNull, reason: '错误必须可见，不能静默丢弃');
    expect(receivedSearch, contains('after-oversized'));
    expect(db.getSearchHistory(), contains('after-oversized'));
    expect(
      tempDir.listSync().whereType<File>().any(
        (file) => file.path.endsWith('.oversized.json'),
      ),
      isTrue,
      reason: '超限操作必须写入独立日志',
    );

    // 模拟主进程启动回放：超大操作在本地应用，不丢数据。
    db.resetForTest();
    await db.init();
    db.setJournalDirectory(tempDir);
    await db.flushPendingJournals();
    expect(db.getHistory().any((item) => item.videoId == 'big'), isTrue);
    expect(
      tempDir.listSync().whereType<File>().where(
        (file) => file.path.contains('oversized'),
      ),
      isEmpty,
    );
  });

  test('P1：旧 clear 重放/回放不会删除清空后的新观看', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_clear_replay_');
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final t0 = DateTime(2026, 11, 5, 10, 0, 0);
    final clearAt = t0.add(const Duration(seconds: 1));
    await db.applyRemoteOps([
      {
        'op': 'history.upsert',
        'opId': 'upsert-old',
        'item': _history('v1', 10, watchedAt: t0).toJson(),
      },
    ]);
    await db.applyRemoteOps([
      {
        'op': 'history.clear',
        'opId': 'clear-1',
        'at': clearAt.toIso8601String(),
      },
    ]);
    expect(db.getHistory(), isEmpty);

    final newer = _history(
      'v2',
      20,
      watchedAt: t0.add(const Duration(seconds: 2)),
    );
    await db.applyRemoteOps([
      {'op': 'history.upsert', 'opId': 'upsert-new', 'item': newer.toJson()},
    ]);
    expect(db.getHistory().single.videoId, 'v2');

    // 模拟主进程重启（内存去重状态清空），重送同一个旧 clear。
    db.resetForTest();
    await db.init();
    await db.applyRemoteOps([
      {
        'op': 'history.clear',
        'opId': 'clear-1',
        'at': clearAt.toIso8601String(),
      },
    ]);
    expect(db.getHistory().single.videoId, 'v2', reason: '旧 clear 不能撤销清空之后的观看');

    // journal 回放的旧 clear 同样要保留新观看。
    db.resetForTest();
    await db.init();
    db.setJournalDirectory(tempDir);
    final journal = File(
      '${tempDir.path}${Platform.pathSeparator}pending_ops.888.json',
    );
    await journal.writeAsString(
      jsonEncode([
        {
          'op': 'history.clear',
          'opId': 'clear-1',
          'at': clearAt.toIso8601String(),
        },
      ]),
    );
    await db.flushPendingJournals();
    expect(db.getHistory().single.videoId, 'v2');
  });

  test('P1：旧收藏 add 晚到不会复活已取消的收藏', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);

    final t0 = DateTime(2026, 11, 5, 12, 0, 0);
    final addOp = {
      'op': 'favorites.add',
      'opId': 'fav-add-old',
      'at': t0.toIso8601String(),
      'item': VideoModel(id: 'v1', title: 'QA').toJson(),
    };
    await db.applyRemoteOps([addOp]);
    expect(db.getFavorites().single.id, 'v1');

    await db.applyRemoteOps([
      {
        'op': 'favorites.remove',
        'opId': 'fav-remove-new',
        'at': t0.add(const Duration(seconds: 1)).toIso8601String(),
        'videoId': 'v1',
      },
    ]);
    expect(db.getFavorites(), isEmpty);

    // 旧 add 重试/回放：不能复活。
    await db.applyRemoteOps([addOp]);
    expect(db.getFavorites(), isEmpty);

    // 更晚的重新收藏仍然有效。
    await db.applyRemoteOps([
      {
        'op': 'favorites.add',
        'opId': 'fav-add-new',
        'at': t0.add(const Duration(seconds: 2)).toIso8601String(),
        'item': VideoModel(id: 'v1', title: 'QA').toJson(),
      },
    ]);
    expect(db.getFavorites().single.id, 'v1');
  });

  test('P1：旧取消收藏重放不会删除后来重新收藏的记录', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_fav_remove_');
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final t0 = DateTime(2026, 11, 5, 13, 0, 0);
    final t1 = t0.add(const Duration(seconds: 1));
    final t2 = t0.add(const Duration(seconds: 2));
    final addOp = {
      'op': 'favorites.add',
      'opId': 'fav-add-1',
      'at': t0.toIso8601String(),
      'item': VideoModel(id: 'v1', title: 'QA').toJson(),
    };
    final removeOp = {
      'op': 'favorites.remove',
      'opId': 'stable-remove',
      'at': t1.toIso8601String(),
      'videoId': 'v1',
    };
    await db.applyRemoteOps([addOp]);
    await db.applyRemoteOps([removeOp]);
    await db.applyRemoteOps([
      {
        'op': 'favorites.add',
        'opId': 'fav-add-2',
        'at': t2.toIso8601String(),
        'item': VideoModel(id: 'v1', title: 'QA').toJson(),
      },
    ]);
    expect(db.getFavorites().single.id, 'v1');

    // 模拟主进程重启：清掉内存 opId 去重状态，重放同一个旧 remove。
    db.resetForTest();
    await db.init();
    await db.applyRemoteOps([removeOp]);
    expect(db.getFavorites().single.id, 'v1', reason: '旧 remove 不能删除之后重新收藏的记录');

    // journal 回放旧的 remove 同样不能删除较新重新收藏。
    db.resetForTest();
    await db.init();
    db.setJournalDirectory(tempDir);
    final journal = File(
      '${tempDir.path}${Platform.pathSeparator}pending_ops.999.json',
    );
    await journal.writeAsString(jsonEncode([removeOp]));
    await db.flushPendingJournals();
    expect(db.getFavorites().single.id, 'v1');

    // 真正更晚的取消收藏仍然生效。
    await db.applyRemoteOps([
      {
        'op': 'favorites.remove',
        'opId': 'remove-newer',
        'at': t2.add(const Duration(seconds: 1)).toIso8601String(),
        'videoId': 'v1',
      },
    ]);
    expect(db.getFavorites(), isEmpty);
  });

  test('P1：版本表淘汰后，旧取消回放仍不能删除活跃收藏', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_fav_evict_');
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final base = DateTime(2026, 11, 5, 18, 0, 0);
    // 预置 500 个其他收藏，占满版本表。
    final others = <String>[];
    for (var i = 0; i < 500; i++) {
      final id = 'other-$i';
      others.add(id);
      await db.applyRemoteOps([
        {
          'op': 'favorites.add',
          'opId': 'seed-$i',
          'at':
              base
                  .subtract(const Duration(minutes: 10))
                  .add(Duration(milliseconds: i))
                  .toIso8601String(),
          'item': VideoModel(id: id, title: 'Other $i').toJson(),
        },
      ]);
    }

    final t0 = base;
    final t1 = base.add(const Duration(seconds: 1));
    final t2 = base.add(const Duration(seconds: 2));
    final addOp = {
      'op': 'favorites.add',
      'opId': 'target-add-1',
      'at': t0.toIso8601String(),
      'item': VideoModel(id: 'target', title: 'Target').toJson(),
    };
    final removeOp = {
      'op': 'favorites.remove',
      'opId': 'target-remove-old',
      'at': t1.toIso8601String(),
      'videoId': 'target',
    };
    await db.applyRemoteOps([addOp]);
    await db.applyRemoteOps([removeOp]);
    await db.applyRemoteOps([
      {
        'op': 'favorites.add',
        'opId': 'target-add-2',
        'at': t2.toIso8601String(),
        'item': VideoModel(id: 'target', title: 'Target').toJson(),
      },
    ]);
    expect(db.getFavorites().map((v) => v.id), contains('target'));

    // 逐个取消其他 500 个收藏：这些更新的 remove 会把 target 的版本挤出前 500。
    for (var i = 0; i < 500; i++) {
      await db.applyRemoteOps([
        {
          'op': 'favorites.remove',
          'opId': 'remove-other-$i',
          'at':
              t2
                  .add(const Duration(seconds: 1))
                  .add(Duration(milliseconds: i))
                  .toIso8601String(),
          'videoId': others[i],
        },
      ]);
    }
    expect(db.getFavorites().map((v) => v.id), ['target']);

    // 模拟重启：回放旧的 remove（保留其日志）不能删除活跃收藏。
    db.resetForTest();
    await db.init();
    db.setJournalDirectory(tempDir);
    final journal = File(
      '${tempDir.path}${Platform.pathSeparator}pending_ops.501.json',
    );
    await journal.writeAsString(jsonEncode([removeOp]));
    await db.flushPendingJournals();
    expect(db.getFavorites().map((v) => v.id), [
      'target',
    ], reason: '活跃收藏的最后版本不能被 500 条上限淘汰');

    // 真正更晚的 remove 仍能生效。
    await db.applyRemoteOps([
      {
        'op': 'favorites.remove',
        'opId': 'target-remove-new',
        'at': t2.add(const Duration(minutes: 1)).toIso8601String(),
        'videoId': 'target',
      },
    ]);
    expect(db.getFavorites(), isEmpty);
  });

  test('P1：删除标记淘汰后，普通日志旧 add 不能复活已取消收藏', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_tomb_normal_');
    final endpoint = File(
      '${tempDir.path}${Platform.pathSeparator}bridge_endpoint.json',
    );
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    db.setJournalDirectory(tempDir);
    db.attachBridge(
      PrefsBridgeClient(await _deadPort(), endpointFile: endpoint),
      journalDir: tempDir,
    );
    // 离线写入目标收藏：普通日志中保留旧 favorites.add。
    await db.addFavorite(VideoModel(id: 'target', title: 'Target'));
    db.detachBridge();
    db.setJournalDirectory(tempDir);
    expect(
      tempDir.listSync().whereType<File>().any(
        (file) => file.path.contains('pending_ops.'),
      ),
      isTrue,
    );

    final base = DateTime.now();
    for (var i = 0; i < 500; i++) {
      await db.applyRemoteOps([
        {
          'op': 'favorites.add',
          'opId': 'seed-$i',
          'at':
              base
                  .subtract(const Duration(minutes: 10))
                  .add(Duration(milliseconds: i))
                  .toIso8601String(),
          'item': VideoModel(id: 'other-$i', title: 'Other $i').toJson(),
        },
      ]);
    }
    // 取消目标收藏后，再取消另外 500 个作品把删除标记挤出前 500。
    await db.applyRemoteOps([
      {
        'op': 'favorites.remove',
        'opId': 'rm-target',
        'at': base.add(const Duration(minutes: 1)).toIso8601String(),
        'videoId': 'target',
      },
    ]);
    for (var i = 0; i < 500; i++) {
      await db.applyRemoteOps([
        {
          'op': 'favorites.remove',
          'opId': 'rm-other-$i',
          'at':
              base
                  .add(const Duration(minutes: 2))
                  .add(Duration(milliseconds: i))
                  .toIso8601String(),
          'videoId': 'other-$i',
        },
      ]);
    }
    expect(db.getFavorites(), isEmpty);

    // 重启回放普通日志：旧 add 不能复活已取消的收藏。
    db.resetForTest();
    await db.init();
    db.setJournalDirectory(tempDir);
    await db.flushPendingJournals();
    expect(db.getFavorites(), isEmpty);
  });

  test('P1：删除标记淘汰后，超大日志旧 add 不能复活已取消收藏', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_tomb_big_');
    final endpoint = File(
      '${tempDir.path}${Platform.pathSeparator}bridge_endpoint.json',
    );
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    db.setJournalDirectory(tempDir);
    db.attachBridge(
      PrefsBridgeClient(await _deadPort(), endpointFile: endpoint),
      journalDir: tempDir,
    );
    final bigEpisodes = List.generate(
      2000,
      (i) => EpisodeModel(
        id: 'ep_$i',
        title: '第 $i 集',
        url: 'https://cdn.test/${List.filled(250, 'x').join()}/$i.m3u8',
      ),
    );
    await db.addFavorite(
      VideoModel(id: 'target', title: 'Target', episodes: bigEpisodes),
    );
    expect(db.oversizedOps, hasLength(1));
    db.detachBridge();
    db.setJournalDirectory(tempDir);

    final base = DateTime.now();
    for (var i = 0; i < 500; i++) {
      await db.applyRemoteOps([
        {
          'op': 'favorites.add',
          'opId': 'seed-$i',
          'at':
              base
                  .subtract(const Duration(minutes: 10))
                  .add(Duration(milliseconds: i))
                  .toIso8601String(),
          'item': VideoModel(id: 'other-$i', title: 'Other $i').toJson(),
        },
      ]);
    }
    await db.applyRemoteOps([
      {
        'op': 'favorites.remove',
        'opId': 'rm-target',
        'at': base.add(const Duration(minutes: 1)).toIso8601String(),
        'videoId': 'target',
      },
    ]);
    for (var i = 0; i < 500; i++) {
      await db.applyRemoteOps([
        {
          'op': 'favorites.remove',
          'opId': 'rm-other-$i',
          'at':
              base
                  .add(const Duration(minutes: 2))
                  .add(Duration(milliseconds: i))
                  .toIso8601String(),
          'videoId': 'other-$i',
        },
      ]);
    }
    expect(db.getFavorites(), isEmpty);

    db.resetForTest();
    await db.init();
    db.setJournalDirectory(tempDir);
    await db.flushPendingJournals();
    expect(db.getFavorites(), isEmpty);
  });

  test('P1：超限收藏 add 在已确认 remove 之后回放不复活', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_fav_order_');
    final endpoint = File(
      '${tempDir.path}${Platform.pathSeparator}bridge_endpoint.json',
    );
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    db.attachBridge(
      PrefsBridgeClient(await _deadPort(), endpointFile: endpoint),
      journalDir: tempDir,
    );

    // 约 700KB 的收藏快照，会被移入超大操作日志。
    final bigEpisodes = List.generate(
      2000,
      (i) => EpisodeModel(
        id: 'ep_$i',
        title: '第 $i 集',
        url: 'https://cdn.test/${List.filled(250, 'x').join()}/$i.m3u8',
      ),
    );
    final bigFavorite = VideoModel(
      id: 'big-fav',
      title: 'QA Big Favorite',
      episodes: bigEpisodes,
    );
    await db.addFavorite(bigFavorite);
    expect(db.oversizedOps, hasLength(1));

    // 主窗口恢复：取消收藏被正常确认，普通队列排空、收藏为空。
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) => db.applyRemoteSet(key, value),
      onRemove: (key) => db.applyRemoteSet(key, null),
      onOps: (ops) => db.applyRemoteOps(ops),
      validatePayload: (payload) async => db.validateRemotePayload(payload),
      endpointFile: endpoint,
    );
    addTearDown(() async {
      db.resetForTest();
      await server?.dispose();
    });

    await db.removeFavorite('big-fav');
    await db.flushPendingOpsForTest();
    expect(db.pendingOps, isEmpty);
    expect(db.getFavorites(), isEmpty);

    // 模拟主窗口重启：回放超大操作日志（旧 favorites.add）不能复活收藏。
    db.resetForTest();
    await db.init();
    db.setJournalDirectory(tempDir);
    await db.flushPendingJournals();
    expect(db.getFavorites(), isEmpty, reason: '旧 add 不能覆盖较新的 remove');
    expect(
      tempDir.listSync().whereType<File>().where(
        (file) => file.path.contains('oversized'),
      ),
      isEmpty,
    );
  });

  test('P2：数值设置被接受后必须能被对应 getter 读取', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) => db.applyRemoteSet(key, value),
      onRemove: (key) => db.applyRemoteSet(key, null),
      onOps: (ops) => db.applyRemoteOps(ops),
      validatePayload: (payload) async => db.validateRemotePayload(payload),
    );
    addTearDown(() async {
      db.resetForTest();
      await server?.dispose();
    });

    Future<Map<String, dynamic>> send(Map<String, Object?> payload) =>
        _rawRequest(server!.port, {...payload, 'session': server.session});

    final reply = await send({
      'ops': [
        {'op': 'set', 'key': 'playback_speed', 'value': 2},
        {'op': 'set', 'key': 'danmaku_opacity', 'value': 1},
        {'op': 'set', 'key': 'danmaku_font_size', 'value': 16},
        {'op': 'set', 'key': 'danmaku_area', 'value': 1},
      ],
    });
    expect(reply['ok'], isTrue);

    // 被接受的数据必须能被 getter 正常读取（JSON 整数会解析成 int）。
    expect(db.getPlaybackSpeed(), 2.0);
    expect(db.getDanmakuOpacity(), 1.0);
    expect(db.getDanmakuFontSize(), 16.0);
    expect(db.getDanmakuArea(), 1.0);
  });
}
