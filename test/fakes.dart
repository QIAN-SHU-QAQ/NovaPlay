import 'package:nova_play/models/video_model.dart';
import 'package:nova_play/services/scraper/base_scraper.dart';

/// 测试用空数据源：不发任何网络请求
class FakeScraper extends BaseScraper {
  @override
  String get name => 'Fake';

  @override
  String get baseUrl => 'https://fake.local';

  @override
  String get icon => '🧪';

  @override
  Future<List<String>> getCategories() async => ['全部'];

  @override
  Future<List<VideoModel>> getHome({int page = 1}) async => [];

  @override
  Future<List<VideoModel>> getByCategory(String category, {int page = 1}) =>
      Future.value([]);

  @override
  Future<List<VideoModel>> search(String keyword, {int page = 1}) async => [];

  @override
  Future<VideoModel> getDetail(String url) => Future.value(VideoModel(
        id: url,
        title: 'Fake',
      ));

  @override
  Future<List<String>> getPlayUrls(String episodeUrl) async => [];
}
