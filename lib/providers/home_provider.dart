import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/video_model.dart';
import '../services/scraper/base_scraper.dart';
import 'scraper_provider.dart';

/// 数据源支持的分类列表（LziApi 为静态动漫分类）
final categoriesProvider = FutureProvider<List<String>>((ref) async {
  final scraper = ref.watch(currentScraperProvider);
  return scraper.getCategories();
});

/// 当前选中的分类；'全部' 表示首页默认推荐流
final selectedCategoryProvider = StateProvider<String>((ref) => '全部');

/// 分类筛选结果（支持无限滚动分页）
class CategoryFeedState {
  final String category;
  final List<VideoModel> videos;
  final bool isLoading;
  final bool hasMore;
  final int page;
  final String? error;

  const CategoryFeedState({
    required this.category,
    this.videos = const [],
    this.isLoading = false,
    this.hasMore = true,
    this.page = 1,
    this.error,
  });

  CategoryFeedState copyWith({
    List<VideoModel>? videos,
    bool? isLoading,
    bool? hasMore,
    int? page,
    String? error,
    bool clearError = false,
  }) {
    return CategoryFeedState(
      category: category,
      videos: videos ?? this.videos,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      page: page ?? this.page,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class CategoryFeedNotifier extends StateNotifier<CategoryFeedState> {
  CategoryFeedNotifier(this._scraper, String category)
    : super(CategoryFeedState(category: category)) {
    loadMore();
  }

  final BaseScraper _scraper;

  Future<void> loadMore() async {
    if (!mounted || state.isLoading || !state.hasMore) return;
    final requestedPage = state.page;
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final videos = await _scraper.getByCategory(
        state.category,
        page: requestedPage,
      );
      if (!mounted) return;
      state = state.copyWith(
        videos: [...state.videos, ...videos],
        isLoading: false,
        hasMore: videos.isNotEmpty,
        page: requestedPage + 1,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// 刷新：丢弃已有结果，从第一页重新加载。
  Future<void> refresh() async {
    if (!mounted) return;
    state = CategoryFeedState(category: state.category);
    await loadMore();
  }
}

final categoryFeedProvider = StateNotifierProvider.family<
  CategoryFeedNotifier,
  CategoryFeedState,
  String
>((ref, category) {
  final scraper = ref.watch(currentScraperProvider);
  return CategoryFeedNotifier(scraper, category);
});
