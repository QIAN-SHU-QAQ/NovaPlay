/// 剧集身份工具。
///
/// 不同数据源提供的剧集标识可靠性不同：
/// - LziApiScraper 用列表位置生成 `ep_1`/`ep_2`，刷新或重排后会指向另一集，
///   **不是**稳定身份；它的 `vod_play_url` 是**直接媒体地址**（m3u8/mp4 等，
///   可能带签名轮换，甚至没有扩展名），也不能当页面身份。
/// - 页面型数据源（如 Yhdm/AniList）的 episode url 是详情页地址，可作为身份。
///
/// 因此 [EpisodeModel.urlIsMediaPlayback] 由数据源显式声明用途；身份计算
/// 依赖该标记，而不是靠扩展名黑名单猜测。
library;

/// 是否为来源提供的稳定剧集 ID（排除本地按位置生成的 `ep_N`）。
bool isStableEpisodeId(String? id) {
  final value = id?.trim() ?? '';
  if (value.isEmpty) return false;
  if (RegExp(r'^ep_\d+$').hasMatch(value)) return false;
  return true;
}

/// 兼容旧数据的兜底启发式：明显是媒体地址或带签名参数时不可作为页面身份。
///
/// 新数据必须使用显式 `media` 标记；该函数只用于标记缺失的旧历史/旧快照。
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
/// 2. 页面 URL（**仅当来源显式标记不是媒体地址**；标记缺失时用启发式兜底）；
/// 3. 当前列表内**唯一**标题（位置 ID 与媒体地址都不可靠时的兜底）。
///
/// 都不可用时返回 null（调用方应禁用该集的手动关联，不能退回列表下标）。
String? episodeIdentityFromMap(
  Map<String, String> episode,
  List<Map<String, String>> siblings,
) {
  final id = episode['id']?.trim() ?? '';
  if (isStableEpisodeId(id)) return 'id:$id';

  final mediaFlag = (episode['media'] ?? '').trim().toLowerCase();
  final pageUrl = episode['pageUrl']?.trim() ?? '';
  if (pageUrl.isNotEmpty && mediaFlag != 'true') {
    if (mediaFlag == 'false') return 'page:$pageUrl';
    // 旧数据没有显式标记：只能用启发式避免把明显媒体地址当页面。
    if (!isVolatileMediaUrl(pageUrl)) return 'page:$pageUrl';
  }

  final title = episode['title']?.trim() ?? '';
  if (title.isEmpty) return null;
  final sameTitle = siblings.where(
    (sibling) => (sibling['title'] ?? '').trim() == title,
  );
  if (sameTitle.length != 1) return null;
  return 'title:$title';
}
