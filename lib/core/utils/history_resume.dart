import '../../models/history_item.dart';
import '../../models/video_model.dart';

/// 续播目标：刷新详情后重新解析出的播放参数。
class HistoryResumeTarget {
  const HistoryResumeTarget({
    required this.videoUrl,
    required this.title,
    required this.episodes,
    required this.index,
    required this.videoTitle,
    this.cover,
  });

  final String videoUrl;
  final String title;
  final List<Map<String, String>> episodes;
  final int index;
  final String videoTitle;
  final String? cover;
}

/// 从历史记录解析「继续播放」目标（R4）。
///
/// 历史里保存的是播放时的剧集快照，地址可能已经过期。续播时必须先用
/// [fetchDetail] 重新拉取作品详情，找到对应的集：
/// - 优先按集标题匹配（列表重排/增减时比位置可靠）；
/// - 标题匹配不到时退回原来的集下标；
/// - 详情刷新失败、没有剧集、或找不到/拿不到播放地址时返回 null，
///   由调用方回退到作品详情页，避免播放错误地址。
Future<HistoryResumeTarget?> resolveHistoryResumeTarget(
  HistoryItem item, {
  required Future<VideoModel?> Function() fetchDetail,
}) async {
  VideoModel? fresh;
  try {
    fresh = await fetchDetail();
  } catch (_) {
    fresh = null;
  }
  final episodes = fresh?.episodes;
  if (fresh == null || episodes == null || episodes.isEmpty) return null;

  final snapshotTitle = item.episodeTitle;
  var index = item.episodeIndex;
  if (snapshotTitle != null && snapshotTitle.isNotEmpty) {
    final matched = episodes.indexWhere((e) => e.title == snapshotTitle);
    if (matched >= 0) index = matched;
  }
  if (index < 0 || index >= episodes.length) return null;

  final episode = episodes[index];
  final playUrl = episode.playUrl ?? episode.url;
  if (playUrl.isEmpty) return null;

  return HistoryResumeTarget(
    videoUrl: playUrl,
    title: '${fresh.title} - ${episode.title}',
    episodes:
        episodes
            .map((e) => {'title': e.title, 'url': e.playUrl ?? e.url})
            .toList(),
    index: index,
    videoTitle: fresh.title,
    cover: fresh.cover ?? item.cover,
  );
}
