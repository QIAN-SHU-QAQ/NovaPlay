import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/core/utils/history_resume.dart';
import 'package:nova_play/models/history_item.dart';
import 'package:nova_play/models/video_model.dart';

EpisodeModel _episode(String id, String title, String url, {String? playUrl}) {
  return EpisodeModel(id: id, title: title, url: url, playUrl: playUrl);
}

HistoryItem _history({
  int index = 0,
  List<EpisodeModel>? episodes,
  String? sourceId,
  String title = 'QA Sample',
  String videoId = 'v1',
}) {
  return HistoryItem(
    videoId: videoId,
    title: title,
    cover: 'cover-old.jpg',
    sourceId: sourceId,
    episodes:
        episodes ??
        [
          _episode('ep1', '第01集', 'old-ep1'),
          _episode('ep2', '第02集', 'old-ep2'),
        ],
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
              _episode(
                'ep1',
                '第01集',
                'new-ep1',
                playUrl: 'https://cdn/new-1.m3u8',
              ),
              _episode(
                'ep2',
                '第02集',
                'new-ep2',
                playUrl: 'https://cdn/new-2.m3u8',
              ),
            ],
          ),
    );

    expect(target, isNotNull);
    expect(target!.videoUrl, 'https://cdn/new-2.m3u8');
    expect(target.index, 1);
    expect(target.cover, 'cover-new.jpg');
    expect(target.episodes.map((e) => e['id']), ['ep1', 'ep2']);
  });

  test('R4：剧集重排时按稳定剧集 ID 匹配，而不是沿用旧位置', () async {
    final item = _history(index: 1);
    final target = await resolveHistoryResumeTarget(
      item,
      fetchDetail:
          () async => VideoModel(
            id: 'v1',
            title: 'QA Sample',
            episodes: [
              _episode(
                'ep2',
                '第02集',
                'new-ep2',
                playUrl: 'https://cdn/new-2.m3u8',
              ),
              _episode(
                'ep1',
                '第01集',
                'new-ep1',
                playUrl: 'https://cdn/new-1.m3u8',
              ),
            ],
          ),
    );

    expect(target, isNotNull);
    expect(target!.videoUrl, 'https://cdn/new-2.m3u8');
    expect(target.index, 0);
  });

  test('R4：原集在新列表中缺失时返回 null，不按下标播放别的集', () async {
    final item = _history(index: 1);
    final target = await resolveHistoryResumeTarget(
      item,
      fetchDetail:
          () async => VideoModel(
            id: 'v1',
            title: 'QA Sample',
            episodes: [
              _episode(
                'ep1',
                '第01集',
                'new-ep1',
                playUrl: 'https://cdn/new-1.m3u8',
              ),
              _episode(
                'ep3',
                '第03集',
                'new-ep3',
                playUrl: 'https://cdn/new-3.m3u8',
              ),
            ],
          ),
    );
    expect(target, isNull);
  });

  test('R4：重复标题无法唯一确认时返回 null', () async {
    final item = _history(index: 1);
    final target = await resolveHistoryResumeTarget(
      item,
      fetchDetail:
          () async => VideoModel(
            id: 'v1',
            title: 'QA Sample',
            episodes: [
              _episode('a1', '第02集', 'a1'),
              _episode('a2', '第02集', 'a2'),
            ],
          ),
    );
    expect(target, isNull);
  });

  test('R4：空剧集快照返回 null，不默认播放首集', () async {
    final target = await resolveHistoryResumeTarget(
      _history(index: 0, episodes: const []),
      fetchDetail:
          () async => VideoModel(
            id: 'v1',
            title: 'QA Sample',
            episodes: [_episode('ep1', '第01集', 'new-ep1')],
          ),
    );
    expect(target, isNull);
  });

  test('R4：来源身份不符时拒绝（裸 ID 在别的源指向另一作品）', () async {
    final item = _history(sourceId: '源A');
    final target = await resolveHistoryResumeTarget(
      item,
      fetchDetail:
          () async => VideoModel(
            id: 'v1',
            title: 'QA Sample',
            source: '源B',
            episodes: [_episode('ep1', '第01集', 'b-ep1')],
          ),
    );
    expect(target, isNull);
  });

  test('R4：旧历史没有来源标识时用标题兜底，标题不符即拒绝', () async {
    final item = _history();
    final target = await resolveHistoryResumeTarget(
      item,
      fetchDetail:
          () async => VideoModel(
            id: 'v1',
            title: '完全不同的作品',
            episodes: [_episode('ep1', '第01集', 'x-ep1')],
          ),
    );
    expect(target, isNull);
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

  test('R4：播放地址为空时返回 null', () async {
    final target = await resolveHistoryResumeTarget(
      _history(),
      fetchDetail:
          () async => VideoModel(
            id: 'v1',
            title: 'QA Sample',
            episodes: [_episode('ep1', '第01集', '')],
          ),
    );
    expect(target, isNull);
  });
}
