import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/models/danmaku_model.dart';
import 'package:nova_play/services/danmaku/dandanplay_client.dart';

class _FakeHttpAdapter implements HttpClientAdapter {
  _FakeHttpAdapter(this.responses);

  final Map<String, String> responses;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = responses[options.uri.path];
    if (body == null) {
      return ResponseBody.fromString(
        jsonEncode({'errorCode': 404, 'errorMessage': 'not found'}),
        404,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('签名算法', () {
    test('与已知向量一致', () {
      final signature = DandanplayClient.signature(
        'nova_test',
        1700000000,
        '/api/v2/comment/12345',
        's3cr3t',
      );
      expect(signature, '2LsQ0PlsnH89QV+OaOzCKIw0jitixAS7DUEoxUsGefY=');
    });
  });

  group('弹幕解析', () {
    test('滚动弹幕：时间/颜色/文本', () {
      final comment = DanmakuComment.tryParse(
        cid: 1,
        p: '12.5,1,16777215,123456',
        text: '前方高能',
      );
      expect(comment, isNotNull);
      expect(comment!.time, const Duration(milliseconds: 12500));
      expect(comment.type, DanmakuType.scroll);
      expect(comment.color, const Color(0xFFFFFFFF));
      expect(comment.text, '前方高能');
    });

    test('顶部/底部弹幕映射正确', () {
      expect(
        DanmakuComment.tryParse(cid: 2, p: '1,5,255,1', text: '顶部')?.type,
        DanmakuType.top,
      );
      expect(
        DanmakuComment.tryParse(cid: 3, p: '1,4,255,1', text: '底部')?.type,
        DanmakuType.bottom,
      );
    });

    test('特殊弹幕与非法数据被忽略', () {
      expect(
        DanmakuComment.tryParse(cid: 4, p: '1,8,255,1', text: '代码'),
        isNull,
      );
      expect(DanmakuComment.tryParse(cid: 5, p: 'bad', text: 'x'), isNull);
      expect(
        DanmakuComment.tryParse(cid: 6, p: '1,1,255,1', text: '  '),
        isNull,
      );
    });
  });

  group('匹配工具', () {
    test('提取集数', () {
      expect(extractEpisodeNumber('第 03 集'), 3);
      expect(extractEpisodeNumber('第2话'), 2);
      expect(extractEpisodeNumber('EP12'), 12);
      expect(extractEpisodeNumber('12'), 12);
      expect(extractEpisodeNumber('OVA 特别篇'), isNull);
    });

    test('标题归一化消除标点与季数', () {
      expect(normalizeDanmakuTitle('【我推的孩子】 第二季'), '我推的孩子');
      expect(normalizeDanmakuTitle('SPY×FAMILY Season 2'), 'spy×family');
    });

    test('相似度匹配与剧集挑选', () {
      expect(titleSimilarity('葬送的芙莉莲', '葬送的芙莉莲'), 1);
      expect(titleSimilarity('葬送的芙莉莲', '葬送的芙莉莲 第二季'), 1);

      final matches = [
        const DanmakuEpisodeMatch(
          episodeId: 111,
          animeTitle: '葬送的芙莉莲',
          episodeTitle: '第1话',
          episodeNumber: '1',
        ),
        const DanmakuEpisodeMatch(
          episodeId: 222,
          animeTitle: '葬送的芙莉莲 第二季',
          episodeTitle: '第5话',
          episodeNumber: '5',
        ),
      ];
      final best = pickBestMatch(matches, '葬送的芙莉莲', 1);
      expect(best?.episodeId, 111);
    });
  });

  group('API 客户端', () {
    test('loadForEpisode 搜索并返回解析后的弹幕', () async {
      final adapter = _FakeHttpAdapter({
        '/api/v2/search/episodes': jsonEncode({
          'errorCode': 0,
          'animes': [
            {
              'animeId': 1,
              'animeTitle': '葬送的芙莉莲',
              'episodes': [
                {'episodeId': 777, 'episodeTitle': '第1话', 'episodeNumber': '1'},
              ],
            },
          ],
        }),
        '/api/v2/comment/777': jsonEncode({
          'errorCode': 0,
          'count': 3,
          'comments': [
            {'cid': 11, 'p': '5.0,1,16777215,9', 'm': '第二条'},
            {'cid': 12, 'p': '1.5,4,16711680,9', 'm': '第一条'},
            {'cid': 13, 'p': '2.0,8,16777215,9', 'm': '特殊弹幕忽略'},
          ],
        }),
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final client = DandanplayClient(
        appId: 'app',
        appSecret: 'secret',
        dio: dio,
        baseUrl: 'https://fake.local',
      );

      final result = await client.loadForEpisode(
        animeTitle: '葬送的芙莉莲',
        episodeTitle: '第 1 集',
        episodeIndex: 0,
      );

      expect(result, isNotNull);
      expect(result!.episodeId, 777);
      expect(result.comments.map((c) => c.text), ['第一条', '第二条']);
      expect(result.comments.first.time, const Duration(milliseconds: 1500));

      // 请求头带上了签名信息
      final headers = adapter.requests.first.headers;
      expect(headers['X-AppId'], 'app');
      expect(headers['X-Timestamp'], isNotNull);
      expect(headers['X-Signature'], isA<String>());
      final signature = headers['X-Signature'] as String;
      expect(signature.isNotEmpty, isTrue);
    });

    test('搜索为空时返回 null', () async {
      final adapter = _FakeHttpAdapter({
        '/api/v2/search/episodes': jsonEncode({
          'errorCode': 0,
          'animes': <dynamic>[],
        }),
      });
      final client = DandanplayClient(
        appId: 'app',
        appSecret: 'secret',
        dio: Dio()..httpClientAdapter = adapter,
        baseUrl: 'https://fake.local',
      );
      expect(
        await client.loadForEpisode(
          animeTitle: '不存在的作品',
          episodeTitle: '第1集',
          episodeIndex: 0,
        ),
        isNull,
      );
    });

    test('401 给出凭据错误提示', () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeHttpAdapter({});
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 401),
              ),
            );
          },
        ),
      );
      final client = DandanplayClient(
        appId: 'bad',
        appSecret: 'bad',
        dio: dio,
        baseUrl: 'https://fake.local',
      );
      expect(
        () => client.searchEpisodes(anime: '测试'),
        throwsA(
          isA<DandanplayException>().having(
            (e) => e.message,
            'message',
            contains('AppId'),
          ),
        ),
      );
    });
  });
}
