/// 剧集身份工具。
///
/// 不同数据源提供的剧集标识可靠性不同：例如 LziApiScraper 的
/// `_parseVideo` 用列表位置生成 `ep_1`/`ep_2`，刷新或重排后会指向另一集，
/// **不是**可验证的稳定身份；而外部源（如 Bangumi/AniList 等）可能提供
/// 真实 episode id。续播与弹幕关联必须区分两者，不能把位置标识当身份。
library;

/// 是否为来源提供的稳定剧集 ID（排除本地按位置生成的 `ep_N`）。
bool isStableEpisodeId(String? id) {
  final value = id?.trim() ?? '';
  if (value.isEmpty) return false;
  if (RegExp(r'^ep_\d+$').hasMatch(value)) return false;
  return true;
}

/// 从播放器/详情页的剧集 map 计算稳定身份（用于弹幕手动关联键）。
///
/// 顺序：来源稳定 ID > 原始页面 URL（pageUrl）> 当前列表内唯一标题。
/// 都不可用时返回 null（调用方应禁用该集的手动关联，不能退回列表下标）。
String? episodeIdentityFromMap(
  Map<String, String> episode,
  List<Map<String, String>> siblings,
) {
  final id = episode['id']?.trim() ?? '';
  if (isStableEpisodeId(id)) return 'id:$id';

  final pageUrl = episode['pageUrl']?.trim() ?? '';
  if (pageUrl.isNotEmpty) return 'page:$pageUrl';

  final title = episode['title']?.trim() ?? '';
  if (title.isEmpty) return null;
  final sameTitle = siblings.where(
    (sibling) => (sibling['title'] ?? '').trim() == title,
  );
  if (sameTitle.length != 1) return null;
  return 'title:$title';
}
