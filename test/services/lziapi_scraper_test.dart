import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/core/network/http_client.dart';
import 'package:nova_play/services/scraper/lziapi_scraper.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Object Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(respond(options)),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _video(
  int id, {
  String title = '番剧',
  String year = '2026',
  String host = 'slow.example',
}) => {
  'vod_id': id,
  'vod_name': title,
  'vod_year': year,
  'vod_play_url': '第1集\$https://$host/1.m3u8',
};
Map<String, dynamic> _list(List<Object> items) => {'code': 1, 'list': items};
Never _fail(RequestOptions options) =>
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
    );

void main() {
  late _Adapter adapter;
  late HttpClientAdapter previous;
  late LziApiScraper scraper;
  void respond(Object Function(RequestOptions) handler) {
    adapter = _Adapter(handler);
    HttpClient().dio.httpClientAdapter = adapter;
  }

  setUp(() {
    previous = HttpClient().dio.httpClientAdapter;
    scraper = LziApiScraper();
  });
  tearDown(() => HttpClient().dio.httpClientAdapter = previous);

  test('主源断连后使用备用搜索并保留来源身份', () async {
    respond(
      (o) => o.uri.host == 'cj.lziapi.com' ? _fail(o) : _list([_video(900)]),
    );
    final result = await scraper.search('番剧');
    expect(result.single.id, '360zy:900');
    expect(result.single.source, '360zy');
    expect(result.single.sourceUrl, contains('360zy.com'));
    expect(adapter.requests.length, 2);
  });
  for (final invalidId in [
    '',
    'oops',
    {'id': 1},
  ]) {
    test('主源作品 ID 无效时回退备用源: $invalidId', () async {
      respond(
        (o) => _list([
          o.uri.host == 'cj.lziapi.com'
              ? {..._video(1), 'vod_id': invalidId}
              : _video(900),
        ]),
      );
      expect((await scraper.search('番剧')).single.id, '360zy:900');
      expect(adapter.requests.length, 2);
    });
  }
  test('两源缺少真实剧集标题时不按自动生成的集数匹配', () async {
    respond(
      (o) => _list([
        {
          ..._video(o.uri.host == 'cj.lziapi.com' ? 1 : 900),
          'vod_play_url':
              o.uri.host == 'cj.lziapi.com'
                  ? r'$https://slow.example/one.m3u8#$https://slow.example/two.m3u8'
                  : r'$https://vod1.maowushi.com/two.m3u8#$https://vod1.maowushi.com/one.m3u8',
        },
      ]),
    );
    final result = await scraper.getDetail('1');
    expect(result.episodes!.first.playUrl, 'https://slow.example/one.m3u8');
  });
  test('备用源缺少真实标题时不与主源显式集数匹配', () async {
    respond(
      (o) => _list([
        {
          ..._video(o.uri.host == 'cj.lziapi.com' ? 1 : 900),
          'vod_play_url':
              o.uri.host == 'cj.lziapi.com'
                  ? r'第 1 集$https://slow.example/one.m3u8#第 2 集$https://slow.example/two.m3u8'
                  : r'$https://vod1.maowushi.com/two.m3u8#$https://vod1.maowushi.com/one.m3u8',
        },
      ]),
    );
    expect(
      (await scraper.getDetail('1')).episodes!.first.playUrl,
      'https://slow.example/one.m3u8',
    );
  });
  test('正常空搜索不触发换源', () async {
    respond((o) => _list([]));
    expect(await scraper.search('不存在'), isEmpty);
    expect(adapter.requests.length, 1);
  });
  test('所有源失败抛出可见错误', () async {
    respond(_fail);
    await expectLater(
      scraper.search('番剧'),
      throwsA(predicate((e) => e.toString().contains('数据源'))),
    );
    expect(adapter.requests.length, 2);
  });
  for (final response in [
    {'code': 0, 'list': []},
    {'code': 1, 'list': 'broken'},
  ]) {
    test('主源协议异常也会回退: $response', () async {
      respond(
        (o) => o.uri.host == 'cj.lziapi.com' ? response : _list([_video(900)]),
      );
      expect((await scraper.search('番剧')).single.id, '360zy:900');
    });
  }
  test('首页回退按备用源分类名称查 ID', () async {
    respond((o) {
      if (o.uri.host == 'cj.lziapi.com') return _fail(o);
      if (o.queryParameters['ac'] == 'list') {
        return {
          'code': 1,
          'class': [
            {'type_id': 40, 'type_name': '日韩动漫'},
          ],
        };
      }
      expect(o.queryParameters['t'].toString(), '40');
      return _list([_video(900)]);
    });
    expect((await scraper.getHome()).single.id, '360zy:900');
    expect(adapter.requests.length, 3);
  });
  test('备用源不支持分类时不会误取其他分类', () async {
    respond(
      (o) =>
          o.uri.host == 'cj.lziapi.com'
              ? _fail(o)
              : {
                'code': 1,
                'class': [
                  {'type_id': 40, 'type_name': '日韩动漫'},
                ],
              },
    );
    await expectLater(scraper.getByCategory('港台动漫'), throwsException);
    expect(adapter.requests.length, 2);
  });
  test('带来源 ID 的详情只请求对应源', () async {
    respond((o) {
      expect(o.uri.host, '360zy.com');
      expect(o.queryParameters['ids'], '900');
      return _list([_video(900)]);
    });
    expect((await scraper.getDetail('360zy:900')).id, '360zy:900');
    expect(adapter.requests.length, 1);
  });
  test('主源 ID 失败不能拿同一个数字请求备用源', () async {
    respond(_fail);
    await expectLater(scraper.getDetail('1'), throwsException);
    expect(adapter.requests.length, 1);
  });
  test('备用播放地址不改变作品与剧集身份', () async {
    respond(
      (o) => _list([
        o.uri.host == 'cj.lziapi.com'
            ? _video(1)
            : _video(900, host: 'vod1.maowushi.com'),
      ]),
    );
    final result = await scraper.getDetail('1');
    expect(result.id, '1');
    expect(result.source, 'LziApi');
    expect(result.episodes!.single.id, 'ep_1');
    expect(result.episodes!.single.playUrl, contains('vod1.maowushi.com'));
  });
  for (final candidate in [
    _video(900, title: '番剧 第二季', host: 'vod1.maowushi.com'),
    _video(900, year: '2025', host: 'vod1.maowushi.com'),
    _video(900, year: '', host: 'vod1.maowushi.com'),
  ]) {
    test(
      '拒绝不确定的同名作品匹配: ${candidate['vod_name']} ${candidate['vod_year']}',
      () async {
        respond(
          (o) => _list([o.uri.host == 'cj.lziapi.com' ? _video(1) : candidate]),
        );
        expect(
          (await scraper.getDetail('1')).episodes!.single.playUrl,
          contains('slow.example'),
        );
      },
    );
  }
  test('详情备用请求失败仍保留可用主源', () async {
    respond(
      (o) => o.uri.host == 'cj.lziapi.com' ? _list([_video(1)]) : _fail(o),
    );
    expect((await scraper.getDetail('1')).id, '1');
  });
  test('详情兼容字符串成功状态', () async {
    respond(
      (o) => {
        'code': '1',
        'list': [_video(1, host: 'vod1.maowushi.com')],
      },
    );
    expect((await scraper.getDetail('1')).id, '1');
  });
  test('详情不接受与请求 ID 不一致的作品', () async {
    respond((o) => _list([_video(2)]));
    await expectLater(scraper.getDetail('1'), throwsException);
    expect(adapter.requests.length, 1);
  });
  test('未知来源不发出请求', () async {
    respond((o) => _list([]));
    await expectLater(scraper.getDetail('unknown:1'), throwsException);
    expect(adapter.requests, isEmpty);
  });
  test('切换剧集地址时保持主源剧集顺序', () async {
    respond((o) {
      final primary = o.uri.host == 'cj.lziapi.com';
      return _list([
        {
          ..._video(primary ? 1 : 900),
          'vod_play_url':
              primary
                  ? r'第1集$https://slow.example/1.m3u8#第2集$https://slow.example/2.m3u8'
                  : r'第2集$https://vod1.maowushi.com/2.m3u8#第1集$https://vod1.maowushi.com/1.m3u8',
        },
      ]);
    });
    final episodes = (await scraper.getDetail('1')).episodes!;
    expect(episodes.map((e) => e.id), ['ep_1', 'ep_2']);
    expect(episodes.map((e) => e.title), ['第1集', '第2集']);
    expect(episodes.map((e) => e.playUrl), [
      'https://vod1.maowushi.com/1.m3u8',
      'https://vod1.maowushi.com/2.m3u8',
    ]);
  });
  test('备用源剧集缺失时保持主源列表', () async {
    respond(
      (o) => _list([
        o.uri.host == 'cj.lziapi.com'
            ? {
              ..._video(1),
              'vod_play_url':
                  r'第1集$https://slow.example/1.m3u8#第2集$https://slow.example/2.m3u8',
            }
            : _video(900, host: 'vod1.maowushi.com'),
      ]),
    );
    final episodes = (await scraper.getDetail('1')).episodes!;
    expect(episodes.length, 2);
    expect(episodes.first.playUrl, contains('slow.example'));
  });
}
