import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/core/utils/history_resume.dart';
import 'package:nova_play/models/history_item.dart';
import 'package:nova_play/models/video_model.dart';

EpisodeModel _episode(String title, String url, {String? playUrl}) {
  return EpisodeModel(id: title, title: title, url: url, playUrl: playUrl);
}

HistoryItem _history({int index = 0, List<EpisodeModel>? episodes}) {
  return HistoryItem(
    videoId: 'v1',
    title: 'QA Sample',
    cover: 'cover-old.jpg',
    episodes:
        episodes ?? [_episode('第01集', 'old-ep1'), _episode('第02集', 'old-ep2')],
    episodeIndex: index,
    position: const Duration(seconds: 42),
    watchedAt: DateTime(2026, 11, 4, 12, 0, 0),
  );
}

void main() {
  test('R4：续播刷新详情，使用新播放地址而不是历史快照', () async {
    final item = _history(index: 1);
    final target = await resolveHistoryResumeTarget(
      item,
      fetchDetail:
          () async => VideoModel(
            id: 'v1',
            title: 'QA Sample',
            cover: 'cover-new.jpg',
            episodes: [
              _episode('第01集', 'new-ep1', playUrl: 'https://cdn/new-1.m3u8'),
              _episode('第02集', 'new-ep2', playUrl: 'https://cdn/new-2.m3u8'),
            ],
          ),
    );

    expect(target, isNotNull);
    expect(target!.videoUrl, 'https://cdn/new-2.m3u8');
    expect(target.index, 1);
    expect(target.cover, 'cover-new.jpg');
    expect(target.episodes.length, 2);
  });

  test('R4：剧集重排时按标题匹配，而不是沿用旧位置', () async {
    final item = _history(index: 1);
    final target = await resolveHistoryResumeTarget(
      item,
      fetchDetail:
          () async => VideoModel(
            id: 'v1',
            title: 'QA Sample',
            episodes: [
              _episode('第02集', 'new-ep2', playUrl: 'https://cdn/new-2.m3u8'),
              _episode('第01集', 'new-ep1', playUrl: 'https://cdn/new-1.m3u8'),
            ],
          ),
    );

    expect(target, isNotNull);
    expect(target!.videoUrl, 'https://cdn/new-2.m3u8');
    expect(target.index, 0);
  });

  test('R4：详情刷新失败时返回 null（调用方回退详情页）', () async {
    final target = await resolveHistoryResumeTarget(
      _history(),
      fetchDetail: () async => null,
    );
    expect(target, isNull);
  });

  test('R4：详情抛异常时返回 null，不使用过期快照', () async {
    final target = await resolveHistoryResumeTarget(
      _history(),
      fetchDetail: () async => throw Exception('network down'),
    );
    expect(target, isNull);
  });

  test('R4：新详情缺少对应剧集时返回 null', () async {
    final item = _history(index: 1);
    final target = await resolveHistoryResumeTarget(
      item,
      fetchDetail:
          () async => VideoModel(
            id: 'v1',
            title: 'QA Sample',
            episodes: [
              _episode('第01集', 'new-ep1', playUrl: 'https://cdn/new-1.m3u8'),
            ],
          ),
    );
    expect(target, isNull);
  });

  test('R4：详情没有剧集或播放地址为空时返回 null', () async {
    final noEpisodes = await resolveHistoryResumeTarget(
      _history(),
      fetchDetail: () async => VideoModel(id: 'v1', title: 'QA Sample'),
    );
    expect(noEpisodes, isNull);

    final emptyUrl = await resolveHistoryResumeTarget(
      _history(),
      fetchDetail:
          () async => VideoModel(
            id: 'v1',
            title: 'QA Sample',
            episodes: [_episode('第01集', '')],
          ),
    );
    expect(emptyUrl, isNull);
  });
}
