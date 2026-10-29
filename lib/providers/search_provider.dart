import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/video_model.dart';
import '../services/scraper/base_scraper.dart';
import 'scraper_provider.dart';

/// 搜索状态
class SearchState {
  final List<VideoModel> results;
  final bool isLoading;
  final String keyword;
  final String? error;

  SearchState({
    this.results = const [],
    this.isLoading = false,
    this.keyword = '',
    this.error,
  });

  SearchState copyWith({
    List<VideoModel>? results,
    bool? isLoading,
    String? keyword,
    String? error,
  }) {
    return SearchState(
      results: results ?? this.results,
      isLoading: isLoading ?? this.isLoading,
      keyword: keyword ?? this.keyword,
      error: error,
    );
  }
}

/// 搜索 Notifier
class SearchNotifier extends StateNotifier<SearchState> {
  final BaseScraper _scraper;

  SearchNotifier(this._scraper) : super(SearchState());

  Future<void> search(String keyword) async {
    if (keyword.trim().isEmpty) return;

    state = state.copyWith(isLoading: true, keyword: keyword, error: null);

    try {
      final results = await _scraper.search(keyword);
      state = state.copyWith(
        results: results,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  void clear() {
    state = SearchState();
  }
}

/// 搜索 Provider
final searchProvider = StateNotifierProvider<SearchNotifier, SearchState>((ref) {
  final scraper = ref.watch(currentScraperProvider);
  return SearchNotifier(scraper);
});
