import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/models/history_item.dart';
import 'package:nova_play/models/video_model.dart';
import 'package:nova_play/services/database_service.dart';
import 'package:nova_play/services/prefs_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

HistoryItem _history(String videoId, String title, int seconds) {
  return HistoryItem(
    videoId: videoId,
    title: title,
    episodeIndex: 0,
    position: Duration(seconds: seconds),
    watchedAt: DateTime(2026, 11, 4),
  );
}

Future<int> _deadPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('配置桥：标量写/删转发并广播变更', () async {
    final values = <String, Object?>{};
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) async => values[key] = value,
      onRemove: (key) async => values.remove(key),
      onOps: (ops) async => const <String>[],
    );
    expect(server, isNotNull);
    final client = PrefsBridgeClient(server!.port);
    addTearDown(() async {
      client.dispose();
      await server.dispose();
    });

    final changes = <Set<String>>[];
    final subscription = server.changes.listen(changes.add);
    addTearDown(subscription.cancel);

    expect(await client.set({'auto_play': false, 'history_v1': '[]'}), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(values['auto_play'], isFalse);
    expect(values['history_v1'], '[]');
    expect(changes.last, containsAll(<String>['auto_play', 'history_v1']));

    expect(await client.remove(['history_v1']), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(values.containsKey('history_v1'), isFalse);
    expect(changes.last, contains('history_v1'));
  });

  test('配置桥：主进程关闭后客户端写入返回 false（播放器转离线日志）', () async {
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) async {},
      onRemove: (key) async {},
      onOps: (ops) async => const <String>[],
    );
    final port = server!.port;
    await server.dispose();

    final client = PrefsBridgeClient(port);
    addTearDown(client.dispose);
    expect(await client.set({'a': 1}), isFalse);
  });

  test('语义操作：主进程在最新状态上合并，两个播放器先后写入都保留', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);

    final server = await PrefsBridgeServer.start(
      onSet: (key, value) => db.applyRemoteSet(key, value),
      onRemove: (key) => db.applyRemoteSet(key, null),
      onOps: (ops) => db.applyRemoteOps(ops),
    );
    addTearDown(() async {
      db.resetForTest();
      await server?.dispose();
    });
    final client = PrefsBridgeClient(server!.port);

    final changeFuture = server.changes.first;
    expect(
      await client.ops([
        {
          'op': 'history.upsert',
          'item': _history('1', 'QA Sample 01', 20).toJson(),
        },
      ]),
      isTrue,
    );
    expect(
      await client.ops([
        {
          'op': 'history.upsert',
          'item': _history('2', 'QA Sample 02', 30).toJson(),
        },
      ]),
      isTrue,
    );
    expect(db.getHistory().map((h) => h.videoId), containsAll(['1', '2']));
    expect(await changeFuture, contains('history_v1'));

    await client.ops([
      {'op': 'history.remove', 'videoId': '1'},
    ]);
    expect(db.getHistory().map((h) => h.videoId), ['2']);

    await client.ops([
      {
        'op': 'favorites.add',
        'item': VideoModel(id: '2', title: 'QA Sample 02').toJson(),
      },
    ]);
    expect(db.getFavorites().single.id, '2');
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
      endpointFile: endpointFile,
    );

    final firstServer = await startServer();
    expect(firstServer, isNotNull);
    final client = PrefsBridgeClient(
      firstServer!.port,
      endpointFile: endpointFile,
    );
    expect(
      await client.ops([
        {
          'op': 'history.upsert',
          'item': _history('1', 'QA Sample 01', 20).toJson(),
        },
      ]),
      isTrue,
    );

    // 主窗口关闭后重启：新主进程使用新端口/新会话，端点文件被更新。
    final firstSession = firstServer.session;
    await firstServer.dispose();
    final secondServer = await startServer();
    expect(secondServer, isNotNull);
    expect(secondServer!.session, isNot(firstSession));

    // 客户端仍持有旧端口号，但应通过端点文件发现新主窗口并提交成功。
    expect(
      await client.ops([
        {
          'op': 'history.upsert',
          'item': _history('2', 'QA Sample 02', 30).toJson(),
        },
      ]),
      isTrue,
    );
    expect(db.getHistory().map((h) => h.videoId), containsAll(['1', '2']));

    await secondServer.dispose();
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

    // 主窗口此前写入的收藏必须保留。
    await db.addFavorite(VideoModel(id: '2', title: 'QA Sample 02'));
    expect(db.getFavorites().single.id, '2');

    // 模拟主窗口已关闭：配置桥连不上。
    db.attachBridge(PrefsBridgeClient(await _deadPort()), journalDir: tempDir);
    await db.saveHistory(_history('3', 'QA Sample 03', 40));

    // 播放器不能用启动时的旧缓存写整份配置：本地历史仍为空，收藏未丢。
    expect(db.getHistory(), isEmpty);
    expect(db.getFavorites().single.id, '2');
    expect(db.pendingOps, isNotEmpty);

    final journal = File(
      '${tempDir.path}${Platform.pathSeparator}pending_ops.$pid.json',
    );
    expect(journal.existsSync(), isTrue);
    expect(journal.readAsStringSync(), contains('history.upsert'));
    expect(jsonDecode(journal.readAsStringSync()), isA<List<dynamic>>());

    // 模拟下次启动主进程：回放离线日志。
    db.resetForTest();
    await db.init();
    db.setJournalDirectory(tempDir);
    await db.flushPendingJournals();

    expect(db.getHistory().single.videoId, '3');
    expect(db.getFavorites().single.id, '2');
    expect(journal.existsSync(), isFalse);
  });
}
