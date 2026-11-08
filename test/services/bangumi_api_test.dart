import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/services/bangumi_api.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);

  /// path → (status, body)
  final Map<String, (int, Object?)> responses;
  final List<String> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    requests.add(path);
    final response = responses[path];
    if (response == null) {
      return ResponseBody.fromString(
        jsonEncode({'error': 'not found'}),
        404,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    final (status, body) = response;
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _searchResponse(List<Map<String, dynamic>> subjects) {
  return {
    'data': [
      for (final subject in subjects)
        {
          'id': subject['id'],
          'name': subject['name'],
          'name_cn': subject['name_cn'],
          'date': subject['date'],
          'type': 2,
        },
    ],
  };
}

Map<String, dynamic> _subjectResponse(int id) {
  return {
    'id': id,
    'name': 'QA Sample',
    'name_cn': 'QA 样本',
    'date': '2024-01-01',
    'rating': {'score': 8.6, 'total': 1234},
    'infobox': [
      {'key': '导演', 'value': 'QA Director'},
      {'key': '动画制作', 'value': 'QA Studio'},
      {'key': '放送开始', 'value': '2024-01-01'},
    ],
  };
}

BangumiApi _api(_FakeAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return BangumiApi(dio: dio);
}

void main() {
  test('R7：多个候选中按相似度选择，不直接取首项', () async {
    final adapter = _FakeAdapter({
      '/v0/search/subjects': (
        200,
        _searchResponse([
          {
            'id': 1,
            'name': 'QA Sample',
            'name_cn': 'QA 样本',
            'date': '2020-01-01',
          },
          {
            'id': 2,
            'name': 'QA Sample Season 2',
            'name_cn': 'QA 样本 第二季',
            'date': '2024-01-01',
          },
        ]),
      ),
      '/v0/subjects/2': (200, _subjectResponse(2)),
      '/v0/subjects/2/characters': (
        200,
        [
          {'name': 'QA 主角', 'images': {}, 'actors': []},
        ],
      ),
    });
    final api = _api(adapter);

    final info = await api.fetchInfo('QA 样本 第二季');
    expect(info, isNotNull);
    expect(info!.subjectId, 2);
    expect(info.matchedTitle, isNotNull);
  });

  test('R7：相似度不足返回 null，不再硬用无关首项', () async {
    final adapter = _FakeAdapter({
      '/v0/search/subjects': (
        200,
        _searchResponse([
          {'id': 9, 'name': '完全无关的动画', 'name_cn': '', 'date': '2019-01-01'},
        ]),
      ),
      '/v0/subjects/9': (200, _subjectResponse(9)),
    });
    final api = _api(adapter);

    expect(await api.fetchInfo('QA 样本 第二季'), isNull);
  });

  test('R7：手动指定 subjectId 时跳过搜索并直接拉取', () async {
    final adapter = _FakeAdapter({
      '/v0/subjects/777': (200, _subjectResponse(777)),
      '/v0/subjects/777/characters': (200, []),
    });
    final api = _api(adapter);

    final info = await api.fetchInfo('任意标题', subjectId: 777);
    expect(info, isNotNull);
    expect(info!.subjectId, 777);
    expect(info.score, 8.6);
    expect(info.staff.map((s) => s.role), contains('导演'));
    expect(adapter.requests, contains('/v0/subjects/777'));
    expect(adapter.requests, isNot(contains('/v0/search/subjects')));
  });

  test('R7：角色接口失败时仍返回评分/制作人员（部分降级）', () async {
    final adapter = _FakeAdapter({
      '/v0/subjects/5': (200, _subjectResponse(5)),
      '/v0/subjects/5/characters': (500, {'error': 'server error'}),
    });
    final api = _api(adapter);

    final info = await api.fetchInfo('QA 样本', subjectId: 5);
    expect(info, isNotNull);
    expect(info!.score, 8.6);
    expect(info.staff, isNotEmpty);
    expect(info.characters, isEmpty);
  });

  test('R7：主体接口失败返回 null，不抛异常', () async {
    final adapter = _FakeAdapter({
      '/v0/subjects/6': (500, {'error': 'server error'}),
    });
    final api = _api(adapter);
    expect(await api.fetchInfo('QA 样本', subjectId: 6), isNull);
  });

  test('R7：明确季号冲突的候选被排除，只用第一季候选时返回 null', () async {
    final adapter = _FakeAdapter({
      '/v0/search/subjects': (
        200,
        _searchResponse([
          {
            'id': 11,
            'name': 'QA Sample',
            'name_cn': 'QA 样本 第一季',
            'date': '2020-01-01',
          },
        ]),
      ),
      '/v0/subjects/11': (200, _subjectResponse(11)),
    });
    final api = _api(adapter);

    expect(await api.fetchInfo('QA 样本 第二季'), isNull);
    // 不应请求被排除的第一季资料。
    expect(adapter.requests, isNot(contains('/v0/subjects/11')));
  });

  test('R7：同名不同年份候选无法唯一确定时不自动取首项', () async {
    final adapter = _FakeAdapter({
      '/v0/search/subjects': (
        200,
        _searchResponse([
          {
            'id': 21,
            'name': 'QA Sample',
            'name_cn': 'QA 样本',
            'date': '2015-01-01',
          },
          {
            'id': 22,
            'name': 'QA Sample',
            'name_cn': 'QA 样本',
            'date': '2024-01-01',
          },
        ]),
      ),
      '/v0/subjects/21': (200, _subjectResponse(21)),
      '/v0/subjects/22': (200, _subjectResponse(22)),
    });
    final api = _api(adapter);

    expect(await api.fetchInfo('QA 样本'), isNull);
  });

  test('P1：搜索网络失败返回不可用（详情页可重试），而不是无匹配', () async {
    final adapter = _FakeAdapter({
      '/v0/search/subjects': (500, {'error': 'timeout'}),
    });
    final api = _api(adapter);

    final result = await api.lookup('QA 样本');
    expect(result.status, BangumiLookupStatus.unavailable);
    expect(result.info, isNull);
  });

  test('P1：空候选返回无匹配（详情页可手选）', () async {
    final adapter = _FakeAdapter({
      '/v0/search/subjects': (200, _searchResponse(const [])),
    });
    final api = _api(adapter);

    final result = await api.lookup('QA 样本');
    expect(result.status, BangumiLookupStatus.noMatch);
    expect(result.info, isNull);
  });

  test('P1：主体可用但角色接口失败时返回部分资料', () async {
    final adapter = _FakeAdapter({
      '/v0/subjects/5': (200, _subjectResponse(5)),
      '/v0/subjects/5/characters': (500, {'error': 'server error'}),
    });
    final api = _api(adapter);

    final result = await api.lookup('QA 样本', subjectId: 5);
    expect(result.status, BangumiLookupStatus.success);
    expect(result.partial, isTrue);
    expect(result.info!.score, 8.6);
    expect(result.info!.staff, isNotEmpty);
    expect(result.info!.characters, isEmpty);
  });

  test('P2：角色字段格式异常时只降级角色，保留主体评分/制作人员', () async {
    final adapter = _FakeAdapter({
      '/v0/subjects/8': (200, _subjectResponse(8)),
      '/v0/subjects/8/characters': (
        200,
        [
          {
            'name': 'QA 主角',
            'images': {},
            // actors 应为数组，这里故意给对象触发解析异常。
            'actors': {'name': 'QA CV'},
          },
        ],
      ),
    });
    final api = _api(adapter);

    final result = await api.lookup('QA 样本', subjectId: 8);
    expect(result.status, BangumiLookupStatus.success);
    expect(result.partial, isTrue);
    expect(result.info!.score, 8.6);
    expect(result.info!.staff, isNotEmpty);
    expect(result.info!.characters, isEmpty);
  });
  test('P1：主体接口失败返回不可用', () async {
    final adapter = _FakeAdapter({
      '/v0/subjects/6': (500, {'error': 'server error'}),
    });
    final api = _api(adapter);

    final result = await api.lookup('QA 样本', subjectId: 6);
    expect(result.status, BangumiLookupStatus.unavailable);
  });
}
