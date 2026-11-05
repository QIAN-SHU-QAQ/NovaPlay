import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/core/utils/episode_identity.dart';
import 'package:nova_play/core/utils/history_resume.dart';
import 'package:nova_play/models/history_item.dart';
import 'package:nova_play/models/video_model.dart';
import 'package:nova_play/services/database_service.dart';
import 'package:nova_play/services/scraper/lziapi_scraper.dart';
import 'package:nova_play/services/scraper/source_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用真实 LziApiScraper + 本地 HTTP 替身验证：解析器按位置生成 ep_N，
/// 刷新重排后 ep_N 会指向别的剧集，续播必须按页面 URL/唯一标题定位。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_test 默认用 HttpOverrides 拦截所有网络请求（返回 400）；
  // 本测试需要真实连接 loopback 上的本地 HTTP 替身。
  setUpAll(() {
    HttpOverrides.global = null;
  });

  late HttpServer server;
  late String playlist;
  late LziApiScraper scraper;

  setUp(() async {
    playlist = '第1集\$https://site/ep1#第2集\$https://site/ep2';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await request.drain<void>();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'application',
          'json',
          charset: 'utf-8',
        );
        request.response.write(
          jsonEncode({
            'code': 1,
            'list': [
              {
                'vod_id': 42,
                'vod_name': 'QA Sample',
                'vod_pic': 'https://site/cover.jpg',
                'vod_content': 'QA',
                'vod_year': '2024',
                'vod_score': '8.0',
                'vod_class': '动画',
                'vod_play_url': playlist,
              },
            ],
          }),
        );
        await request.response.close();
      } catch (e) {
        debugPrint('local test server error: $e');
      }
    });
    scraper = LziApiScraper(
      primary: SourceConfig(
        id: 'local',
        name: '本地测试源',
        baseUrl: 'http://127.0.0.1:${server.port}/api.php/provide/vod/',
      ),
      fallbacks: const [],
    );
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('R4：真实解析器的位置生成 ep_N 重排后按页面 URL 定位', () async {
    final first = await scraper.getDetail('42');
    // 证明解析器确实是按位置生成 ID。
    expect(first.episodes!.map((e) => e.id), ['ep_1', 'ep_2']);

    final history = HistoryItem(
      videoId: first.id,
      title: first.title,
      episodes: first.episodes!,
      episodeIndex: 1,
      position: const Duration(minutes: 10),
      watchedAt: DateTime(2026, 11, 5, 10),
    );

    // 刷新后剧集重排：ep_1 现在指向第2集，旧位置 ID 不可信。
    playlist = '第2集\$https://site/ep2#第1集\$https://site/ep1';
    final target = await resolveHistoryResumeTarget(
      history,
      fetchDetail: () => scraper.getDetail('42'),
    );

    expect(target, isNotNull);
    expect(target!.index, 0, reason: '应按 pageUrl 命中第2集的新位置');
    expect(target.videoUrl, 'https://site/ep2');
  });

  test('R4：真实解析器刷新后原集缺失时不按位置播别的集', () async {
    final first = await scraper.getDetail('42');
    final history = HistoryItem(
      videoId: first.id,
      title: first.title,
      episodes: first.episodes!,
      episodeIndex: 1,
      position: const Duration(minutes: 10),
      watchedAt: DateTime(2026, 11, 5, 10),
    );

    playlist = '第1集\$https://site/ep1#第3集\$https://site/ep3';
    final target = await resolveHistoryResumeTarget(
      history,
      fetchDetail: () => scraper.getDetail('42'),
    );
    expect(target, isNull);
  });

  test('R5：真实源媒体地址轮换并重启后，手动弹幕关联仍保留', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);

    List<Map<String, String>> episodeMaps(VideoModel detail) {
      return detail.episodes!
          .map(
            (e) => {
              'id': e.id,
              'title': e.title,
              'url': e.playUrl ?? e.url,
              'pageUrl': e.url,
              'media': e.urlIsMediaPlayback ? 'true' : 'false',
            },
          )
          .toList();
    }

    // 真实 LziApi 的 vod_play_url 是直接媒体地址，甚至可能没有扩展名。
    playlist = '第1集\$https://cdn.test/hls/old1#第2集\$https://cdn.test/hls/old2';
    final first = await scraper.getDetail('42');
    final firstMaps = episodeMaps(first);
    expect(firstMaps[1]['media'], 'true', reason: 'LziApi 地址必须标记为媒体地址');
    final identity = episodeIdentityFromMap(firstMaps[1], firstMaps);
    expect(identity, isNotNull);
    expect(identity, contains('第2集'), reason: '直接媒体地址（即使无扩展名）不能作为身份，应使用唯一标题');

    final mappingKey = DatabaseService.danmakuMappingEntryKey(
      first.id,
      identity!,
    );
    await db.setDanmakuMapping(mappingKey, {
      'episodeId': 222,
      'animeTitle': 'QA Sample',
      'episodeTitle': '第2话',
    });

    // 模拟进程重启（prefs 保留）。
    db.resetForTest();
    await db.init();
    expect(db.getDanmakuMapping(mappingKey)?['episodeId'], 222);

    // 源刷新：媒体地址轮换（old→new），列表位置/标题不变。
    playlist = '第1集\$https://cdn.test/hls/new1#第2集\$https://cdn.test/hls/new2';
    final refreshed = await scraper.getDetail('42');
    final newMaps = episodeMaps(refreshed);
    final newIdentity = episodeIdentityFromMap(newMaps[1], newMaps);
    expect(newIdentity, identity, reason: '地址轮换后关联键必须不变');

    final newKey = DatabaseService.danmakuMappingEntryKey(
      refreshed.id,
      newIdentity!,
    );
    expect(newKey, mappingKey);
    expect(
      db.getDanmakuMapping(newKey)?['episodeId'],
      222,
      reason: '重启 + 地址轮换后仍应读到手选关联',
    );

    // 续播本身也应拿到新地址。
    final history = HistoryItem(
      videoId: first.id,
      title: first.title,
      episodes: first.episodes!,
      episodeIndex: 1,
      position: const Duration(minutes: 10),
      watchedAt: DateTime(2026, 11, 5, 10),
    );
    final target = await resolveHistoryResumeTarget(
      history,
      fetchDetail: () => scraper.getDetail('42'),
    );
    expect(target, isNotNull);
    expect(target!.videoUrl, 'https://cdn.test/hls/new2');
  });

  test('R5：备用源替换播放地址时保留媒体标记，重启后关联仍保留', () async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);

    var fallbackPlaylist =
        '第1集\$https://cdn.test/hls/old1#第2集\$https://cdn.test/hls/old2';
    final fallbackServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() async => fallbackServer.close(force: true));
    fallbackServer.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      request.response.write(
        jsonEncode({
          'code': 1,
          'list': [
            {
              'vod_id': 99,
              'vod_name': 'QA Sample',
              'vod_pic': 'https://site/cover.jpg',
              'vod_content': 'QA',
              'vod_year': '2024',
              'vod_score': '8.0',
              'vod_class': '动画',
              'vod_play_url': fallbackPlaylist,
            },
          ],
        }),
      );
      await request.response.close();
    });

    final multiSource = LziApiScraper(
      primary: SourceConfig(
        id: 'lziapi',
        name: 'LziApi',
        baseUrl: 'http://127.0.0.1:${server.port}/api.php/provide/vod/',
      ),
      fallbacks: [
        SourceConfig(
          id: 'fallback',
          name: 'Fallback',
          baseUrl:
              'http://127.0.0.1:${fallbackServer.port}/api.php/provide/vod/',
        ),
      ],
    );

    List<Map<String, String>> episodeMaps(VideoModel detail) {
      return detail.episodes!
          .map(
            (e) => {
              'id': e.id,
              'title': e.title,
              'url': e.playUrl ?? e.url,
              'pageUrl': e.url,
              'media': e.urlIsMediaPlayback ? 'true' : 'false',
            },
          )
          .toList();
    }

    // 主源详情行为触发备用源替换路径：备用源地址是直接媒体地址。
    final first = await multiSource.getDetail('42');
    final firstMaps = episodeMaps(first);
    expect(
      firstMaps[1]['url'],
      'https://cdn.test/hls/old2',
      reason: '备用源替换后应使用备用源地址',
    );
    expect(firstMaps[1]['media'], 'true', reason: '替换路径必须保留媒体地址标记');
    final identity = episodeIdentityFromMap(firstMaps[1], firstMaps);
    expect(identity, 'title:第2集');

    final mappingKey = DatabaseService.danmakuMappingEntryKey(
      first.id,
      identity!,
    );
    await db.setDanmakuMapping(mappingKey, {
      'episodeId': 222,
      'animeTitle': 'QA Sample',
      'episodeTitle': '第2话',
    });

    // 模拟重启后备用源地址轮换（old2 → new2）。
    db.resetForTest();
    await db.init();
    fallbackPlaylist =
        '第1集\$https://cdn.test/hls/new1#第2集\$https://cdn.test/hls/new2';
    final refreshed = await multiSource.getDetail('42');
    final newMaps = episodeMaps(refreshed);
    expect(newMaps[1]['media'], 'true');
    final newIdentity = episodeIdentityFromMap(newMaps[1], newMaps);
    expect(newIdentity, identity, reason: '备用源地址轮换后关联键必须不变');
    expect(
      db.getDanmakuMapping(
        DatabaseService.danmakuMappingEntryKey(refreshed.id, newIdentity!),
      )?['episodeId'],
      222,
    );
    expect(refreshed.episodes![1].url, 'https://cdn.test/hls/new2');
  });
}
