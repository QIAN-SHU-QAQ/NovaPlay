import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/scraper/base_scraper.dart';
import '../services/scraper/scraper_registry.dart';
import '../services/scraper/anilist_scraper.dart';
import '../services/scraper/lziapi_scraper.dart';

/// 解析器注册中心 Provider
final scraperRegistryProvider = Provider<ScraperRegistry>((ref) {
  final registry = ScraperRegistry();
  // 注册 LziApi 视频源（提供真实播放地址）
  registry.register(LziApiScraper());
  // 注册 AniList 解析器（元数据源）
  registry.register(AniListScraper());
  return registry;
});

/// 当前使用的解析器 Provider（默认 LziApi）
final currentScraperProvider = Provider<BaseScraper>((ref) {
  final registry = ref.watch(scraperRegistryProvider);
  return registry.defaultScraper ?? LziApiScraper();
});

/// 所有可用解析器列表
final availableScrapersProvider = Provider<List<BaseScraper>>((ref) {
  final registry = ref.watch(scraperRegistryProvider);
  return registry.scrapers;
});
