import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/models/video_model.dart';
import 'package:nova_play/services/database_service.dart';
import 'package:nova_play/services/prefs_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an old cancel remains effective across unrelated replays', () async {
    final otherIds = List.generate(500, (i) => 'other-$i');
    SharedPreferences.setMockInitialValues({
      'favorites_v1': jsonEncode([
        for (final id in otherIds) VideoModel(id: id, title: id).toJson(),
      ]),
    });
    final db = DatabaseService()..resetForTest();
    await db.init();
    final temp = await Directory.systemTemp.createTemp(
      'pr7-r8-player-survives-',
    );
    addTearDown(() async {
      db.resetForTest();
      await temp.delete(recursive: true);
    });
    final endpoint = File(
      '${temp.path}${Platform.pathSeparator}missing-endpoint.json',
    );
    db.attachBridge(
      PrefsBridgeClient(0, endpointFile: endpoint),
      journalDir: temp,
    );
    final episodes = List.generate(
      2000,
      (index) => EpisodeModel(
        id: 'episode-$index',
        title: 'Episode $index',
        url: 'https://example.test/${'x' * 250}/$index.m3u8',
      ),
    );
    const target = 'target';
    await db.addFavorite(
      VideoModel(id: target, title: 'Target', episodes: episodes),
    );
    final oversized = temp.listSync().whereType<File>().singleWhere(
      (file) => file.path.endsWith('.oversized.json'),
    );
    List readOps() => jsonDecode(oversized.readAsStringSync()) as List;
    final oldAdd = readOps().single as Map;
    final oldAddAt = DateTime.parse(oldAdd['at'] as String);
    final removalAt = oldAddAt.add(const Duration(seconds: 1));
    Map<String, dynamic> remove(String id, DateTime time) => {
      'op': 'favorites.remove',
      'opId': 'remove-$id',
      'at': time.toIso8601String(),
      'videoId': id,
    };

    // These two calls exercise the main side while the attached player stays alive.
    await db.applyRemoteOps([remove(target, removalAt)]);
    await db.flushPendingJournals();
    expect(db.getFavorites().map((video) => video.id), isNot(contains(target)));
    expect(oversized.existsSync(), isFalse);
    expect(db.oversizedOps.single['opId'], oldAdd['opId']);

    final guardPrefs = await SharedPreferences.getInstance();
    const guardsKey = 'favorites_replay_guards_v1';
    // Existing preferences from the previous replay guard implementation.
    final newer = DateTime.now().toIso8601String();
    await guardPrefs.setString(
      guardsKey,
      jsonEncode({
        target: oldAddAt.toIso8601String(),
        for (var i = 0; i < 4999; i++) 'replayed-$i': newer,
      }),
    );
    final nextLog = File(
      '${temp.path}${Platform.pathSeparator}pending_ops.101.json',
    );
    await nextLog.writeAsString(
      jsonEncode([
        {
          'op': 'favorites.add',
          'opId': 'next-replayed-add',
          'at': DateTime.now().toIso8601String(),
          'item': VideoModel(id: otherIds.last, title: 'Next replay').toJson(),
        },
      ]),
    );
    await db.flushPendingJournals();
    for (var i = 0; i < otherIds.length; i++) {
      await db.applyRemoteOps([
        remove(otherIds[i], removalAt.add(Duration(seconds: i + 1))),
      ]);
    }
    expect(db.getFavorites(), isEmpty);

    // The same player adds a new oversized favorite and rewrites its pending snapshot.
    const newId = 'new-favorite';
    await db.addFavorite(
      VideoModel(id: newId, title: 'New favorite', episodes: episodes),
    );
    final newOperations = readOps();
    expect(newOperations.map((op) => op['item']['id']), contains(newId));

    // Main startup again. Only the new favorite should survive.
    db.resetForTest();
    await db.init();
    db.setJournalDirectory(temp);
    await db.flushPendingJournals();
    expect(db.getFavorites().map((video) => video.id), [newId]);
  });
}
