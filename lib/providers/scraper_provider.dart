import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/database_service.dart';
import '../services/scraper/base_scraper.dart';
import '../services/scraper/lziapi_scraper.dart';
import '../services/scraper/source_config.dart';

/// 数据源配置版本号：设置页修改配置后自增，驱动下游 scraper 重建。
final sourceVersionProvider = StateProvider<int>((ref) => 0);

/// 当前保存的全部数据源配置（含已禁用项）。
final sourceConfigsProvider = Provider<List<SourceConfig>>((ref) {
  ref.watch(sourceVersionProvider);
  return DatabaseService().getSources();
});

/// 当前生效的数据源：优先用户选中的，否则取第一个启用的。
final activeSourceConfigProvider = Provider<SourceConfig>((ref) {
  final configs = ref.watch(sourceConfigsProvider);
  final enabled = configs.where((c) => c.enabled).toList(growable: false);
  final activeId = DatabaseService().getActiveSourceId();

  if (enabled.isEmpty) {
    // 全部禁用时仍保证有一个可用源，避免应用直接不可用
    return configs.isNotEmpty ? configs.first : SourceConfig.defaults().first;
  }
  return enabled.firstWhere(
    (c) => c.id == activeId,
    orElse: () => enabled.first,
  );
});

/// 当前主 scraper：主源 + 其余启用源作为回退。
final currentScraperProvider = Provider<BaseScraper>((ref) {
  final configs = ref.watch(sourceConfigsProvider);
  final active = ref.watch(activeSourceConfigProvider);
  final fallbacks = configs
      .where((c) => c.enabled && c.id != active.id)
      .toList(growable: false);
  return LziApiScraper(primary: active, fallbacks: fallbacks);
});
