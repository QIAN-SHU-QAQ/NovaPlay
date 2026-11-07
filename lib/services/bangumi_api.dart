import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/bangumi_info.dart';

/// Bangumi 搜索候选（R7：不再直接取搜索首项）。
class BangumiSubjectCandidate {
  const BangumiSubjectCandidate({
    required this.subjectId,
    required this.name,
    this.nameCn,
    this.date,
    this.score = 0,
  });

  final int subjectId;
  final String name;
  final String? nameCn;
  final String? date;
  final double score;

  String get displayTitle =>
      (nameCn?.trim().isNotEmpty ?? false) ? nameCn!.trim() : name.trim();
}

/// Bangumi (api.bgm.tv) 公开接口封装：标题搜索 → 评分/制作人员/角色。
///
/// bgm.tv 要求非默认 UA；网络/解析失败一律返回 null（静默降级）。
///
/// R7 改进：
/// - 搜索结果按标题（含中文名）相似度排序，选择最匹配项而不是首项；
/// - 相似度低于阈值时返回 null，避免错误关联；
/// - 角色接口失败时仍返回评分/制作人员（部分降级）；
/// - 支持调用方传入已确认的 subjectId（手动纠正/缓存复用）。
/// Bangumi 查询结果状态：区分「成功」「无可靠匹配」和「服务不可用」，
/// 详情页据此分别展示资料、手选入口或可重试的降级提示。
enum BangumiLookupStatus { success, noMatch, unavailable }

class BangumiLookupResult {
  const BangumiLookupResult._(this.status, {this.info, this.partial = false});

  const BangumiLookupResult.success(BangumiInfo info, {bool partial = false})
    : this._(BangumiLookupStatus.success, info: info, partial: partial);

  const BangumiLookupResult.noMatch() : this._(BangumiLookupStatus.noMatch);

  const BangumiLookupResult.unavailable()
    : this._(BangumiLookupStatus.unavailable);

  final BangumiLookupStatus status;
  final BangumiInfo? info;

  /// 评分/制作人员可用，但角色接口失败时为 true。
  final bool partial;
}

class BangumiApi {
  BangumiApi({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://api.bgm.tv',
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
              headers: {
                'User-Agent':
                    'NovaPlay/1.0 (Windows desktop; https://github.com/novaplay)',
                'Accept': 'application/json',
              },
            ),
          );

  final Dio _dio;

  /// 候选低于该相似度时视为不匹配。
  static const double minMatchScore = 0.5;

  /// 参与制作人员卡的 infobox 键白名单（其余是发售日期等元数据，不入卡）
  static const _staffKeys = {
    '原作',
    '导演',
    '系列构成',
    '脚本',
    '人物原案',
    '人物设定',
    '音乐',
    '音响监督',
    '美术监督',
    '色彩设计',
    '摄影监督',
    '动画制作',
    '制作公司',
    '出品',
  };

  /// 搜索动画候选并按匹配度排序。
  Future<List<BangumiSubjectCandidate>> searchSubjects(String title) async {
    final keyword = title.trim();
    if (keyword.isEmpty) return const [];
    final search = await _dio.post(
      '/v0/search/subjects',
      data: {
        'keyword': keyword,
        'filter': {
          'type': [2],
        }, // 2 = 动画
      },
    );
    final data = search.data;
    final list = data is Map ? (data['data'] as List?) : null;
    if (list == null || list.isEmpty) return const [];

    final candidates = <BangumiSubjectCandidate>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final id = raw['id'];
      if (id is! num) continue;
      final name = (raw['name'] as String?)?.trim() ?? '';
      final nameCn = (raw['name_cn'] as String?)?.trim();
      final date = (raw['date'] as String?)?.trim();
      candidates.add(
        BangumiSubjectCandidate(
          subjectId: id.toInt(),
          name: name,
          nameCn: nameCn,
          date: date,
        ),
      );
    }

