import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../core/network/http_client.dart';
import '../../models/video_model.dart';
import 'base_scraper.dart';

/// LziApi 数据源 - 基于 maccms CMS 的动漫视频源
/// 提供真实可播放的 m3u8 视频地址
class LziApiScraper extends BaseScraper {
  @override
  String get name => 'LziApi';

  @override
  String get baseUrl => 'https://cj.lziapi.com/api.php/provide/vod/';

  @override
  String get icon => '🎬';

  final HttpClient _httpClient = HttpClient();

  // 作品 ID 的命名空间必须与实际请求源一致；旧数字 ID 仍属于主源。
  static const List<String> _apiSources = [
    'https://cj.lziapi.com/api.php/provide/vod/',
    'https://360zy.com/api.php/provide/vod/',
  ];

  /// 解析 JSON 响应
  Map<String, dynamic> _parseJson(String jsonStr) {
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _fetchData(
    Map<String, dynamic> params, {
    int source = 0,
  }) async {
    final response = await _httpClient.get(
      _apiSources[source],
      queryParameters: params,
      options: Options(
        responseType: ResponseType.json,
        sendTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ),
    );

    final data =
        response.data is String
            ? _parseJson(response.data as String)
            : response.data as Map<String, dynamic>;
    if (data['code'].toString() != '1') {
      throw const FormatException('数据源返回失败状态');
    }
    return data;
  }

  final Map<String, String> _backupCategories = {};

  Future<String> _backupCategory(String category) async {
    if (!_backupCategories.containsKey(category)) {
      final data = await _fetchData({'ac': 'list'}, source: 1);
      for (final entry in data['class'] as List) {
        _backupCategories[entry['type_name'].toString()] =
            entry['type_id'].toString();
      }
    }
    final id = _backupCategories[category];
    if (id == null) throw StateError('备用数据源不支持该分类');
    return id;
  }

  /// 空列表是有效结果；只有请求或协议异常才回退。
  Future<List<VideoModel>> _listWithFallback(
    Map<String, dynamic> params, {
    String? category,
  }) async {
    for (var source = 0; source < _apiSources.length; source++) {
      try {
        final query = Map<String, dynamic>.of(params);
        if (source == 1 && category != null) {
          query['t'] = await _backupCategory(category);
        }
        final data = await _fetchData(query, source: source);
        return (data['list'] as List)
            .map(
              (item) =>
                  _parseVideo(item as Map<String, dynamic>, source: source),
            )
            .toList();
      } catch (e) {
        debugPrint('视频数据源 ${source == 0 ? name : '360zy'} 请求失败: $e');
      }
    }
    throw Exception('视频数据源暂时不可用，请检查网络后重试');
  }

  // maccms 分类 ID
  static const int _typeGuochan = 29; // 国产动漫
  static const int _typeRihan = 30; // 日韩动漫
  static const int _typeOumei = 31; // 欧美动漫
  static const int _typeGangtai = 32; // 港台动漫
  static const int _typeHaiwai = 33; // 海外动漫

  @override
  Future<List<String>> getCategories() async {
    return ['全部', '日韩动漫', '国产动漫', '欧美动漫', '港台动漫', '海外动漫'];
  }

  @override
  Future<List<VideoModel>> getHome({int page = 1}) async {
    return getByCategory('日韩动漫', page: page);
  }

  @override
  Future<List<VideoModel>> getByCategory(
    String category, {
    int page = 1,
  }) async {
    int typeId;
    switch (category) {
      case '日韩动漫':
        typeId = _typeRihan;
        break;
      case '国产动漫':
        typeId = _typeGuochan;
        break;
      case '欧美动漫':
        typeId = _typeOumei;
        break;
      case '港台动漫':
        typeId = _typeGangtai;
        break;
      case '海外动漫':
        typeId = _typeHaiwai;
        break;
      default:
        typeId = _typeRihan;
    }

    return _listWithFallback({
      'ac': 'detail',
      't': typeId,
      'pg': page,
    }, category: category == '全部' ? '日韩动漫' : category);
  }

  @override
  Future<List<VideoModel>> search(String keyword, {int page = 1}) async {
    return _listWithFallback({'ac': 'detail', 'wd': keyword, 'pg': page});
  }

  @override
  Future<VideoModel> getDetail(String url) async {
    final source = url.startsWith('360zy:') ? 1 : 0;
    final id = source == 1 ? url.substring('360zy:'.length) : url;
    if (!RegExp(r'^\d+$').hasMatch(id)) {
      throw Exception('无效的视频标识，请重新搜索作品');
    }
    try {
      final data = await _fetchData({
        'ac': 'detail',
        'ids': id,
      }, source: source);

      if ((data['list'] as List).isEmpty) {
        throw Exception('未找到视频详情');
      }

      final item = data['list'][0];
      if (item['vod_id'].toString() != id) {
        throw const FormatException('数据源返回了不匹配的作品标识');
      }
      final video = _parseVideo(item, source: source);

      // 如果主源的 CDN 慢，尝试从备用源获取更快的播放地址
      final hasFastCdn =
          video.episodes?.any((ep) {
            final playUrl = ep.playUrl ?? '';
            return _fastCdnDomains.any((cdn) => playUrl.contains(cdn));
          }) ??
          false;

      if (source == 0 &&
          !hasFastCdn &&
          video.title.isNotEmpty &&
          _hasExplicitEpisodeTitles(item) &&
          video.year != null &&
          video.year!.trim().isNotEmpty) {
        try {
          final backupData = await _fetchData({
            'ac': 'detail',
            'wd': video.title,
          }, source: 1);

          final backupList = backupData['list'] as List;
          // 查找匹配的视频
          for (final backupItem in backupList) {
            final backupName = (backupItem['vod_name'] as String?) ?? '';
            if (backupName.trim() == video.title.trim() &&
                _hasExplicitEpisodeTitles(backupItem) &&
                backupItem['vod_year']?.toString().trim() ==
                    video.year!.trim()) {
              final backupVideo = _parseVideo(backupItem, source: 1);
              if (backupVideo.episodes != null &&
                  backupVideo.episodes!.isNotEmpty &&
                  backupVideo.episodes!.first.playUrl != null &&
                  backupVideo.episodes!.first.playUrl!.contains('.m3u8')) {
                final episodes = video.episodes ?? <EpisodeModel>[];
                final replacements = backupVideo.episodes!;
                // 保留集数、顺序和剧集 ID，避免跨源缺集/特典造成续播错位。
                if (episodes.isEmpty ||
                    episodes.length != replacements.length ||
                    episodes.map((e) => e.title.trim()).toSet().length !=
                        episodes.length ||
                    replacements.map((e) => e.title.trim()).toSet().length !=
                        replacements.length) {
                  continue;
                }
                final byTitle = {
                  for (final ep in replacements) ep.title.trim(): ep,
                };
                if (!episodes.every(
                  (ep) => byTitle.containsKey(ep.title.trim()),
                )) {
                  continue;
                }
                return video.copyWith(
                  episodes:
                      episodes.map((ep) {
                        final replacement = byTitle[ep.title.trim()]!;
                        return EpisodeModel(
                          id: ep.id,
                          title: ep.title,
                          index: ep.index,
                          url: replacement.url,
                          playUrl: replacement.playUrl,
                        );
                      }).toList(),
                );
              }
            }
          }
        } catch (e) {
          debugPrint('Backup source failed: $e');
        }
      }

      return video;
    } catch (e) {
      debugPrint('LziApiScraper getDetail error: $e');
      throw Exception('视频详情暂时不可用，请重试或返回搜索选择其他数据源');
    }
  }

  @override
  Future<List<String>> getPlayUrls(String episodeUrl) async {
    // 如果已经是 m3u8 直链，直接返回
    if (episodeUrl.endsWith('.m3u8') || episodeUrl.contains('.m3u8?')) {
      return [episodeUrl];
    }

    // 如果是 share 链接，尝试解析出 m3u8 地址
    try {
      final response = await _httpClient.get(episodeUrl);
      final html = response.data.toString();

      // 从 HTML 中提取 m3u8 地址
      final m3u8Regex = RegExp(r'var\s+main\s*=\s*"([^"]+\.m3u8[^"]*)"');
      final match = m3u8Regex.firstMatch(html);
      if (match != null) {
        String m3u8Url = match.group(1)!;
        // 如果是相对路径，补全为绝对路径
        if (m3u8Url.startsWith('/')) {
          final uri = Uri.parse(episodeUrl);
          m3u8Url = '${uri.scheme}://${uri.host}$m3u8Url';
        }
        return [m3u8Url];
      }

      // 尝试匹配其他格式的 m3u8
      final m3u8Regex2 = RegExp(r'https?://\S+\.m3u8\S*');
      final matches = m3u8Regex2.allMatches(html);
      if (matches.isNotEmpty) {
        return matches.map((m) => m.group(0)!).toList();
      }

      return [episodeUrl]; // 回退：返回原始 URL
    } catch (e) {
      debugPrint('LziApiScraper getPlayUrls error: $e');
      return [episodeUrl];
    }
  }

  /// 解析视频数据
  VideoModel _parseVideo(Map<String, dynamic> item, {int source = 0}) {
    if (item['vod_id'] == null || item['vod_name'] is! String) {
      throw const FormatException('数据源缺少作品标识或标题');
    }
    final vodId = item['vod_id'].toString();
    if (!RegExp(r'^\d+$').hasMatch(vodId)) {
      throw const FormatException('数据源作品标识无效');
    }
    final title = item['vod_name'] as String;
    final pic = item['vod_pic'] as String?;
    final blurb = item['vod_blurb'] as String?;
    final content = item['vod_content'] as String?;
    // 清理 HTML 标签
    final description = (blurb ?? content ?? '').replaceAll(
      RegExp(r'<[^>]*>'),
      '',
    );
    final year = item['vod_year'] as String?;
    final area = item['vod_area'] as String?;
    final score = item['vod_score'] as String?;
    final doubanScore = item['vod_douban_score'] as String?;

    // 解析类型
    final className = item['vod_class'] as String?;

    // 解析评分
    double? rating;
    if (score != null && score != '0.0') {
      rating = double.tryParse(score);
    } else if (doubanScore != null && doubanScore != '0.0') {
      rating = double.tryParse(doubanScore);
    }

    // 解析选集
    final episodes = _parseEpisodes(item);

    return VideoModel(
      id: source == 0 ? vodId : '360zy:$vodId',
      title: title,
      cover: pic,
      description: description.isNotEmpty ? description : null,
      rating: rating,
      year: year,
      genre: className ?? area,
      source: source == 0 ? name : '360zy',
      sourceUrl: _apiSources[source],
      episodes: episodes,
    );
  }

  /// 快速 CDN 域名列表（按速度排序）
  static const List<String> _fastCdnDomains = [
    'vod1.maowushi.com', // 360zy.com 的 CDN，速度快
    'v.cdnlz22.com',
    'v.lzcdn27.com',
    'v.lzcdn31.com',
  ];

  /// 选择最佳播放源
  String _selectBestSource(List<String> sources) {
    // 优先选择 m3u8 直链
    final m3u8Sources = sources.where((s) => s.contains('.m3u8')).toList();
    if (m3u8Sources.isEmpty) return sources[0];

    // 在 m3u8 源中选择 CDN 速度最快的
    for (final cdn in _fastCdnDomains) {
      for (final source in m3u8Sources) {
        if (source.contains(cdn)) {
          return source;
        }
      }
    }

    // 默认使用第一个 m3u8 源
    return m3u8Sources[0];
  }

  /// 显示用的自动集数不能作为跨源剧集对应关系的依据。
  bool _hasExplicitEpisodeTitles(Map<String, dynamic> item) {
    final raw = item['vod_play_url'] as String? ?? '';
    if (raw.isEmpty) return false;
    return _selectBestSource(raw.split(r'$$$')).split('#').every((part) {
      final separator = part.indexOf(r'$');
      return separator > 0 && part.substring(0, separator).trim().isNotEmpty;
    });
  }

  /// 解析选集列表：$$$ 分线路，# 分剧集，$ 分标题和 URL。
  List<EpisodeModel> _parseEpisodes(Map<String, dynamic> item) {
    final playUrl = item['vod_play_url'] as String? ?? '';

    if (playUrl.isEmpty) return [];

    // 分隔不同播放源
    final sources = playUrl.split(r'$$$');

    // 选择最佳播放源
    final selectedSource = _selectBestSource(sources);

    final episodes = <EpisodeModel>[];

    // 分隔不同集数
    final episodeParts = selectedSource.split('#');
    for (int i = 0; i < episodeParts.length; i++) {
      final part = episodeParts[i];
      final dollarIndex = part.indexOf(r'$');
      if (dollarIndex == -1) continue;

      final title = part.substring(0, dollarIndex).trim();
      final url = part.substring(dollarIndex + 1).trim();

      if (url.isNotEmpty) {
        episodes.add(
          EpisodeModel(
            id: 'ep_${i + 1}',
            title: title.isNotEmpty ? title : '第 ${i + 1} 集',
            url: url,
            index: i,
            playUrl: url, // 直接播放地址
          ),
        );
      }
    }

    return episodes;
  }
}
