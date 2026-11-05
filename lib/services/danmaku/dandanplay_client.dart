import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../models/danmaku_model.dart';

/// 弹弹play 开放弹幕网络客户端。
///
/// 协议来自官方 Swagger（https://api.dandanplay.net/swagger）：
/// - 请求头：X-AppId / X-Timestamp（秒）/ X-Signature
/// - 签名 = Base64(SHA256(AppId + Timestamp + path + AppSecret))，path 不含 query
/// - 搜索剧集：GET /api/v2/search/episodes?anime=&episode=
/// - 获取弹幕：GET /api/v2/comment/{episodeId}?withRelated=true&chConvert=1
///
/// AppId/AppSecret 需在 https://dev.dandanplay.com 免费申请后填入设置。
class DandanplayException implements Exception {
  final String message;

  const DandanplayException(this.message);

  @override
  String toString() => message;
}

/// 搜索结果中的一集（已摊平 anime + episode）。
class DanmakuEpisodeMatch {
  final int episodeId;
  final String animeTitle;
  final String episodeTitle;
  final String? episodeNumber;

  const DanmakuEpisodeMatch({
    required this.episodeId,
    required this.animeTitle,
    required this.episodeTitle,
    this.episodeNumber,
  });
}

class DanmakuLoadResult {
  final List<DanmakuComment> comments;
  final int episodeId;
  final String animeTitle;
  final String episodeTitle;

  const DanmakuLoadResult({
    required this.comments,
    required this.episodeId,
    required this.animeTitle,
    required this.episodeTitle,
  });
}

class DandanplayClient {
  DandanplayClient({
    required this.appId,
    required this.appSecret,
    Dio? dio,
    String baseUrl = 'https://api.dandanplay.net',
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 15),
             ),
           ),
       _baseUrl = baseUrl;

  final String appId;
  final String appSecret;
  final Dio _dio;
  final String _baseUrl;

  /// 签名算法（公开出来便于单元测试）。
  static String signature(
    String appId,
    int timestamp,
    String path,
    String appSecret,
  ) {
    final data = utf8.encode('$appId$timestamp$path$appSecret');
    return base64Encode(sha256.convert(data).bytes);
  }

  Map<String, String> _headers(String path) {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return {
      'X-AppId': appId,
      'X-Timestamp': '$timestamp',
      'X-Signature': signature(appId, timestamp, path, appSecret),
      'User-Agent': 'NovaPlay/1.1 (Windows)',
      'Accept': 'application/json',
    };
  }

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String> query = const {},
  ]) async {
    final uri = Uri.parse('$_baseUrl$path').replace(
      queryParameters:
          query.isEmpty ? null : query.map((k, v) => MapEntry(k, v)),
    );
    try {
      final response = await _dio.getUri<dynamic>(
        uri,
        options: Options(
          headers: _headers(path),
          responseType: ResponseType.json,
        ),
      );
      final data = response.data;
      if (data is! Map) {
        throw const DandanplayException('弹弹play 返回数据格式异常');
      }
      final result = data.cast<String, dynamic>();
      final errorCode = result['errorCode'];
      if (errorCode is num && errorCode != 0) {
        throw DandanplayException(
          '弹弹play 返回错误：${result['errorMessage'] ?? errorCode}',
        );
      }
      return result;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw const DandanplayException('AppId 或 AppSecret 无效，请检查设置');
      }
      throw DandanplayException('请求弹弹play 失败：${e.message ?? e.type.name}');
    }
  }

  Future<List<DanmakuEpisodeMatch>> searchEpisodes({
    required String anime,
    String? episode,
  }) async {
    final data = await _get('/api/v2/search/episodes', {
      'anime': anime,
      if (episode != null && episode.isNotEmpty) 'episode': episode,
    });
    final animes = data['animes'];
    if (animes is! List) return const [];

    final matches = <DanmakuEpisodeMatch>[];
    for (final animeJson in animes) {
      if (animeJson is! Map) continue;
      final animeTitle = (animeJson['animeTitle'] as String?)?.trim() ?? '';
      final episodes = animeJson['episodes'];
      if (episodes is! List) continue;
      for (final episodeJson in episodes) {
        if (episodeJson is! Map) continue;
        final id = episodeJson['episodeId'];
        if (id is! num) continue;
        matches.add(
          DanmakuEpisodeMatch(
            episodeId: id.toInt(),
            animeTitle: animeTitle,
            episodeTitle:
                (episodeJson['episodeTitle'] as String?)?.trim() ?? '',
            episodeNumber: episodeJson['episodeNumber']?.toString(),
          ),
        );
      }
    }
    return matches;
  }

  Future<List<DanmakuComment>> fetchComments(
    int episodeId, {
    int from = 0,
    bool withRelated = true,
  }) async {
    final data = await _get('/api/v2/comment/$episodeId', {
      'withRelated': '$withRelated',
      'chConvert': '1',
      'from': '$from',
    });
    final rawComments = data['comments'];
    if (rawComments is! List) return const [];

    final comments = <DanmakuComment>[];
    for (final raw in rawComments) {
      if (raw is! Map) continue;
      final cid = raw['cid'];
      final p = raw['p'];
      final text = raw['m'];
      if (cid is! num || p is! String || text is! String) continue;
      final comment = DanmakuComment.tryParse(
        cid: cid.toInt(),
        p: p,
        text: text,
      );
      if (comment != null) comments.add(comment);
    }
    comments.sort((a, b) => a.time.compareTo(b.time));
    return comments;
  }

  /// 按「作品名 + 剧集标题」自动匹配弹幕库并拉取弹幕。
  ///
  /// 匹配策略：优先按集数搜索，其次按作品名搜索后用标题相似度 + 集数距离挑选。
  Future<DanmakuLoadResult?> loadForEpisode({
    required String animeTitle,
    required String episodeTitle,
    required int episodeIndex,
  }) async {
    final number = extractEpisodeNumber(episodeTitle) ?? (episodeIndex + 1);
    final season = extractSeason(animeTitle);

    var matches = await searchEpisodes(anime: animeTitle, episode: '$number');
    if (matches.isEmpty) {
      matches = await searchEpisodes(anime: animeTitle);
    }
    if (matches.isEmpty) {
      // 带季数标记的标题可能搜不到，退化为去掉季数后的作品名。
      matches = await searchEpisodes(
        anime: normalizeDanmakuTitle(animeTitle),
        episode: '$number',
      );
    }
    if (matches.isEmpty) return null;

    final best = pickBestMatch(matches, animeTitle, number, season: season);
    if (best == null) return null;

    final comments = await fetchComments(best.episodeId);
    return DanmakuLoadResult(
      comments: comments,
      episodeId: best.episodeId,
      animeTitle: best.animeTitle,
      episodeTitle: best.episodeTitle,
    );
  }
}

