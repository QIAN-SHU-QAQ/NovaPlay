import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/services/m3u8/m3u8_parser.dart';

void main() {
  group('media playlist', () {
    const media = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:9.009,
seg-0.ts
#EXTINF:9.009,
https://cdn.example.com/videos/seg-1.ts
#EXTINF:3.003,
sub/seg-2.ts
#EXT-X-ENDLIST
''';

    test('解析分片、时长与绝对地址', () {
      final playlist = M3u8Parser.parse(
        media,
        baseUrl: 'https://cdn.example.com/hls/index.m3u8',
      );

      expect(playlist.isMaster, isFalse);
      expect(playlist.segments.length, 3);
      expect(playlist.totalDuration, closeTo(21.021, 0.001));
      expect(playlist.segments[0].url, 'https://cdn.example.com/hls/seg-0.ts');
      expect(
        playlist.segments[1].url,
        'https://cdn.example.com/videos/seg-1.ts',
      );
      expect(
        playlist.segments[2].url,
        'https://cdn.example.com/hls/sub/seg-2.ts',
      );
      expect(playlist.segments[2].index, 2);
    });

    test('识别 AES-128 加密', () {
      const encrypted = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:10,
seg-0.ts
''';
      final playlist = M3u8Parser.parse(
        encrypted,
        baseUrl: 'https://cdn.example.com/hls/index.m3u8',
      );
      expect(playlist.isEncrypted, isTrue);
      expect(playlist.encryptionMethod, 'AES-128');
    });

    test('METHOD=NONE 不算加密', () {
      const plain = '''
#EXTM3U
#EXT-X-KEY:METHOD=NONE
#EXTINF:10,
seg-0.ts
''';
      final playlist = M3u8Parser.parse(
        plain,
        baseUrl: 'https://cdn.example.com/hls/index.m3u8',
      );
      expect(playlist.isEncrypted, isFalse);
    });
  });

  group('master playlist', () {
    const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1800000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"
720/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3600000,RESOLUTION=1920x1080
https://cdn.example.com/1080/index.m3u8
''';

    test('解析变体与属性', () {
      final playlist = M3u8Parser.parse(
        master,
        baseUrl: 'https://cdn.example.com/hls/master.m3u8',
      );

      expect(playlist.isMaster, isTrue);
      expect(playlist.variants.length, 2);
      expect(
        playlist.variants[0].url,
        'https://cdn.example.com/hls/720/index.m3u8',
      );
      expect(playlist.variants[0].bandwidth, 1800000);
      expect(playlist.variants[0].resolution, '1280x720');
      expect(
        playlist.variants[1].url,
        'https://cdn.example.com/1080/index.m3u8',
      );
      expect(playlist.variants[1].bandwidth, 3600000);
    });
  });

  test('非法内容抛出 M3u8FormatException', () {
    expect(
      () => M3u8Parser.parse(
        '<html>not a playlist</html>',
        baseUrl: 'https://a/b',
      ),
      throwsA(isA<M3u8FormatException>()),
    );
  });

  test('BOM 与 CRLF 不影响解析', () {
    const content = '\uFEFF#EXTM3U\r\n#EXTINF:4.0,\r\nseg-0.ts\r\n';
    final playlist = M3u8Parser.parse(
      content,
      baseUrl: 'https://cdn.example.com/index.m3u8',
    );
    expect(playlist.segments.length, 1);
    expect(playlist.segments.first.url, 'https://cdn.example.com/seg-0.ts');
  });
}
