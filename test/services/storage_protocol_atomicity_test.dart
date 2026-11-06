import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/services/database_service.dart';
import 'package:nova_play/services/prefs_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The storage gate pauses a real SharedPreferences write.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const _entry = '42||title:第2集';
const _mapping = {'episodeId': 222, 'animeTitle': 'QA', 'episodeTitle': '第2集'};

class _SlowStore extends InMemorySharedPreferencesStore {
  _SlowStore() : super.empty();

  final entered = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith('danmaku_episode_map_v1') && !entered.isCompleted) {
      entered.complete();
      await resume.future;
    }
    return super.setValue(valueType, key, value);
  }
}

Future<Map<String, dynamic>> _send(
  PrefsBridgeServer server,
  Map<String, Object?> body,
) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    server.port,
  );
  try {
    socket.writeln(jsonEncode({...body, 'session': server.session}));
    await socket.flush();
    final reply = await socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 5));
    return (jsonDecode(reply) as Map).cast<String, dynamic>();
  } finally {
    socket.destroy();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DatabaseService db;
  late PrefsBridgeServer server;
  late Directory temporary;
  late File endpoint;
  late List<Map<String, dynamic>> seenOps;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = DatabaseService()..resetForTest();
    await db.init();
    temporary = await Directory.systemTemp.createTemp('review-r8-integration-');
    endpoint = File('${temporary.path}${Platform.pathSeparator}endpoint.json');
    seenOps = [];
    server =
        (await PrefsBridgeServer.start(
          onSet: db.applyRemoteSet,
          onRemove: (key) => db.applyRemoteSet(key, null),
          onOps: (ops) {
            seenOps.addAll(ops);
            return db.applyRemoteOps(ops);
          },
          validatePayload: (payload) async => db.validateRemotePayload(payload),
          endpointFile: endpoint,
        ))!;
  });

  tearDown(() async {
    db.resetForTest();
    await server.dispose();
    await temporary.delete(recursive: true);
  });

  test('numeric history watchedAt is rejected before any write', () async {
    Map<String, Object?> payload(Object watchedAt) => {
      'ops': [
        {
          'op': 'danmaku.map.set',
          'key': _entry,
          'value': _mapping,
          'opId': 'map-1',
        },
        {
          'op': 'history.upsert',
          'opId': 'history-2',
          'item': {
            'videoId': '42',
            'title': 'QA',
            'sourceId': 'source',
            'watchedAt': watchedAt,
          },
        },
      ],
    };
    final malformed = payload(20261106);
    expect(db.validateRemotePayload(malformed), 'bad_item');
    expect(await _send(server, malformed), {'ok': false, 'error': 'bad_item'});
    expect(db.getDanmakuMapping(_entry), isNull);
    expect(db.getHistory(), isEmpty);

    // A rejected batch leaves both opIds available for a corrected retry.
    final retry = await _send(server, payload('2026-11-06T00:00:00Z'));
    expect(retry['ok'], isTrue);
    expect(retry['appliedIds'], ['map-1', 'history-2']);
    expect(db.getHistory().single.videoId, '42');
  });

  test('numeric favorite updatedAt is rejected before any write', () async {
    final malformed = {
      'ops': [
        {
          'op': 'danmaku.map.set',
          'key': _entry,
          'value': _mapping,
          'opId': 'map-1',
        },
        {
          'op': 'favorites.add',
          'opId': 'favorite-2',
          'item': {'id': '42', 'title': 'QA', 'updatedAt': 20261106},
        },
      ],
    };
    expect(db.validateRemotePayload(malformed), 'bad_item');
    expect(await _send(server, malformed), {'ok': false, 'error': 'bad_item'});
    expect(db.getDanmakuMapping(_entry), isNull);
    expect(db.getFavorites(), isEmpty);
  });

  test('duplicate in-flight opId cannot overwrite newer mapping', () async {
    SharedPreferences.setMockInitialValues({});
    final store = _SlowStore();
    SharedPreferencesStorePlatform.instance = store;
    db.resetForTest();
    await db.init();
    addTearDown(() {
      if (!store.resume.isCompleted) store.resume.complete();
    });

    Map<String, Object?> payload(String opId, int episodeId) => {
      'ops': [
        {
          'op': 'danmaku.map.set',
          'key': _entry,
          'opId': opId,
          'value': {..._mapping, 'episodeId': episodeId},
        },
      ],
    };
    Future<void> waitForSeen(int count) async {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (seenOps.length < count && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(seenOps.length, count);
    }

    final first = payload('map-1', 111);
    final pending = _send(server, first);
    await store.entered.future.timeout(const Duration(seconds: 2));
    final newer = _send(server, payload('map-2', 222));
    await waitForSeen(2);
    final retry = _send(server, first);
    await waitForSeen(3);
    store.resume.complete();
    final replies = await Future.wait([pending, newer, retry]);
    expect(replies.map((reply) => reply['appliedIds']), [
      ['map-1'],
      ['map-2'],
      ['map-1'],
    ]);
    expect(db.getDanmakuMapping(_entry)?['episodeId'], 222);
  });
}