/// 标题归一化：去除空白、标点、季数标记，全角转半角。
String normalizeDanmakuTitle(String input) {
  var title = input.toLowerCase();

  // 全角数字/字母 → 半角
  title = title.replaceAllMapped(
    RegExp(r'[\uFF10-\uFF19\uFF21-\uFF3A\uFF41-\uFF5A]'),
    (match) {
      final code = match.group(0)!.codeUnitAt(0);
      return String.fromCharCode(code - 0xFEE0);
    },
  );

  title = title.replaceAll(
    RegExp(r'[\s\[\]\(\)（）【】「」『』《》〈〉,，.。!！?？:：;；~～\-—_/\\|·・]'),
    '',
  );
  title = title.replaceAll(RegExp(r'第[0-9一二三四五六七八九十]+[季期部]'), '');
  title = title.replaceAll(RegExp(r'season[0-9]+'), '');
  return title;
}

/// 提取标题里的集数（如「第 3 集」「EP12」「03」），提取不到返回 null。
int? extractEpisodeNumber(String title) {
  final normalized = title.replaceAllMapped(
    RegExp(r'[\uFF10-\uFF19]'),
    (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0xFEE0),
  );
  final patterns = <RegExp>[
    RegExp(r'第\s*(\d+(?:\.\d+)?)\s*[集话話回期]'),
    RegExp(r'[Ee][Pp]?\s*(\d+(?:\.\d+)?)'),
    RegExp(r'(\d+(?:\.\d+)?)\s*[集话話回期]'),
    RegExp(r'^(\d+(?:\.\d+)?)$'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(normalized);
    if (match != null) {
      final value = double.tryParse(match.group(1)!);
      if (value != null) return value.round();
    }
  }
  return null;
}

/// 提取标题里的季数（「第 3 季」「Season 2」「2nd Season」「S2」），无季数返回 null。
int? extractSeason(String input) {
  final normalized = input.replaceAllMapped(
    RegExp(r'[\uFF10-\uFF19]'),
    (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0xFEE0),
  );
  final patterns = <RegExp>[
    RegExp(r'第\s*([0-9一二三四五六七八九十]+)\s*[季期部]'),
    RegExp(r'season\s*([0-9]{1,2})', caseSensitive: false),
    RegExp(r'([0-9]{1,2})(?:st|nd|rd|th)\s*season', caseSensitive: false),
    RegExp(r'[Ss]([0-9]{1,2})(?![0-9])'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(normalized);
    if (match == null) continue;
    final raw = match.group(1)!;
    final value = int.tryParse(raw) ?? _parseChineseNumber(raw);
    if (value != null && value > 0) return value;
  }
  return null;
}

int? _parseChineseNumber(String text) {
  const digits = {
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  if (text.isEmpty) return null;
  final tenIndex = text.indexOf('十');
  if (tenIndex < 0) return digits[text];
  final tensText = text.substring(0, tenIndex);
  final onesText = text.substring(tenIndex + 1);
  final tens = tensText.isEmpty ? 1 : (digits[tensText] ?? 0);
  final ones = onesText.isEmpty ? 0 : (digits[onesText] ?? 0);
  return tens * 10 + ones;
}

/// 标题相似度（0-1），用于从搜索结果里挑选最匹配的作品。
double titleSimilarity(String a, String b) {
  final left = normalizeDanmakuTitle(a);
  final right = normalizeDanmakuTitle(b);
  if (left.isEmpty || right.isEmpty) return 0;
  if (left == right) return 1;
  if (left.contains(right) || right.contains(left)) return 0.85;

  final leftGrams = _bigrams(left);
  final rightGrams = _bigrams(right);
  if (leftGrams.isEmpty || rightGrams.isEmpty) return 0;
  final intersection = leftGrams.intersection(rightGrams).length;
  final union = leftGrams.length + rightGrams.length - intersection;
  return union == 0 ? 0 : intersection / union;
}

Set<String> _bigrams(String value) {
  if (value.length < 2) return {value};
  return {for (var i = 0; i < value.length - 1; i++) value.substring(i, i + 2)};
}

/// 从候选剧集里挑最匹配的一集。
///
/// 规则（R5）：
/// - 作品名相似度低于 [minSimilarity] 的候选直接丢弃；全部不达标时返回 null，
///   不再把无关作品当成本集弹幕；
/// - 双方都能解析出季数且季数不同时直接排除（第二季不能匹配第一季）；
/// - 只有一方能解析季数时轻微降权，相似度仍然优先；
/// - 集数差距作为次要修正。
DanmakuEpisodeMatch? pickBestMatch(
  List<DanmakuEpisodeMatch> matches,
  String animeTitle,
  int episodeNumber, {
  int? season,
  double minSimilarity = 0.45,
}) {
  if (matches.isEmpty) return null;

  final querySeason = season ?? extractSeason(animeTitle);
  DanmakuEpisodeMatch? best;
  var bestScore = double.negativeInfinity;
  for (final match in matches) {
    final similarity = titleSimilarity(animeTitle, match.animeTitle);
    if (similarity < minSimilarity) continue;

    final candidateSeason = extractSeason(match.animeTitle);
    if (querySeason != null &&
        candidateSeason != null &&
        candidateSeason != querySeason) {
      continue;
    }
    final seasonPenalty =
        (querySeason == null) != (candidateSeason == null) ? 0.15 : 0.0;

    final candidateNumber =
        extractEpisodeNumber(match.episodeTitle) ??
        int.tryParse(match.episodeNumber ?? '');
    final distance =
        candidateNumber == null ? 0 : (candidateNumber - episodeNumber).abs();
    final score =
        similarity * 10 -
        seasonPenalty * 10 -
        (distance > 2 ? 3 : distance * 0.5);
    if (score > bestScore) {
      bestScore = score;
      best = match;
    }
  }
  debugPrint(
    '弹幕匹配：$animeTitle 第$episodeNumber集 (季数=$querySeason) → '
    '${best?.animeTitle} ${best?.episodeTitle} (episodeId=${best?.episodeId})',
  );
  return best;
}
