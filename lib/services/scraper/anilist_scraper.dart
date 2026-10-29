import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../core/network/http_client.dart';
import '../../models/video_model.dart';
import 'base_scraper.dart';

/// AniList API 解析器 - 使用公开的 GraphQL API 获取动漫数据
class AniListScraper extends BaseScraper {
  @override
  String get name => 'AniList';

  @override
  String get baseUrl => 'https://graphql.anilist.co';

  @override
  String get icon => '📺';

  final HttpClient _httpClient = HttpClient();

  @override
  Future<List<String>> getCategories() async {
    return ['全部', '热门', '最新', '评分最高', '动作', '冒险', '喜剧', '剧情', '奇幻', '科幻'];
  }

  @override
  Future<List<VideoModel>> getHome({int page = 1}) async {
    try {
      final query = '''
        query {
          Page(page: $page, perPage: 20) {
            media(type: ANIME, sort: POPULARITY_DESC) {
              id
              title { romaji native english }
              synonyms
              synonyms
              coverImage { large }
              averageScore
              description(asHtml: false)
              episodes
              genres
              startDate { year }
            }
          }
        }
      ''';

      final response = await _httpClient.post(
        baseUrl,
        data: {'query': query},
        options: Options(contentType: 'application/json'),
      );

      final data = response.data;
      final mediaList = data['data']['Page']['media'] as List;

      return mediaList.map((item) => _parseAnime(item)).toList();
    } catch (e) {
      debugPrint('AniListScraper getHome error: $e');
      return [];
    }
  }

  @override
  Future<List<VideoModel>> getByCategory(String category, {int page = 1}) async {
    String sort = 'POPULARITY_DESC';
    String? genre;

    switch (category) {
      case '热门':
        sort = 'TRENDING_DESC';
        break;
      case '最新':
        sort = 'START_DATE_DESC';
        break;
      case '评分最高':
        sort = 'SCORE_DESC';
        break;
      case '动作':
        genre = 'Action';
        break;
      case '冒险':
        genre = 'Adventure';
        break;
      case '喜剧':
        genre = 'Comedy';
        break;
      case '剧情':
        genre = 'Drama';
        break;
      case '奇幻':
        genre = 'Fantasy';
        break;
      case '科幻':
        genre = 'Sci-Fi';
        break;
    }

    final genreFilter = genre != null ? ', genre: "$genre"' : '';
    final query = '''
      query {
        Page(page: $page, perPage: 20) {
          media(type: ANIME, sort: $sort$genreFilter) {
            id
            title { romaji native english }
              synonyms
            coverImage { large }
            averageScore
            description
            episodes
            genres
            startDate { year }
          }
        }
      }
    ''';

    final response = await _httpClient.post(
      baseUrl,
      data: {'query': query},
      options: Options(contentType: 'application/json'),
    );

    final data = response.data;
    final mediaList = data['data']['Page']['media'] as List;

    return mediaList.map((item) => _parseAnime(item)).toList();
  }

  @override
  Future<List<VideoModel>> search(String keyword, {int page = 1}) async {
    try {
      final query = '''
        query {
          Page(page: $page, perPage: 20) {
            media(search: "$keyword", type: ANIME) {
              id
              title { romaji native english }
              synonyms
              coverImage { large }
              averageScore
              description
              episodes
              genres
              startDate { year }
            }
          }
        }
      ''';

      final response = await _httpClient.post(
        baseUrl,
        data: {'query': query},
        options: Options(contentType: 'application/json'),
      );

      final data = response.data;
      final mediaList = data['data']['Page']['media'] as List;

      return mediaList.map((item) => _parseAnime(item)).toList();
    } catch (e) {
      debugPrint('AniListScraper search error: $e');
      return [];
    }
  }

  @override
  Future<VideoModel> getDetail(String url) async {
    try {
      final id = int.tryParse(url) ?? 0;
      final query = '''
        query {
          Media(id: $id, type: ANIME) {
            id
            title { romaji native english }
              synonyms
            coverImage { large }
            bannerImage
            averageScore
            description(asHtml: false)
            episodes
            genres
            startDate { year }
            status
            studios { nodes { name } }
            characters(page: 1, perPage: 5) { nodes { name { full } } }
          }
        }
      ''';

      final response = await _httpClient.post(
        baseUrl,
        data: {'query': query},
        options: Options(contentType: 'application/json'),
      );

      final data = response.data;
      final media = data['data']['Media'];

      return _parseAnimeDetail(media);
    } catch (e) {
      debugPrint('AniListScraper getDetail error: $e');
      rethrow;
    }
  }

  @override
  Future<List<String>> getPlayUrls(String episodeUrl) async {
    // 返回测试视频源（公开的示例视频）
    // 实际使用时需要接入真实的视频源 API
    return [
      'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
      'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8',
    ];
  }

  VideoModel _parseAnime(Map<String, dynamic> item) {
    final title = item['title'];
    // 从别名中找中文标题
    final synonyms = (item['synonyms'] as List?)?.cast<String>() ?? [];
    final chineseTitle = _findChineseTitle(synonyms);
    // 优先中文，其次日文，其次英文，最后罗马音
    final displayTitle = chineseTitle ?? title['native'] ?? title['english'] ?? title['romaji'] ?? '未知';
    final cover = item['coverImage']?['large'];
    final score = item['averageScore'];
    final description = item['description']?.toString().replaceAll(RegExp(r'<[^>]*>'), '');
    final episodes = item['episodes'];
    final genres = (item['genres'] as List?)?.join(' / ');
    final year = item['startDate']?['year']?.toString();

    return VideoModel(
      id: item['id'].toString(),
      title: displayTitle,
      cover: cover,
      description: description,
      rating: score != null ? score / 10.0 : null,
      year: year,
      genre: genres,
      source: name,
      episodes: episodes != null
          ? List.generate(
              episodes,
              (i) => EpisodeModel(
                id: 'ep_${i + 1}',
                title: '第 ${i + 1} 集',
                url: '${item['id']}/episode/${i + 1}',
                index: i,
              ),
            )
          : null,
    );
  }

  VideoModel _parseAnimeDetail(Map<String, dynamic> media) {
    final title = media['title'];
    // 从别名中找中文标题
    final synonyms = (media['synonyms'] as List?)?.cast<String>() ?? [];
    final chineseTitle = _findChineseTitle(synonyms);
    // 优先中文，其次日文，其次英文，最后罗马音
    final displayTitle = chineseTitle ?? title['native'] ?? title['english'] ?? title['romaji'] ?? '未知';
    final cover = media['coverImage']?['large'];
    final score = media['averageScore'];
    final description = media['description']?.toString().replaceAll(RegExp(r'<[^>]*>'), '');
    final episodes = media['episodes'];
    final genres = (media['genres'] as List?)?.join(' / ');
    final year = media['startDate']?['year']?.toString();

    return VideoModel(
      id: media['id'].toString(),
      title: displayTitle,
      cover: cover,
      description: description,
      rating: score != null ? score / 10.0 : null,
      year: year,
      genre: genres,
      source: name,
      episodes: episodes != null
          ? List.generate(
              episodes,
              (i) => EpisodeModel(
                id: 'ep_${i + 1}',
                title: '第 ${i + 1} 集',
                url: '${media['id']}/episode/${i + 1}',
                index: i,
              ),
            )
          : null,
    );
  }

  /// 从别名列表中找中文标题
  String? _findChineseTitle(List<String> synonyms) {
    for (final synonym in synonyms) {
      // 检测是否包含中文字符
      if (RegExp(r'[一-鿿]').hasMatch(synonym)) {
        return synonym;
      }
    }
    return null;
  }
}
