import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/services/m3u8/m3u8_downloader.dart';
import 'package:nova_play/services/m3u8/m3u8_parser.dart';

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

String _playlist(List<String> segmentNames, {bool endList = true}) {
  final buffer = StringBuffer('#EXTM3U\n');
  for (final name in segmentNames) {
    buffer
      ..writeln('#EXTINF:4,')
      ..writeln(name);
  }
  if (endList) buffer.writeln('#EXT-X-ENDLIST');
  return buffer.toString();
}

void main() {
  late Directory tempDir;
  late M3u8Downloader downloader;
  late _FakeAdapter adapter;

  const playlistUrl = 'https://cdn.test/hls/index.m3u8';
  final mediaPlaylist = _playlist(['s0.ts', 's1.ts', 's2.ts']);

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

  test('断点续传：失败后重跑复用已完成且校验通过的分片', () async {
    final savePath = '${tempDir.path}/resume.ts';
    final s1Url = 'https://cdn.test/hls/s1.ts';
    final savedS1 = adapter.responses.remove(s1Url);

    // 第一次：s1 缺失导致失败，s0 已完整落盘并写入清单。
    await expectLater(
      downloader.download(url: playlistUrl, savePath: savePath),
      throwsA(isA<M3u8FormatException>()),
    );
    expect(File('$savePath.segments/seg_000000.ts').existsSync(), isTrue);

    // 恢复 s1 后重跑：s0 校验通过应复用，不重复请求。
    adapter.responses[s1Url] = savedS1!;
    adapter.requests.clear();
    final result = await downloader.download(
      url: playlistUrl,
      savePath: savePath,
    );

    expect(result.segmentCount, 3);
    expect(File(savePath).readAsBytesSync(), [1, 2, 3, 4, 5, 6]);
    expect(
      adapter.requests.where((u) => u.endsWith('s0.ts')),
      isEmpty,
      reason: '完整且哈希一致的分片不应重复下载',
    );
  });

  test('R2：缓存分片被截断时不复用，重新下载后产物正确', () async {
    final savePath = '${tempDir.path}/truncated.ts';
    final s1Url = 'https://cdn.test/hls/s1.ts';
    final savedS1 = adapter.responses.remove(s1Url);

    await expectLater(
      downloader.download(url: playlistUrl, savePath: savePath),
      throwsA(isA<M3u8FormatException>()),
    );
    // 模拟上次中断导致 s0 被截断。
    final cached = File('$savePath.segments/seg_000000.ts');
    cached.writeAsBytesSync([1]);

    adapter.responses[s1Url] = savedS1!;
    adapter.requests.clear();
    await downloader.download(url: playlistUrl, savePath: savePath);

    expect(File(savePath).readAsBytesSync(), [1, 2, 3, 4, 5, 6]);
    expect(
      adapter.requests.where((u) => u.endsWith('s0.ts')).length,
      1,
      reason: '截断文件必须重新下载',
    );
  });

  test('R2：旧清单遗留的分片不会被混入新下载', () async {
    final savePath = '${tempDir.path}/stale.ts';
    final segmentsDir = Directory('$savePath.segments')..createSync();
    // 上一次任务的旧分片内容 [9]。
    File('${segmentsDir.path}/seg_000000.ts').writeAsBytesSync([9]);
    File('${segmentsDir.path}/manifest.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'playlistUrl': playlistUrl,
        'fingerprint': 'old-fingerprint',
        'generatedAt': DateTime.now().toIso8601String(),
        'segments': [
          {
            'index': 0,
            'url': 'https://cdn.test/hls/s0.ts',
            'duration': 4.0,
            'size': 1,
            'sha256': 'old',
          },
        ],
      }),
    );

    await downloader.download(url: playlistUrl, savePath: savePath);

    expect(File(savePath).readAsBytesSync(), [1, 2, 3, 4, 5, 6]);
    expect(adapter.requests.where((u) => u.endsWith('s0.ts')).length, 1);
  });

  test('R2：清单 URI 变化时重新下载全部分片', () async {
    final savePath = '${tempDir.path}/changed.ts';
    final s1Url = 'https://cdn.test/hls/s1.ts';
    final savedS1 = adapter.responses.remove(s1Url);
    await expectLater(
      downloader.download(url: playlistUrl, savePath: savePath),
      throwsA(isA<M3u8FormatException>()),
    );

    // 清单换成新 URI 的同一批分片。
    final newMedia = _playlist(['n0.ts', 'n1.ts', 'n2.ts']);
    adapter.responses[playlistUrl] = utf8.encode(newMedia);
    adapter.responses['https://cdn.test/hls/n0.ts'] = [11];
    adapter.responses['https://cdn.test/hls/n1.ts'] = [12];
    adapter.responses['https://cdn.test/hls/n2.ts'] = [13];
    adapter.responses['https://cdn.test/hls/s2.ts'] = [6];
    adapter.responses[s1Url] = savedS1!;
    adapter.requests.clear();

    await downloader.download(url: playlistUrl, savePath: savePath);

    expect(File(savePath).readAsBytesSync(), [11, 12, 13]);
    expect(
      adapter.requests.where(
        (u) => u.contains('/s0.ts') || u.contains('/s1.ts'),
      ),
      isEmpty,
      reason: '旧清单分片不能被复用',
    );
  });

  test('R3：fMP4（EXT-X-MAP）在下载主体前报错', () async {
    const fmp4Url = 'https://cdn.test/hls/fmp4.m3u8';
    adapter.responses[fmp4Url] = utf8.encode('''
#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:4,
seg0.m4s
#EXTINF:4,
seg1.m4s
#EXT-X-ENDLIST
''');
    adapter.responses['https://cdn.test/hls/seg0.m4s'] = [1];
    adapter.responses['https://cdn.test/hls/seg1.m4s'] = [2];
    adapter.requests.clear();

    await expectLater(
      downloader.download(url: fmp4Url, savePath: '${tempDir.path}/fmp4.ts'),
      throwsA(
        isA<M3u8FormatException>().having(
          (e) => e.message,
          'message',
          contains('fMP4'),
        ),
      ),
    );
    expect(
      adapter.requests.where((u) => u.endsWith('.m4s')),
      isEmpty,
      reason: '不支持格式不应开始下载分片',
    );
  });

  test('R3：BYTERANGE / 直播 / 独立音轨在下载主体前报错', () async {
    const byteRangeUrl = 'https://cdn.test/hls/br.m3u8';
    adapter.responses[byteRangeUrl] = utf8.encode('''
#EXTM3U
#EXTINF:4,
#EXT-X-BYTERANGE:100@0
s0.ts
#EXT-X-ENDLIST
''');
    const liveUrl = 'https://cdn.test/hls/live.m3u8';
    adapter.responses[liveUrl] = utf8.encode(
      _playlist(['s0.ts'], endList: false),
    );
    const audioMasterUrl = 'https://cdn.test/hls/audio-master.m3u8';
    adapter.responses[audioMasterUrl] = utf8.encode('''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a1",NAME="audio",URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="a1"
v/index.m3u8
''');

    for (final (url, expected) in [
      (byteRangeUrl, 'BYTERANGE'),
      (liveUrl, '直播'),
      (audioMasterUrl, '独立音轨'),
    ]) {
      await expectLater(
        downloader.download(url: url, savePath: '${tempDir.path}/x.ts'),
        throwsA(
          isA<M3u8FormatException>().having(
            (e) => e.message,
            'message',
            contains(expected),
          ),
        ),
        reason: url,
      );
    }
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
    adapter.responses['https://cdn.test/hls/low/index.m3u8'] = utf8.encode(
      _playlist(['low-0.ts']),
    );
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
#EXT-X-ENDLIST
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
