import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/bangumi_info.dart';
import '../services/bangumi_api.dart';
import '../services/database_service.dart';

final bangumiApiProvider = Provider<BangumiApi>((ref) => BangumiApi());

/// 按标题拉取 Bangumi 元数据；失败/无结果返回 null（详情页静默降级双栏）。
///
/// R7：优先使用用户手动纠正过的 subjectId，否则由 [BangumiApi] 按相似度
/// 选择候选（不再直接取搜索首项）。
final bangumiInfoProvider = FutureProvider.family<BangumiInfo?, String>((
  ref,
  title,
) {
  final mapping = DatabaseService().getBangumiMapping(title);
  final subjectId = mapping?['subjectId'];
  return ref
      .read(bangumiApiProvider)
      .fetchInfo(title, subjectId: subjectId is int ? subjectId : null);
});
