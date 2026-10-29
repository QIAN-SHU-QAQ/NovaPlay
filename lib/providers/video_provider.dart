import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/video_model.dart';
import '../services/scraper/base_scraper.dart';
import 'scraper_provider.dart';

/// 首页视频列表状态
class VideoListState {
  final List<VideoModel> videos;
  final bool isLoading;
  final bool hasMore;
  final int currentPage;
  final String? error;

  VideoListState({
    this.videos = const [],
    this.isLoading = false,
    this.hasMore = true,
    this.currentPage = 1,
    this.error,
  });

  VideoListState copyWith({
    List<VideoModel>? videos,
    bool? isLoading,
    bool? hasMore,
    int? currentPage,
    String? error,
  }) {
    return VideoListState(
      videos: videos ?? this.videos,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      currentPage: currentPage ?? this.currentPage,
      error: error,
    );
  }
}

/// 首页视频列表 Notifier
class VideoListNotifier extends StateNotifier<VideoListState> {
  final BaseScraper _scraper;

  VideoListNotifier(this._scraper) : super(VideoListState()) {
    loadVideos();
  }

  Future<void> loadVideos() async {
    if (state.isLoading) return;

    state = state.copyWith(isLoading: true, error: null);

    try {
      final videos = await _scraper.getHome(page: 1);
      state = VideoListState(
        videos: videos,
        isLoading: false,
        hasMore: videos.isNotEmpty,
        currentPage: 1,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  Future<void> loadMore() async {
    if (state.isLoading || !state.hasMore) return;

    state = state.copyWith(isLoading: true);

    try {
      final nextPage = state.currentPage + 1;
      final videos = await _scraper.getHome(page: nextPage);
      state = state.copyWith(
        videos: [...state.videos, ...videos],
        isLoading: false,
        hasMore: videos.isNotEmpty,
        currentPage: nextPage,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  Future<void> refresh() async {
    state = VideoListState(isLoading: true);
    try {
      final videos = await _scraper.getHome(page: 1);
      state = VideoListState(
        videos: videos,
        isLoading: false,
        hasMore: videos.isNotEmpty,
        currentPage: 1,
      );
    } catch (e) {
      state = VideoListState(
        isLoading: false,
        error: e.toString(),
      );
    }
  }
}

/// 首页视频列表 Provider
final videoListProvider = StateNotifierProvider<VideoListNotifier, VideoListState>((ref) {
  final scraper = ref.watch(currentScraperProvider);
  return VideoListNotifier(scraper);
});

/// 视频详情 Provider
final videoDetailProvider = FutureProvider.family<VideoModel, String>((ref, url) async {
  final scraper = ref.watch(currentScraperProvider);
  return scraper.getDetail(url);
});

/// 视频播放地址 Provider
final playUrlsProvider = FutureProvider.family<List<String>, String>((ref, episodeUrl) async {
  final scraper = ref.watch(currentScraperProvider);
  return scraper.getPlayUrls(episodeUrl);
});
