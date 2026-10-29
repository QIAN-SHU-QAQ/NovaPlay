/// Bangumi (api.bgm.tv) 元数据：评分、制作人员、角色+声优。
/// 全部字段可空——接口失败时由调用方静默降级为双栏布局。
class BangumiInfo {
  final double? score;
  final int? scoreCount;
  final List<BangumiStaffEntry> staff;
  final List<BangumiCharacter> characters;

  const BangumiInfo({
    this.score,
    this.scoreCount,
    this.staff = const [],
    this.characters = const [],
  });

  bool get isEmpty =>
      score == null && staff.isEmpty && characters.isEmpty;
}

/// 制作人员条目：key=职务（导演/系列构成/动画制作…），value=人名/公司
class BangumiStaffEntry {
  final String role;
  final String name;

  const BangumiStaffEntry({required this.role, required this.name});
}

class BangumiCharacter {
  final String name;
  final String? imageUrl;

  /// 配音演员（优先中文译名）
  final String? cv;

  const BangumiCharacter({
    required this.name,
    this.imageUrl,
    this.cv,
  });
}
