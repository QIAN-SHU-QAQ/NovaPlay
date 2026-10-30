import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/services/m3u8/m3u8_downloader.dart';

/// 内存版 HTTP 适配器：按 URL 返回预设内容，并记录请求。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);

  final Map<String, List<int>> responses;
  final List<String> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requests.add(url);
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

void main() {
  late Directory tempDir;
  late M3u8Downloader downloader;
  late _FakeAdapter adapter;

  const playlistUrl = 'https://cdn.test/hls/index.m3u8';
  const mediaPlaylist = '''
#EXTM3U
#EXTINF:4,
s0.ts
#EXTINF:4,
s1.ts
#EXTINF:4,
s2.ts
''';

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('nova_m3u8_');
    adapter = _FakeAdapter({
      playlistUrl: utf8.encode(mediaPlaylist),
      'https://cdn.test/hls/s0.ts': [1, 2, 3],
      'https://cdn.test/hls/s1.ts': [4, 5],
      'https://cdn.test/hls/s2.ts': [6],
    });
    downloader = M3u8Downloader(
      dio: Dio()..httpClientAdapter = adapter,
      concurrency: 2,
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('下载全部分片并按顺序合并', () async {
    final savePath = '${tempDir.path}/out.ts';
    final progress = <M3u8DownloadProgress>[];

    final result = await downloader.download(
      url: playlistUrl,
      savePath: savePath,
      onProgress: progress.add,
    );

    expect(result.segmentCount, 3);
    expect(File(savePath).readAsBytesSync(), [1, 2, 3, 4, 5, 6]);
    expect(File(savePath).existsSync(), isTrue);
    expect(Directory('$savePath.segments').existsSync(), isFalse);
    expect(progress.last.phase, M3u8DownloadPhase.done);
    expect(progress.last.fraction, 1.0);
    expect(adapter.requests.length, 4);
  });

  test('断点续传：已存在的分片不再重新下载', () async {
    final savePath = '${tempDir.path}/resume.ts';
    final segmentsDir = Directory('$savePath.segments')..createSync();
    File('${segmentsDir.path}/seg_000000.ts').writeAsBytesSync([1, 2, 3]);

    final result = await downloader.download(
      url: playlistUrl,
      savePath: savePath,
    );

    expect(result.segmentCount, 3);
    expect(File(savePath).readAsBytesSync(), [1, 2, 3, 4, 5, 6]);
    // playlist + s1 + s2，s0 复用本地分片
    expect(adapter.requests.where((u) => u.endsWith('s0.ts')), isEmpty);
    expect(adapter.requests.length, 3);
  });

  test('master playlist 选择最高码率变体', () async {
    const masterUrl = 'https://cdn.test/hls/master.m3u8';
    adapter.responses[masterUrl] = utf8.encode('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080
high/index.m3u8
''');
    adapter.responses['https://cdn.test/hls/low/index.m3u8'] = utf8.encode('''
#EXTM3U
#EXTINF:4,
low-0.ts
''');
    adapter.responses['https://cdn.test/hls/high/index.m3u8'] = utf8.encode(
      mediaPlaylist,
    );
    adapter.responses['https://cdn.test/hls/high/s0.ts'] = [7];
    adapter.responses['https://cdn.test/hls/high/s1.ts'] = [8];
    adapter.responses['https://cdn.test/hls/high/s2.ts'] = [9];

    final savePath = '${tempDir.path}/master.ts';
    await downloader.download(url: masterUrl, savePath: savePath);

    expect(File(savePath).readAsBytesSync(), [7, 8, 9]);
    expect(adapter.requests.where((u) => u.contains('/low/')), isEmpty);
  });

  test('加密流显式报错', () async {
    const encryptedUrl = 'https://cdn.test/hls/enc.m3u8';
    adapter.responses[encryptedUrl] = utf8.encode('''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:4,
s0.ts
''');

    expect(
      () => downloader.download(
        url: encryptedUrl,
        savePath: '${tempDir.path}/enc.ts',
      ),
      throwsA(isA<Exception>()),
    );
  });
}
