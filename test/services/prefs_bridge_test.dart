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
  String title,
  int seconds, {
  DateTime? watchedAt,
}) {
  return HistoryItem(
    videoId: videoId,
    title: title,
    episodeIndex: 0,
    position: Duration(seconds: seconds),
    watchedAt: watchedAt ?? DateTime(2026, 11, 4, 12, 0, 0),
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

  test('R6：缺少 session 的请求被拒绝且不写入', () async {
    var written = false;
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) async => written = true,
      onRemove: (key) async => written = true,
      onOps: (ops) async {
        written = true;
        return const <String>[];
      },
      validatePayload: (payload) async => null,
    );
    addTearDown(() => server!.dispose());
    final reply = await _rawRequest(server!.port, {
      'set': {'auto_play': false},
    });
    expect(reply['ok'], isFalse);
    expect(reply['error'], 'session_required');
    expect(written, isFalse);
  });

  test('R6：错误/空/非字符串 session 被拒绝，正确 session 可写入', () async {
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) async {},
      onRemove: (key) async {},
      onOps: (ops) async => const <String>[],
      validatePayload: (payload) async => null,
    );
    final bridge = server!;
    addTearDown(() => bridge.dispose());

    for (final badSession in ['wrong-token', '', 123]) {
      final reply = await _rawRequest(bridge.port, {
        'set': {'auto_play': false},
        'session': badSession,
      });
      expect(reply['ok'], isFalse, reason: 'session=$badSession');
      expect(reply['error'], 'session_required');
    }

    final okReply = await _rawRequest(bridge.port, {
      'set': {'auto_play': false},
      'session': bridge.session,
    });
    expect(okReply['ok'], isTrue);
  });

  test('R6：不允许的键/操作/超量请求被整批拒绝且不写入', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) => db.applyRemoteSet(key, value),
      onRemove: (key) => db.applyRemoteSet(key, null),
      onOps: (ops) => db.applyRemoteOps(ops),
      validatePayload: (payload) async => db.validateRemotePayload(payload),
    );
    addTearDown(() => server!.dispose());

    Future<Map<String, dynamic>> send(Map<String, Object?> payload) =>
        _rawRequest(server!.port, {...payload, 'session': server.session});

    // 不允许的标量键
    var reply = await send({
      'set': {'downloads_v1': '[]'},
    });
    expect(reply['ok'], isFalse);
    expect(reply['error'], 'unsupported_key');

    // 不允许的操作
    reply = await send({
      'ops': [
        {'op': 'history.truncate'},
      ],
    });
    expect(reply['ok'], isFalse);
    expect(reply['error'], 'unsupported_op');

    // 结构错误
    reply = await send({'ops': 'not-a-list'});
    expect(reply['ok'], isFalse);
    expect(reply['error'], 'bad_ops');

    // 超量操作
    reply = await send({
      'ops': [
        for (var i = 0; i <= DatabaseService.maxOpsPerRequest; i++)
          {'op': 'history.clear'},
      ],
    });
    expect(reply['ok'], isFalse);
    expect(reply['error'], 'bad_ops');

    // 数据没有被修改
    expect(db.getHistory(), isEmpty);
    expect(db.getAutoPlay(), isTrue);
  });

  test('R1：乱序到达的旧历史操作不会覆盖较新进度', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);

    final newer = _history(
      '1',
      'QA Sample 01',
      20,
      watchedAt: DateTime(2026, 11, 4, 12, 1, 0),
    );
    final older = _history(
      '1',
      'QA Sample 01',
      10,
      watchedAt: DateTime(2026, 11, 4, 12, 0, 0),
    );
    await db.applyRemoteOps([
      {'op': 'history.upsert', 'item': newer.toJson()},
    ]);
    await db.applyRemoteOps([
      {'op': 'history.upsert', 'item': older.toJson()},
    ]);
    expect(db.getHistory().single.position, const Duration(seconds: 20));

    // 用户主动回退到 5 秒：watchedAt 更新，允许覆盖。
    final seekBack = _history(
      '1',
      'QA Sample 01',
      5,
      watchedAt: DateTime(2026, 11, 4, 12, 2, 0),
    );
    await db.applyRemoteOps([
      {'op': 'history.upsert', 'item': seekBack.toJson()},
    ]);
    expect(db.getHistory().single.position, const Duration(seconds: 5));
  });

  test('R1：删除后的旧日志不会复活记录，新的观看可以恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);

    final item = _history(
      '1',
      'QA Sample 01',
      10,
      watchedAt: DateTime(2026, 11, 4, 12, 0, 0),
    );
    await db.applyRemoteOps([
      {'op': 'history.upsert', 'item': item.toJson()},
    ]);
    await db.applyRemoteOps([
      {
        'op': 'history.remove',
        'videoId': '1',
        'at': DateTime(2026, 11, 4, 12, 0, 30).toIso8601String(),
      },
    ]);
    expect(db.getHistory(), isEmpty);

    // 早于删除时间的旧日志：不能复活。
    await db.applyRemoteOps([
      {'op': 'history.upsert', 'item': item.toJson()},
    ]);
    expect(db.getHistory(), isEmpty);

    // 删除之后的新观看：允许恢复。
    final afterDelete = _history(
      '1',
      'QA Sample 01',
      30,
      watchedAt: DateTime(2026, 11, 4, 12, 1, 0),
    );
    await db.applyRemoteOps([
      {'op': 'history.upsert', 'item': afterDelete.toJson()},
    ]);
    expect(db.getHistory().single.position, const Duration(seconds: 30));
  });

  test('R1：离线积压后恢复，新旧操作按队列顺序补交', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_queue_');
    final endpointFile = File(
      '${tempDir.path}${Platform.pathSeparator}bridge_endpoint.json',
    );
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    // 端点文件不存在：主窗口未运行，操作进入离线队列。
    final client = PrefsBridgeClient(
      await _deadPort(),
      endpointFile: endpointFile,
    );
    db.attachBridge(client, journalDir: tempDir);
    final offline = _history(
      '1',
      'QA Sample 01',
      10,
      watchedAt: DateTime(2026, 11, 4, 12, 0, 0),
    );
    await db.saveHistory(offline);
    expect(db.pendingOps.length, 1);
    expect(db.getHistory(), isEmpty);

    // 主窗口启动：端点文件出现；新操作加入队列，按旧→新顺序补交。
    final received = <int>[];
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) => db.applyRemoteSet(key, value),
      onRemove: (key) => db.applyRemoteSet(key, null),
      onOps: (ops) async {
        for (final op in ops) {
          final item = op['item'];
          if (item is Map) received.add(item['positionMs'] as int);
        }
        return db.applyRemoteOps(ops);
      },
      validatePayload: (payload) async => db.validateRemotePayload(payload),
      endpointFile: endpointFile,
    );
    addTearDown(() async {
      db.resetForTest();
      await server?.dispose();
    });

    final online = _history(
      '1',
      'QA Sample 01',
      20,
      watchedAt: DateTime(2026, 11, 4, 12, 1, 0),
    );
    await db.saveHistory(online);
    await db.flushPendingOpsForTest();

    expect(received, [10000, 20000], reason: '必须按旧→新顺序补交');
    expect(db.pendingOps, isEmpty);
    expect(db.getHistory().single.position, const Duration(seconds: 20));
  });

  test('R1：主进程回放离线日志时仍遵守版本规则', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_replay_');
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    // 主进程已有较新的 20 秒记录。
    await db.saveHistory(
      _history(
        '1',
        'QA Sample 01',
        20,
        watchedAt: DateTime(2026, 11, 4, 12, 1, 0),
      ),
    );

    // 模拟旧播放器留下的离线日志（10 秒，时间更早）。
    final journal = File(
      '${tempDir.path}${Platform.pathSeparator}pending_ops.999.json',
    );
    await journal.writeAsString(
      jsonEncode([
        {
          'op': 'history.upsert',
          'item':
              _history(
                '1',
                'QA Sample 01',
                10,
                watchedAt: DateTime(2026, 11, 4, 12, 0, 0),
              ).toJson(),
        },
      ]),
    );

    db.setJournalDirectory(tempDir);
    await db.flushPendingJournals();
    expect(db.getHistory().single.position, const Duration(seconds: 20));
    expect(journal.existsSync(), isFalse);
  });

  test('主窗口重启后旧播放器发现新端点并恢复实时提交', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_bridge_');
    final endpointFile = File(
      '${tempDir.path}${Platform.pathSeparator}bridge_endpoint.json',
    );
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<PrefsBridgeServer?> startServer() => PrefsBridgeServer.start(
      onSet: (key, value) => db.applyRemoteSet(key, value),
      onRemove: (key) => db.applyRemoteSet(key, null),
      onOps: (ops) => db.applyRemoteOps(ops),
      validatePayload: (payload) async => db.validateRemotePayload(payload),
      endpointFile: endpointFile,
    );

    final firstServer = await startServer();
    expect(firstServer, isNotNull);
    final first = firstServer!;
    final client = PrefsBridgeClient(first.port, endpointFile: endpointFile);
    db.attachBridge(client);
    db.setJournalDirectory(tempDir);
    final firstSession = first.session;

    await db.saveHistory(
      _history(
        '1',
        'QA Sample 01',
        20,
        watchedAt: DateTime(2026, 11, 4, 12, 0, 0),
      ),
    );
    expect(db.getHistory().map((h) => h.videoId), ['1']);

    // 主窗口关闭后重启：新端口/新会话，端点文件被更新。
    await first.dispose();
    final secondServer = await startServer();
    expect(secondServer, isNotNull);
    final second = secondServer!;
    expect(second.session, isNot(firstSession));

    await db.saveHistory(
      _history(
        '2',
        'QA Sample 02',
        30,
        watchedAt: DateTime(2026, 11, 4, 12, 1, 0),
      ),
    );
    expect(db.getHistory().map((h) => h.videoId), containsAll(['1', '2']));

    db.resetForTest();
    await second.dispose();
  });

  test('播放器离线写入：不覆盖本地配置，操作进日志并在下次启动回放', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    final tempDir = Directory.systemTemp.createTempSync('nova_journal_');
    addTearDown(() {
      db.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    await db.addFavorite(VideoModel(id: '2', title: 'QA Sample 02'));
    expect(db.getFavorites().single.id, '2');

    db.attachBridge(PrefsBridgeClient(await _deadPort()), journalDir: tempDir);
    await db.saveHistory(_history('3', 'QA Sample 03', 40));

    expect(db.getHistory(), isEmpty);
    expect(db.getFavorites().single.id, '2');
    expect(db.pendingOps, isNotEmpty);

    final journal = File(
      '${tempDir.path}${Platform.pathSeparator}pending_ops.$pid.json',
    );
    expect(journal.existsSync(), isTrue);
    expect(journal.readAsStringSync(), contains('history.upsert'));

    db.resetForTest();
    await db.init();
    db.setJournalDirectory(tempDir);
    await db.flushPendingJournals();

    expect(db.getHistory().single.videoId, '3');
    expect(db.getFavorites().single.id, '2');
    expect(journal.existsSync(), isFalse);
  });

  test('配置桥：标量写/删转发并广播变更', () async {
    final values = <String, Object?>{};
    final tempDir = Directory.systemTemp.createTempSync('nova_scalar_');
    final endpointFile = File(
      '${tempDir.path}${Platform.pathSeparator}bridge_endpoint.json',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) async => values[key] = value,
      onRemove: (key) async => values.remove(key),
      onOps: (ops) async => const <String>[],
      validatePayload: (payload) async => null,
      endpointFile: endpointFile,
    );
    expect(server, isNotNull);
    final client = PrefsBridgeClient(server!.port, endpointFile: endpointFile);
    addTearDown(() async {
      client.dispose();
      await server.dispose();
    });

    final changes = <Set<String>>[];
    final subscription = server.changes.listen(changes.add);
    addTearDown(subscription.cancel);

    expect(await client.set({'auto_play': false}), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(values['auto_play'], isFalse);
    expect(changes.last, contains('auto_play'));

    expect(await client.remove(['auto_play']), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(values.containsKey('auto_play'), isFalse);
    expect(changes.last, contains('auto_play'));
  });

  test('配置桥：主进程关闭后客户端写入返回 false（播放器转离线日志）', () async {
    final tempDir = Directory.systemTemp.createTempSync('nova_closed_');
    final endpointFile = File(
      '${tempDir.path}${Platform.pathSeparator}bridge_endpoint.json',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) async {},
      onRemove: (key) async {},
      onOps: (ops) async => const <String>[],
      validatePayload: (payload) async => null,
      endpointFile: endpointFile,
    );
    await server!.dispose();
    // 端点文件存在但主进程已关闭：客户端请求失败。
    final client = PrefsBridgeClient(server.port, endpointFile: endpointFile);
    addTearDown(client.dispose);
    expect(await client.set({'auto_play': false}), isFalse);
  });
}
