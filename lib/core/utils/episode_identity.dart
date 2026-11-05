/// 剧集身份工具。
///
/// 不同数据源提供的剧集标识可靠性不同：例如 LziApiScraper 的
/// `_parseVideo` 用列表位置生成 `ep_1`/`ep_2`，刷新或重排后会指向另一集，
/// **不是**可验证的稳定身份；而外部源（如 Bangumi/AniList 等）可能提供
/// 真实 episode id。此外 `EpisodeModel.url` 在部分源里是**媒体地址**
/// （m3u8/mp4，带签名或 CDN 参数，刷新后会轮换），也不能当页面身份。
/// 续播与弹幕关联必须区分这些来源，不能把位置标识/易失媒体地址当身份。
library;

/// 是否为来源提供的稳定剧集 ID（排除本地按位置生成的 `ep_N`）。
bool isStableEpisodeId(String? id) {
  final value = id?.trim() ?? '';
  if (value.isEmpty) return false;
  if (RegExp(r'^ep_\d+$').hasMatch(value)) return false;
  return true;
}

/// 是否像会轮换的媒体地址（m3u8/mp4 等，或带签名/过期参数）。
///
/// LziApiScraper 的 `EpisodeModel.url` 就是媒体地址；把它当页面身份会导致
/// 刷新后手动弹幕关联键改变、已保存的纠正失效。
bool isVolatileMediaUrl(String? url) {
  final value = url?.trim() ?? '';
  if (value.isEmpty) return true;
  final lower = value.toLowerCase();
  final path = lower.split('?').first.split('#').first;
  const mediaExtensions = [
    '.m3u8',
    '.mp4',
    '.ts',
    '.flv',
    '.mkv',
    '.mov',
    '.webm',
    '.m4s',
    '.mp3',
    '.m4a',
    '.aac',
  ];
  for (final extension in mediaExtensions) {
    if (path.endsWith(extension)) return true;
  }
  // 带签名/过期参数的地址即使不是媒体扩展名也不稳定。
  final queryIndex = lower.indexOf('?');
  final query = queryIndex >= 0 ? lower.substring(queryIndex + 1) : '';
  const volatileParams = [
    'sign=',
    'token=',
    'expires=',
    'auth_key=',
    'x-signature=',
  ];
  for (final param in volatileParams) {
    if (query.contains(param)) return true;
  }
  return false;
}

/// 从播放器/详情页的剧集 map 计算稳定身份（用于弹幕手动关联键）。
///
/// 顺序：
/// 1. 来源提供的稳定 episode ID；
/// 2. 稳定页面 URL（pageUrl，排除 m3u8/mp4/带签名等易失媒体地址）；
/// 3. 当前列表内**唯一**标题（位置 ID 与媒体 URL 都不可靠时的兜底）。
///
/// 都不可用时返回 null（调用方应禁用该集的手动关联，不能退回列表下标）。
String? episodeIdentityFromMap(
  Map<String, String> episode,
  List<Map<String, String>> siblings,
) {
  final id = episode['id']?.trim() ?? '';
  if (isStableEpisodeId(id)) return 'id:$id';

  final pageUrl = episode['pageUrl']?.trim() ?? '';
  if (pageUrl.isNotEmpty && !isVolatileMediaUrl(pageUrl)) {
    return 'page:$pageUrl';
  }

  final title = episode['title']?.trim() ?? '';
  if (title.isEmpty) return null;
  final sameTitle = siblings.where(
    (sibling) => (sibling['title'] ?? '').trim() == title,
  );
  if (sameTitle.length != 1) return null;
  return 'title:$title';
}
