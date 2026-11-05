import '../../models/history_item.dart';
import '../../models/video_model.dart';
import 'episode_identity.dart';

/// 续播目标：刷新详情后重新解析出的播放参数。
class HistoryResumeTarget {
  const HistoryResumeTarget({
    required this.videoUrl,
    required this.title,
    required this.episodes,
    required this.index,
    required this.videoTitle,
    this.cover,
    this.sourceId,
  });

  final String videoUrl;
  final String title;
  final List<Map<String, String>> episodes;
  final int index;
  final String videoTitle;
  final String? cover;
  final String? sourceId;
}

/// 从历史记录解析「继续播放」目标（R4）。
///
/// 历史里保存的是播放时的剧集快照，地址可能已经过期。续播时必须先用
/// [fetchDetail] 重新拉取作品详情，并确认新详情确实属于原作品：
/// - 作品 ID 必须一致；主源裸 ID 在不同数据源之间会重名，因此还要比对
///   来源标识与标题，身份不符时返回 null（转人工选集）；
/// - 剧集优先用稳定 ID，其次 URL，最后用**唯一**标题定位；
/// - 缺集、重复标题、信息不足或无法唯一确认时返回 null，不再按下标猜；
/// - 详情刷新失败、没有剧集、或拿不到播放地址时返回 null。
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
  if (!_isSameWork(item, fresh)) return null;

  final snapshot = _snapshotEpisode(item);
  if (snapshot == null) return null;
  final index = _matchEpisodeIndex(snapshot, episodes);
  if (index == null) return null;

  final episode = episodes[index];
  final playUrl = episode.playUrl ?? episode.url;
  if (playUrl.isEmpty) return null;

  return HistoryResumeTarget(
    videoUrl: playUrl,
    title: '${fresh.title} - ${episode.title}',
    episodes:
        episodes
            .map(
              (e) => {
                'id': e.id,
                'title': e.title,
                'url': e.playUrl ?? e.url,
                'pageUrl': e.url,
              },
            )
            .toList(),
    index: index,
    videoTitle: fresh.title,
    cover: fresh.cover ?? item.cover,
    sourceId: fresh.source,
  );
}

/// 确认刷新后的详情仍属于历史里的同一作品。
bool _isSameWork(HistoryItem item, VideoModel fresh) {
  if (item.videoId != fresh.id) return false;

  // 来源已知且不一致：主源裸 ID 在别的源可能指向另一部作品。
  if (item.sourceId != null &&
      item.sourceId!.isNotEmpty &&
      fresh.source != null &&
      fresh.source!.isNotEmpty &&
      item.sourceId != fresh.source) {
    return false;
  }

  // 标题兜底：旧历史没有来源标识，或同源 ID 被复用时，标题明显不同即拒绝。
  final stored = _normalizeTitle(item.title);
  final current = _normalizeTitle(fresh.title);
  if (stored.isEmpty || current.isEmpty) return false;
  if (stored == current) return true;
  return stored.contains(current) || current.contains(stored);
}

EpisodeModel? _snapshotEpisode(HistoryItem item) {
  final episodes = item.episodes;
  final index = item.episodeIndex;
  if (episodes.isEmpty || index < 0 || index >= episodes.length) return null;
  return episodes[index];
}

/// 返回新列表中的唯一匹配下标；无法唯一确认时返回 null（不按下标猜）。
int? _matchEpisodeIndex(EpisodeModel snapshot, List<EpisodeModel> fresh) {
  final snapshotId = snapshot.id.trim();
  // LziApiScraper 等用列表位置生成 ep_N；刷新/重排后它会指向别的剧集，
  // 不能作为身份。只有来源提供的真实 ID 才优先按 ID 匹配。
  if (isStableEpisodeId(snapshotId)) {
    final matches = <int>[];
    for (var i = 0; i < fresh.length; i++) {
      if (fresh[i].id == snapshotId) matches.add(i);
    }
    if (matches.length == 1) return matches.first;
    if (matches.length > 1) return null;
  }

  for (final identity in [snapshot.url, snapshot.playUrl]) {
    if (identity == null || identity.trim().isEmpty) continue;
    final matches = <int>[];
    for (var i = 0; i < fresh.length; i++) {
      if (fresh[i].url == identity || fresh[i].playUrl == identity) {
        matches.add(i);
      }
    }
    if (matches.length == 1) return matches.first;
    if (matches.length > 1) return null;
  }

  final snapshotTitle = snapshot.title.trim();
  if (snapshotTitle.isNotEmpty) {
    final matches = <int>[];
    for (var i = 0; i < fresh.length; i++) {
      if (fresh[i].title.trim() == snapshotTitle) matches.add(i);
    }
    if (matches.length == 1) return matches.first;
    // 重复标题无法确认是哪一集。
    if (matches.length > 1) return null;
  }
  return null;
}

String _normalizeTitle(String input) {
  var text = input.toLowerCase();
  text = text.replaceAll(
    RegExp(r'[\s\[\]\(\)（）【】「」『』《》〈〉,，.。!！?？:：;；~～\-—_/\\|·・×]'),
    '',
  );
  return text;
}
