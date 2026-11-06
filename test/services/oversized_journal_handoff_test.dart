import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/models/video_model.dart';
import 'package:nova_play/services/database_service.dart';
import 'package:nova_play/services/prefs_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NativeIo extends IOOverrides {}

class _PausedWrite implements File {
  _PausedWrite(this.file, this.entered, this.resume);

  final File file;
  final Completer<void> entered;
  final Future<void> resume;

  @override
  String get path => file.path;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    entered.complete();
    await resume;
    return file.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  Future<File> rename(String newPath) => file.rename(newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ordinary journal survives until the oversized journal is durable',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = DatabaseService()..resetForTest();
      await db.init();
      final temp = await Directory.systemTemp.createTemp(
        'pr7-r9-moving-journal-',
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
      final entered = Completer<void>();
      final resume = Completer<void>();
      final native = _NativeIo();
      final pendingPlayer = IOOverrides.runZoned(
        () => db.addFavorite(
          VideoModel(id: target, title: 'Target', episodes: episodes),
        ),
        createFile: (path) {
          final file = native.createFile(path);
          if (path.contains('.oversized.json.') && path.endsWith('.tmp')) {
            return _PausedWrite(file, entered, resume.future);
          }
          return file;
        },
      );
      try {
        await entered.future.timeout(const Duration(seconds: 5));
        final journal = temp.listSync().whereType<File>().singleWhere(
          (file) => file.path.endsWith('.json'),
        );
        final ops = jsonDecode(await journal.readAsString()) as List;
        expect(ops.single['item']['id'], target);
      } finally {
        resume.complete();
        await pendingPlayer;
      }
      expect(
        temp.listSync().whereType<File>().map((f) => f.path),
        contains(endsWith('.oversized.json')),
      );
    },
  );
}
