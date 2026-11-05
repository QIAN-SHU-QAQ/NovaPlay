import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/services/download_service.dart';
import 'package:nova_play/services/m3u8/m3u8_downloader.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.responses);

  final Map<String, List<int>> responses;
  final Map<String, Duration> delays = {};
  final List<String> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requests.add(url);
    final delay = delays[url];
    if (delay != null) {
      await Future<void>.delayed(delay);
    }
    final data = responses[url];
    if (data == null) {
      return ResponseBody.fromString('not found', 404);
    }
    if (options.responseType == ResponseType.plain) {
      return ResponseBody.fromString(
        utf8.decode(data),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.textPlainContentType],
        },
      );
    }
    return ResponseBody.fromBytes(data, 200);
  }

  @override
  void close({bool force = false}) {}
}

Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _Adapter adapter;
  late DownloadService service;

  const playlistUrl = 'https://cdn.test/hls/index.m3u8';
  const mediaPlaylist = '''
#EXTM3U
#EXTINF:4,
s0.ts
#EXTINF:4,
s1.ts
#EXT-X-ENDLIST
''';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('nova_download_');
    adapter = _Adapter({
      playlistUrl: utf8.encode(mediaPlaylist),
      'https://cdn.test/hls/s0.ts': [1, 2, 3],
      'https://cdn.test/hls/s1.ts': [4, 5],
    });
    service = DownloadService(
      downloader: M3u8Downloader(
        dio: Dio()..httpClientAdapter = adapter,
        concurrency: 1,
      ),
      baseDirectory: () async => tempDir,
    );
    await service.init();
  });

  tearDown(() {
    service.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('加入任务后完成下载，文件按分片顺序合并', () async {
    final task = await service.addTask(title: '测试番剧/第1集', url: playlistUrl);
    await _waitFor(
      () => service.tasks.single.status == DownloadStatus.completed,
    );

    final completed = service.tasks.single;
    expect(completed.id, task.id);
    expect(completed.progress, 1);
    expect(completed.savePath, contains('测试番剧_第1集'));
    final file = File(completed.savePath);
    expect(file.existsSync(), isTrue);
    expect(file.readAsBytesSync(), [1, 2, 3, 4, 5]);
  });

  test('下载失败标记 failed，补齐数据后可重试成功', () async {
    adapter.responses.remove('https://cdn.test/hls/s1.ts');

    await service.addTask(title: '失败重试', url: playlistUrl);
    await _waitFor(() => service.tasks.single.status == DownloadStatus.failed);
    expect(service.tasks.single.error, isNotNull);
    expect(service.tasks.single.progress, lessThan(1));

    adapter.responses['https://cdn.test/hls/s1.ts'] = [4, 5];
    service.resumeTask(service.tasks.single.id);
    await _waitFor(
      () => service.tasks.single.status == DownloadStatus.completed,
    );
    expect(File(service.tasks.single.savePath).readAsBytesSync(), [
      1,
      2,
      3,
      4,
      5,
    ]);
  });

  test('删除任务会清理已下载文件', () async {
    await service.addTask(title: '删除测试', url: playlistUrl);
    await _waitFor(
      () => service.tasks.single.status == DownloadStatus.completed,
    );
    final savePath = service.tasks.single.savePath;

    await service.removeTask(service.tasks.single.id);

    expect(service.tasks, isEmpty);
    expect(File(savePath).existsSync(), isFalse);
    expect(Directory('$savePath.segments').existsSync(), isFalse);
  });

  test('暂停后保留当前进度，继续下载从断点完成', () async {
    // 第二个分片故意变慢，留出"下载中暂停"的窗口。
    adapter.delays['https://cdn.test/hls/s1.ts'] = const Duration(
      milliseconds: 500,
    );

    final task = await service.addTask(title: '暂停进度', url: playlistUrl);
    // 2 个分片、并发 1：第一个完成后进度应为 0.5
    await _waitFor(() => service.tasks.single.progress >= 0.5);
    service.pauseTask(task.id);
    await _waitFor(() => service.tasks.single.status == DownloadStatus.paused);

    // 回归点：暂停后进度不能被重置为 0（旧实现用 _run 开始时的任务副本覆盖）
    expect(service.tasks.single.progress, greaterThanOrEqualTo(0.5));

    final prefs = await SharedPreferences.getInstance();
    await _waitFor(() => prefs.getString('downloads_v1') != null);
    final persisted = jsonDecode(prefs.getString('downloads_v1')!) as List;
    final persistedProgress =
        ((persisted.first as Map)['progress'] as num).toDouble();
    expect(persistedProgress, greaterThanOrEqualTo(0.5));

    service.resumeTask(task.id);
    await _waitFor(
      () => service.tasks.single.status == DownloadStatus.completed,
    );
    expect(File(service.tasks.single.savePath).readAsBytesSync(), [
      1,
      2,
      3,
      4,
      5,
    ]);
  });

  test('任务持久化：重启后恢复，未完成任务标记为暂停', () async {
    await service.addTask(title: '持久化测试', url: playlistUrl);
    await _waitFor(
      () => service.tasks.single.status == DownloadStatus.completed,
    );
    final prefs = await SharedPreferences.getInstance();
    await _waitFor(() => prefs.getString('downloads_v1') != null);
    service.dispose();

    final restarted = DownloadService(
      downloader: M3u8Downloader(dio: Dio()..httpClientAdapter = adapter),
      baseDirectory: () async => tempDir,
    );
    await restarted.init();
    expect(restarted.tasks.single.title, '持久化测试');
    expect(restarted.tasks.single.status, DownloadStatus.completed);
    restarted.dispose();

    // 手工写入一个"下载中"任务，模拟异常退出后的恢复
    final raw = jsonDecode(prefs.getString('downloads_v1')!) as List;
    final legacy = Map<String, dynamic>.from(raw.first as Map);
    legacy['status'] = 'downloading';
    await prefs.setString('downloads_v1', jsonEncode([legacy]));
    final restored = DownloadService(
      downloader: M3u8Downloader(dio: Dio()..httpClientAdapter = adapter),
      baseDirectory: () async => tempDir,
    );
    await restored.init();
    expect(restored.tasks.single.status, DownloadStatus.paused);
    restored.dispose();
  });
}
