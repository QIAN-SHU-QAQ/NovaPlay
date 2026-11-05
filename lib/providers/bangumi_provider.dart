import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/bangumi_info.dart';
import '../services/bangumi_api.dart';
import '../services/database_service.dart';

final bangumiApiProvider = Provider<BangumiApi>((ref) => BangumiApi());

/// Bangumi 查询参数：完整视频 ID 用于关联与缓存，标题只用于搜索。
class BangumiQuery {
  const BangumiQuery({required this.videoId, required this.title});

  final String videoId;
  final String title;

  @override
  bool operator ==(Object other) =>
      other is BangumiQuery && other.videoId == videoId && other.title == title;

  @override
  int get hashCode => Object.hash(videoId, title);
}

/// 拉取 Bangumi 元数据；失败/无结果返回 null（详情页静默降级双栏）。
///
/// R7：手动关联按**完整视频 ID** 保存与读取；自动匹配由 [BangumiApi]
/// 按相似度/季数排序并拒绝无法唯一确认的候选（不再取搜索首项）。
final bangumiInfoProvider = FutureProvider.family<BangumiInfo?, BangumiQuery>((
  ref,
  query,
) {
  final mapping = DatabaseService().getBangumiMapping(query.videoId);
  final subjectId = mapping?['subjectId'];
  return ref
      .read(bangumiApiProvider)
      .fetchInfo(query.title, subjectId: subjectId is int ? subjectId : null);
});