    final queryYear = _extractYear(title);
    final querySeason = _extractSeason(title);
    final scored =
        candidates
            .map((candidate) {
              // 明确季号冲突的候选直接排除（第二季不能匹配第一季）。
              final candidateSeason = _extractSeason(
                '${candidate.nameCn ?? ''} ${candidate.name}',
              );
              if (querySeason != null &&
                  candidateSeason != null &&
                  querySeason != candidateSeason) {
                return null;
              }
              var score = _matchScore(title, candidate);
              // 季号明确匹配时提升优先级，避免被同名无季号条目以微弱优势
              // 拖入“无法唯一确定”的并列。
              if (querySeason != null &&
                  candidateSeason != null &&
                  querySeason == candidateSeason) {
                score += 0.1;
              }
              final candidateYear = _extractYear(candidate.date ?? '');
              // 作品名里带年份时，年份不同的候选明显降权。
              if (queryYear != null &&
                  candidateYear != null &&
                  queryYear != candidateYear) {
                score -= 0.3;
              }
              return BangumiSubjectCandidate(
                subjectId: candidate.subjectId,
                name: candidate.name,
                nameCn: candidate.nameCn,
                date: candidate.date,
                score: score,
              );
            })
            .whereType<BangumiSubjectCandidate>()
            .toList()
          ..sort((a, b) => b.score.compareTo(a.score));
    return scored;
  }

  /// 拉取 Bangumi 资料；[subjectId] 非空时直接使用该条目（手动纠正/缓存）。
  /// 查询 Bangumi 资料并区分失败原因。
  ///
  /// - 搜索/主体接口网络失败 → [BangumiLookupStatus.unavailable]（详情页可重试）；
  /// - 无候选、相似度不足、季号冲突或无法唯一确定 → [BangumiLookupStatus.noMatch]（详情页可手选）；
  /// - 主体成功但角色接口失败 → success + partial=true（保留评分/制作人员）。
  Future<BangumiLookupResult> lookup(String title, {int? subjectId}) async {
    var resolvedId = subjectId;
    String? matchedTitle;
    if (resolvedId == null) {
      final List<BangumiSubjectCandidate> candidates;
      try {
        candidates = await searchSubjects(title);
      } catch (e) {
        debugPrint('BangumiApi 搜索失败，资料不可用: $e');
        return const BangumiLookupResult.unavailable();
      }
      if (candidates.isEmpty) {
        return const BangumiLookupResult.noMatch();
      }
      final best = candidates.first;
      if (best.score < minMatchScore) {
        debugPrint(
          'BangumiApi: 标题相似度不足（${best.score.toStringAsFixed(2)}），'
          '跳过自动匹配：$title',
        );
        return const BangumiLookupResult.noMatch();
      }
      // 无法唯一确认时（并列候选、同名不同年份等）不自动选首项，
      // 交给详情页手动匹配，避免把另一部作品的资料关联过来。
      if (candidates.length > 1 &&
          (best.score - candidates[1].score).abs() < 0.05) {
        debugPrint(
          'BangumiApi: 候选无法唯一确定（${best.displayTitle} / '
          '${candidates[1].displayTitle}），跳过自动匹配：$title',
        );
        return const BangumiLookupResult.noMatch();
      }
      resolvedId = best.subjectId;
      matchedTitle = best.displayTitle;
    }

    final fetched = await _fetchSubjectInfo(
      resolvedId,
      matchedTitle: matchedTitle,
    );
    final info = fetched.info;
    if (info == null) return const BangumiLookupResult.unavailable();
    return BangumiLookupResult.success(info, partial: fetched.charactersFailed);
  }

  /// 兼容旧调用：成功返回资料，无匹配/不可用返回 null。
  Future<BangumiInfo?> fetchInfo(String title, {int? subjectId}) async {
    final result = await lookup(title, subjectId: subjectId);
    return result.info;
  }

  /// 提取季号（第N季 / Season N / Nth Season），无法确定返回 null。
  static int? _extractSeason(String input) {
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

  static int? _parseChineseNumber(String text) {
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

  Future<({BangumiInfo? info, bool charactersFailed})> _fetchSubjectInfo(
    int subjectId, {
    String? matchedTitle,
  }) async {
    try {
      final subjectResponse = await _dio.get('/v0/subjects/$subjectId');
      final subject = subjectResponse.data;
      if (subject is! Map<String, dynamic>) {
        debugPrint('BangumiApi: subject 返回格式异常');
        return (info: null, charactersFailed: false);
      }

      // 角色接口独立降级：失败时只保留评分/制作人员。
      var charactersRaw = const <dynamic>[];
      var charactersFailed = false;
      try {
        final charactersResponse = await _dio.get(
          '/v0/subjects/$subjectId/characters',
        );
        final data = charactersResponse.data;
        if (data is List) charactersRaw = data;
      } catch (e) {
        charactersFailed = true;
        debugPrint('BangumiApi: 获取角色失败，降级为部分资料: $e');
      }

      // 评分
      double? score;
      int? scoreCount;
      final rating = subject['rating'];
      if (rating is Map) {
        final rawScore = rating['score'];
        if (rawScore is num) score = rawScore.toDouble();
        final rawCount = rating['total'];
        if (rawCount is int) scoreCount = rawCount;
      }

      // 制作人员（infobox）
      final staff = <BangumiStaffEntry>[];
      final infobox = (subject['infobox'] as List?) ?? const [];
      for (final entry in infobox) {
        if (entry is! Map) continue;
        final key = entry['key']?.toString() ?? '';
        if (!_staffKeys.contains(key)) continue;
        final value = _flattenInfoboxValue(entry['value']);
        if (value != null && value.isNotEmpty) {
          staff.add(BangumiStaffEntry(role: key, name: value));
        }
        if (staff.length >= 8) break;
      }

      // 角色 + 声优
      final characters = <BangumiCharacter>[];
      for (final raw in charactersRaw.take(12)) {
        if (raw is! Map) continue;
        final name = raw['name']?.toString();
        if (name == null || name.isEmpty) continue;
        final images = raw['images'];
        final actors = (raw['actors'] as List?) ?? const [];
        String? cv;
        for (final actor in actors) {
          if (actor is Map &&
              actor['name'] != null &&
              actor['name'].toString().isNotEmpty) {
            // 优先中文配音名
            if (actor['lang'] == 'cn') {
              cv = actor['name'].toString();
              break;
            }
            cv ??= actor['name'].toString();
          }
        }
        characters.add(
          BangumiCharacter(
            name: name,
            imageUrl:
                images is Map
                    ? (images['medium']?.toString() ??
                        images['large']?.toString())
                    : null,
            cv: cv,
          ),
        );
      }

      return (
        info: BangumiInfo(
          subjectId: subjectId,
          matchedTitle: matchedTitle,
          score: score,
          scoreCount: scoreCount,
          staff: staff,
          characters: characters,
        ),
        charactersFailed: charactersFailed,
      );
    } catch (e) {
      debugPrint('BangumiApi subject detail failed: $e');
      return (info: null, charactersFailed: false);
    }
  }

  double _matchScore(String query, BangumiSubjectCandidate candidate) {
    var best = 0.0;
    for (final name in [candidate.name, candidate.nameCn]) {
      if (name == null || name.trim().isEmpty) continue;
      // 基础相似度忽略季数标记，再用保留季数的相似度做区分：
      // 「QA 样本 第二季」应优先匹配带「第二季」的条目，而不是同名第一季。
      final base = _titleSimilarity(query, name);
      final withSeason = _titleSimilarityKeepSeason(query, name);
      final combined = base * 0.75 + withSeason * 0.25;
      if (combined > best) best = combined;
    }
    return best;
  }

  static String _normalizeTitle(String input) {
    var text = input.toLowerCase();
    text = text.replaceAllMapped(
      RegExp(r'[\uFF10-\uFF19\uFF21-\uFF3A\uFF41-\uFF5A]'),
      (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0xFEE0),
    );
    text = text.replaceAll(
      RegExp(r'[\s\[\]\(\)（）【】「」『』《》〈〉,，.。!！?？:：;；~～\-—_/\\|·・×]'),
      '',
    );
    text = text.replaceAll(RegExp(r'第[0-9一二三四五六七八九十]+[季期部]'), '');
    text = text.replaceAll(RegExp(r'season[0-9]+'), '');
    return text;
  }

  static String _normalizeTitleKeepSeason(String input) {
    var text = input.toLowerCase();
    text = text.replaceAllMapped(
      RegExp(r'[\uFF10-\uFF19\uFF21-\uFF3A\uFF41-\uFF5A]'),
      (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0xFEE0),
    );
    text = text.replaceAll(
      RegExp(r'[\s\[\]\(\)（）【】「」『』《》〈〉,，.。!！?？:：;；~～\-—_/\\|·・×]'),
      '',
    );
    return text;
  }

  static double _titleSimilarityKeepSeason(String a, String b) {
    final left = _normalizeTitleKeepSeason(a);
    final right = _normalizeTitleKeepSeason(b);
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

  static double _titleSimilarity(String a, String b) {
    final left = _normalizeTitle(a);
    final right = _normalizeTitle(b);
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

  static Set<String> _bigrams(String value) {
    if (value.length < 2) return {value};
    return {
      for (var i = 0; i < value.length - 1; i++) value.substring(i, i + 2),
    };
  }

  static int? _extractYear(String text) {
    final match = RegExp(r'(19|20)\d{2}').firstMatch(text);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  /// infobox 的 value 可能是字符串、字符串数组或 [{v: '...'}] 数组
  String? _flattenInfoboxValue(dynamic value) {
    if (value is String) return value;
    if (value is List) {
      final parts = <String>[];
      for (final item in value) {
        if (item is String) {
          parts.add(item);
        } else if (item is Map && item['v'] != null) {
          parts.add(item['v'].toString());
        }
      }
      return parts.join('、');
    }
    return null;
  }
}
