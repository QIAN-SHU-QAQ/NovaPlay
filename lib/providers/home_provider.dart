import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/video_model.dart';
import 'scraper_provider.dart';

/// 数据源支持的分类列表（LziApi 为静态动漫分类）
final categoriesProvider = FutureProvider<List<String>>((ref) async {
  final scraper = ref.watch(currentScraperProvider);
  return scraper.getCategories();
});

/// 当前选中的分类；'全部' 表示首页默认推荐流
final selectedCategoryProvider = StateProvider<String>((ref) => '全部');

/// 分类筛选结果（无分页，默认拉第一页）
final categoryVideosProvider =
    FutureProvider.family<List<VideoModel>, String>((ref, category) async {
  final scraper = ref.read(currentScraperProvider);
  return scraper.getByCategory(category);
});
