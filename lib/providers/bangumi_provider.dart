import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/bangumi_info.dart';
import '../services/bangumi_api.dart';

final bangumiApiProvider = Provider<BangumiApi>((ref) => BangumiApi());

/// 按标题拉取 Bangumi 元数据；失败/无结果返回 null（详情页静默降级双栏）。
final bangumiInfoProvider =
    FutureProvider.family<BangumiInfo?, String>((ref, title) {
  return ref.read(bangumiApiProvider).fetchInfo(title);
});
