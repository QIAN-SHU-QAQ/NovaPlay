import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/video_model.dart';
import '../services/scraper/base_scraper.dart';
import 'scraper_provider.dart';

/// 搜索状态（支持无限滚动分页）
class SearchState {
  final List<VideoModel> results;
  final bool isLoading;
  final String keyword;
  final int page;
  final bool hasMore;
  final String? error;

  SearchState({
    this.results = const [],
    this.isLoading = false,
    this.keyword = '',
    this.page = 1,
    this.hasMore = true,
    this.error,
  });

  SearchState copyWith({
    List<VideoModel>? results,
    bool? isLoading,
    String? keyword,
    int? page,
    bool? hasMore,
    String? error,
    bool clearError = false,
  }) {
    return SearchState(
      results: results ?? this.results,
      isLoading: isLoading ?? this.isLoading,
      keyword: keyword ?? this.keyword,
      page: page ?? this.page,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// 搜索 Notifier
class SearchNotifier extends StateNotifier<SearchState> {
  final BaseScraper _scraper;
  int _requestId = 0;

  SearchNotifier(this._scraper) : super(SearchState());

  Future<void> search(String keyword) async {
    final query = keyword.trim();
    if (!mounted || query.isEmpty) return;

    final requestId = ++_requestId;
    state = SearchState(isLoading: true, keyword: query);

    try {
      final results = await _scraper.search(query, page: 1);
      // Older requests can still complete after a new search, clear or disposal.
      if (!mounted || requestId != _requestId) return;
      state = SearchState(
        results: results,
        isLoading: false,
        keyword: query,
        page: 2,
        hasMore: results.isNotEmpty,
      );
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// 加载下一页结果并追加（供列表滚到底部时调用）。
  Future<void> loadMore() async {
    if (!mounted || state.isLoading || !state.hasMore) return;
    final keyword = state.keyword;
    if (keyword.isEmpty) return;

    final requestId = _requestId;
    final requestedPage = state.page;
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final results = await _scraper.search(keyword, page: requestedPage);
      if (!mounted || requestId != _requestId) return;
      state = state.copyWith(
        results: [...state.results, ...results],
        isLoading: false,
        hasMore: results.isNotEmpty,
        page: requestedPage + 1,
      );
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  void clear() {
    if (!mounted) return;
    _requestId++;
    state = SearchState();
  }
}

/// 搜索 Provider
final searchProvider = StateNotifierProvider<SearchNotifier, SearchState>((
  ref,
) {
  final scraper = ref.watch(currentScraperProvider);
  return SearchNotifier(scraper);
});
