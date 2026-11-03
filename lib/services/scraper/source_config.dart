/// 数据源配置：maccms 风格 API 的可持久化描述。
///
/// 内置源只是默认值，用户可以新增 / 启停 / 切换，避免"源挂了整个应用不可用"。
class SourceConfig {
  final String id;
  final String name;
  final String baseUrl;
  final bool enabled;

  const SourceConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.enabled = true,
  });

  factory SourceConfig.fromJson(Map<String, dynamic> json) {
    return SourceConfig(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '未命名源',
      baseUrl: (json['baseUrl'] as String?) ?? '',
      enabled: (json['enabled'] as bool?) ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'enabled': enabled,
  };

  SourceConfig copyWith({String? name, String? baseUrl, bool? enabled}) {
    return SourceConfig(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      enabled: enabled ?? this.enabled,
    );
  }

  /// 内置默认源（首次启动时写入，之后以用户配置为准）
  static List<SourceConfig> defaults() => const [
    SourceConfig(
      id: 'lziapi',
      name: 'LziApi',
      baseUrl: 'https://cj.lziapi.com/api.php/provide/vod/',
    ),
    SourceConfig(
      id: '360zy',
      name: '360zy',
      baseUrl: 'https://360zy.com/api.php/provide/vod/',
    ),
  ];
}

/// 数据源层统一异常：带用户可读文案，供 UI 展示/重试。
class ScraperException implements Exception {
  final String message;
  final Object? cause;

  ScraperException(this.message, [this.cause]);

  @override
  String toString() => message;
}
