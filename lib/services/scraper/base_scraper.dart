import '../../models/video_model.dart';

abstract class BaseScraper {
  String get name;
  String get baseUrl;
  String get icon;

  /// Get homepage videos
  Future<List<VideoModel>> getHome({int page = 1});

  /// Search videos by keyword
  Future<List<VideoModel>> search(String keyword, {int page = 1});

  /// Get video detail by url
  Future<VideoModel> getDetail(String url);

  /// Get play urls for an episode
  Future<List<String>> getPlayUrls(String episodeUrl);

  /// Get video categories
  Future<List<String>> getCategories();

  /// Get videos by category
  Future<List<VideoModel>> getByCategory(String category, {int page = 1});
}
