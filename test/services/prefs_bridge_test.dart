import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/models/history_item.dart';
import 'package:nova_play/services/database_service.dart';
import 'package:nova_play/services/prefs_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('配置桥：写入/删除转发到主进程并广播变更', () async {
    final values = <String, Object?>{};
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) async => values[key] = value,
      onRemove: (key) async => values.remove(key),
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

  test('配置桥：主进程关闭后客户端写入返回 false（播放器回退本地写）', () async {
    final server = await PrefsBridgeServer.start(
      onSet: (key, value) async {},
      onRemove: (key) async {},
    );
    final port = server!.port;
    await server.dispose();

    final client = PrefsBridgeClient(port);
    addTearDown(client.dispose);
    expect(await client.set({'a': 1}), isFalse);
  });

  test('播放进程写入经主进程持久化，主进程随后写设置不丢历史', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);

    final server = await PrefsBridgeServer.start(
      onSet: (key, value) => db.applyRemoteSet(key, value),
      onRemove: (key) => db.applyRemoteSet(key, null),
    );
    addTearDown(() async {
      db.resetForTest();
      await server?.dispose();
    });

    // 模拟播放器进程：DatabaseService 的写操作转发给主进程。
    db.attachBridge(PrefsBridgeClient(server!.port));
    await db.setAutoPlay(false);
    await db.saveHistory(
      HistoryItem(
        videoId: '1',
        title: 'QA Sample 01',
        episodeIndex: 0,
        position: const Duration(seconds: 35),
        watchedAt: DateTime(2026, 11, 3),
      ),
    );

    expect(db.getAutoPlay(), isFalse);
    expect(db.getHistory().single.videoId, '1');

    // 模拟主进程写入设置：不能覆盖已经由播放器写入的历史。
    db.detachBridge();
    await db.setAutoPlay(true);
    expect(db.getAutoPlay(), isTrue);
    expect(db.getHistory().single.videoId, '1');
  });
}
