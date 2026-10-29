import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart';
import 'package:flutter/foundation.dart';
import '../../core/network/http_client.dart';
import '../../models/video_model.dart';
import 'base_scraper.dart';

class YhdmScraper extends BaseScraper {
  @override
  String get name => '樱花动漫';

  @override
  String get baseUrl => 'https://yhdm.me';

  @override
  String get icon => '🌸';

  final HttpClient _httpClient = HttpClient();

  @override
  Future<List<String>> getCategories() async {
    return ['全部', '日本动漫', '国产动漫', '欧美动漫', '动漫电影'];
  }

  @override
  Future<List<VideoModel>> getHome({int page = 1}) async {
    try {
      // 首页有 JS 跳转，直接访问 /lander
      final url = page == 1 ? '$baseUrl/lander' : '$baseUrl/lander/page/$page';
      final response = await _httpClient.get(url);
      final document = html_parser.parse(response.data);
      return _parseVideoList(document);
    } catch (e) {
      debugPrint('YhdmScraper getHome error: $e');
      return [];
    }
  }

  @override
  Future<List<VideoModel>> getByCategory(String category, {int page = 1}) async {
    try {
      // 樱花动漫分类页面
      final url = '$baseUrl/list/$page.html';
      final response = await _httpClient.get(url);
      final document = html_parser.parse(response.data);
      return _parseVideoList(document);
    } catch (e) {
      debugPrint('YhdmScraper getByCategory error: $e');
      return [];
    }
  }

  @override
  Future<List<VideoModel>> search(String keyword, {int page = 1}) async {
    try {
      final url = '$baseUrl/search.html?keyword=$keyword&page=$page';
      final response = await _httpClient.get(url);
      final document = html_parser.parse(response.data);
      return _parseVideoList(document);
    } catch (e) {
      debugPrint('YhdmScraper search error: $e');
      return [];
    }
  }

  @override
  Future<VideoModel> getDetail(String url) async {
    try {
      final fullUrl = url.startsWith('http') ? url : '$baseUrl$url';
      final response = await _httpClient.get(fullUrl);
      final document = html_parser.parse(response.data);

      // 解析标题
      final title = document.querySelector('h1')?.text.trim() ?? '未知';

      // 解析封面
      final cover = document.querySelector('.detail-info img')?.attributes['src'] ??
          document.querySelector('.thumb img')?.attributes['src'];

      // 解析简介
      final description = document.querySelector('.detail-info .des')?.text.trim() ??
          document.querySelector('.info')?.text.trim();

      // 解析评分
      double? rating;
      final ratingText = document.querySelector('.score')?.text.trim();
      if (ratingText != null) {
        rating = double.tryParse(ratingText);
      }

      // 解析年份
      final year = document.querySelector('.year')?.text.trim();

      // 解析类型
      final genre = document.querySelector('.type')?.text.trim();

      // 解析选集
      final episodes = _parseEpisodes(document);

      return VideoModel(
        id: url,
        title: title,
        cover: cover,
        description: description,
        rating: rating,
        year: year,
        genre: genre,
        source: name,
        sourceUrl: fullUrl,
        episodes: episodes,
      );
    } catch (e) {
      debugPrint('YhdmScraper getDetail error: $e');
      rethrow;
    }
  }

  @override
  Future<List<String>> getPlayUrls(String episodeUrl) async {
    try {
      final fullUrl = episodeUrl.startsWith('http') ? episodeUrl : '$baseUrl$episodeUrl';
      final response = await _httpClient.get(fullUrl);
      final document = html_parser.parse(response.data);

      // 解析视频源地址（通常是 m3u8 格式）
      final playUrls = <String>[];

      // 尝试从 script 标签中提取 m3u8 地址
      final scripts = document.querySelectorAll('script');
      for (final script in scripts) {
        final text = script.text;
        // 匹配 m3u8 链接
        final m3u8Regex = RegExp(r'https?://\S+\.m3u8\S*');
        final matches = m3u8Regex.allMatches(text);
        for (final match in matches) {
          playUrls.add(match.group(0)!);
        }
      }

      // 如果没找到，尝试 iframe
      if (playUrls.isEmpty) {
        final iframes = document.querySelectorAll('iframe');
        for (final iframe in iframes) {
          final src = iframe.attributes['src'];
          if (src != null && src.isNotEmpty) {
            playUrls.add(src);
          }
        }
      }

      return playUrls;
    } catch (e) {
      debugPrint('YhdmScraper getPlayUrls error: $e');
      return [];
    }
  }

  // 解析视频列表
  List<VideoModel> _parseVideoList(Document document) {
    final videos = <VideoModel>[];

    // 樱花动漫的视频列表通常在 .list-sucl 或类似的容器中
    final items = document.querySelectorAll('.list-sucl li, .video-list li, .anime-list li, .list-item');

    for (final item in items) {
      try {
        final link = item.querySelector('a');
        if (link == null) continue;

        final href = link.attributes['href'] ?? '';
        final title = link.attributes['title'] ?? link.text.trim();

        // 解析封面图
        final img = item.querySelector('img');
        final cover = img?.attributes['data-src'] ?? img?.attributes['src'];

        // 解析评分
        double? rating;
        final ratingEl = item.querySelector('.score, .rating, .tag-score');
        if (ratingEl != null) {
          rating = double.tryParse(ratingEl.text.trim());
        }

        // 解析更新信息
        final info = item.querySelector('.info, .tag, .note')?.text.trim();

        if (title.isNotEmpty && href.isNotEmpty) {
          videos.add(VideoModel(
            id: href,
            title: title,
            cover: cover,
            rating: rating,
            source: name,
            sourceUrl: href,
            description: info,
          ));
        }
      } catch (e) {
        continue;
      }
    }

    return videos;
  }

  // 解析选集列表
  List<EpisodeModel> _parseEpisodes(Document document) {
    final episodes = <EpisodeModel>[];

    // 选集通常在播放列表区域
    final items = document.querySelectorAll('.play-list a, .episode-list a, .movurl a, .playlist a');

    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final href = item.attributes['href'] ?? '';
      final title = item.text.trim();

      if (href.isNotEmpty) {
        episodes.add(EpisodeModel(
          id: 'ep_$i',
          title: title.isNotEmpty ? title : '第${i + 1}集',
          url: href,
          index: i,
        ));
      }
    }

    return episodes;
  }
}
