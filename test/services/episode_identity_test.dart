import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/core/utils/episode_identity.dart';

void main() {
  test('R5：位置生成的 ep_N 不算稳定剧集 ID', () {
    expect(isStableEpisodeId('ep_1'), isFalse);
    expect(isStableEpisodeId('ep_12'), isFalse);
    expect(isStableEpisodeId(''), isFalse);
    expect(isStableEpisodeId(null), isFalse);
    expect(isStableEpisodeId('stable-123'), isTrue);
    expect(isStableEpisodeId('movie-ep-2'), isTrue);
  });

  test('R5：剧集重排后按 pageUrl 计算的身份保持一致', () {
    final before = [
      {'id': 'ep_1', 'title': '第1集', 'pageUrl': 'https://site/ep1'},
      {'id': 'ep_2', 'title': '第2集', 'pageUrl': 'https://site/ep2'},
    ];
    final after = [
      {'id': 'ep_1', 'title': '第2集', 'pageUrl': 'https://site/ep2'},
      {'id': 'ep_2', 'title': '第1集', 'pageUrl': 'https://site/ep1'},
    ];
    final identityBefore = episodeIdentityFromMap(before[1], before);
    final identityAfter = episodeIdentityFromMap(after[0], after);
    expect(identityBefore, isNotNull);
    expect(identityBefore, identityAfter);
    expect(identityBefore, contains('site/ep2'));
  });

  test('R5：没有 pageUrl 时只在标题唯一时使用标题', () {
    final unique = [
      {'id': 'ep_1', 'title': '第1集'},
      {'id': 'ep_2', 'title': '第2集'},
    ];
    expect(episodeIdentityFromMap(unique[1], unique), 'title:第2集');

    final duplicated = [
      {'id': 'ep_1', 'title': '第1集'},
      {'id': 'ep_2', 'title': '第1集'},
    ];
    expect(episodeIdentityFromMap(duplicated[1], duplicated), isNull);

    final noInfo = [
      {'id': 'ep_1'},
      {'id': 'ep_2'},
    ];
    expect(episodeIdentityFromMap(noInfo[1], noInfo), isNull);
  });

  test('R5：来源稳定 ID 优先于 pageUrl', () {
    final episodes = [
      {'id': 'stable-aaa', 'title': '第1集', 'pageUrl': 'https://site/ep1'},
      {'id': 'stable-bbb', 'title': '第2集', 'pageUrl': 'https://site/ep2'},
    ];
    expect(episodeIdentityFromMap(episodes[1], episodes), 'id:stable-bbb');
  });

  test('R5：易失媒体地址不能当页面身份，改为唯一标题', () {
    final oldEpisodes = [
      {
        'id': 'ep_1',
        'title': '第1集',
        'pageUrl': 'https://cdn.test/hls/old1.m3u8',
      },
      {
        'id': 'ep_2',
        'title': '第2集',
        'pageUrl': 'https://cdn.test/hls/old2.m3u8',
      },
    ];
    final refreshed = [
      {
        'id': 'ep_1',
        'title': '第1集',
        'pageUrl': 'https://cdn.test/hls/new1.m3u8',
      },
      {
        'id': 'ep_2',
        'title': '第2集',
        'pageUrl': 'https://cdn.test/hls/new2.m3u8?sign=rotated',
      },
    ];
    final before = episodeIdentityFromMap(oldEpisodes[1], oldEpisodes);
    final after = episodeIdentityFromMap(refreshed[1], refreshed);
    expect(before, 'title:第2集');
    expect(after, before, reason: '媒体地址轮换后关联键必须保持不变');
    expect(isVolatileMediaUrl('https://x/a.m3u8?sign=1'), isTrue);
    expect(isVolatileMediaUrl('https://site/episode/2'), isFalse);
  });

  test('R5：媒体地址 + 重复标题时无法确认身份', () {
    final episodes = [
      {'id': 'ep_1', 'title': '第1集', 'pageUrl': 'https://cdn/a.m3u8'},
      {'id': 'ep_2', 'title': '第1集', 'pageUrl': 'https://cdn/b.m3u8'},
    ];
    expect(episodeIdentityFromMap(episodes[1], episodes), isNull);
  });
}
