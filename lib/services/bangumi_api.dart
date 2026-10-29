import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/bangumi_info.dart';

/// Bangumi (api.bgm.tv) 公开接口封装：标题搜索 → 评分/制作人员/角色。
/// bgm.tv 要求非默认 UA；任何网络/解析失败一律返回 null（静默降级）。
class BangumiApi {
  BangumiApi({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://api.bgm.tv',
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
              headers: {
                'User-Agent':
                    'NovaPlay/1.0 (Windows desktop; https://github.com/novaplay)',
                'Accept': 'application/json',
              },
            ));

  final Dio _dio;

  /// 参与制作人员卡的 infobox 键白名单（其余是放送日期等元数据，不入卡）
  static const _staffKeys = {
    '原作', '导演', '系列构成', '脚本', '人物原案', '人物设定', '音乐', '音响监督',
    '美术监督', '色彩设计', '摄影监督', '动画制作', '制作公司', '出品',
  };

  Future<BangumiInfo?> fetchInfo(String title) async {
    try {
      final keyword = title.trim();
      if (keyword.isEmpty) return null;

      final search = await _dio.post(
        '/v0/search/subjects',
        data: {
          'keyword': keyword,
          'filter': {'type': [2]}, // 2 = 动画
        },
      );
      final list = search.data['data'] as List?;
      if (list == null || list.isEmpty) return null;
      final subjectId = list.first['id'] as int;
      return await _fetchSubjectInfo(subjectId);
    } catch (e) {
      debugPrint('BangumiApi fetchInfo failed: $e');
      return null;
    }
  }

  Future<BangumiInfo?> _fetchSubjectInfo(int subjectId) async {
    try {
      final results = await Future.wait([
        _dio.get('/v0/subjects/$subjectId'),
        _dio.get('/v0/subjects/$subjectId/characters'),
      ]);
      final subject = results[0].data as Map<String, dynamic>;
      final charactersRaw =
          (results[1].data as List?) ?? const [];

      // 评分
      double? score;
      int? scoreCount;
      final rating = subject['rating'] as Map<String, dynamic>?;
      if (rating != null) {
        final rawScore = rating['score'];
        if (rawScore is num) score = rawScore.toDouble();
        final rawCount = rating['total'];
        if (rawCount is int) scoreCount = rawCount;
      }

      // 制作人员（infobox）
      final staff = <BangumiStaffEntry>[];
      final infobox = (subject['infobox'] as List?) ?? const [];
      for (final entry in infobox) {
        if (entry is! Map<String, dynamic>) continue;
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
        if (raw is! Map<String, dynamic>) continue;
        final name = raw['name']?.toString();
        if (name == null || name.isEmpty) continue;
        final images = raw['images'] as Map<String, dynamic>?;
        final actors = (raw['actors'] as List?) ?? const [];
        String? cv;
        for (final actor in actors) {
          if (actor is Map<String, dynamic> &&
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
        characters.add(BangumiCharacter(
          name: name,
          imageUrl: images?['medium']?.toString() ??
              images?['large']?.toString(),
          cv: cv,
        ));
      }

      return BangumiInfo(
        score: score,
        scoreCount: scoreCount,
        staff: staff,
        characters: characters,
      );
    } catch (e) {
      debugPrint('BangumiApi subject detail failed: $e');
      return null;
    }
  }

  /// infobox 的 value 可能是字符串、字符串数组或 [{v: '...'}] 数组
  String? _flattenInfoboxValue(dynamic value) {
    if (value is String) return value;
    if (value is List) {
      final parts = <String>[];
      for (final item in value) {
        if (item is String) {
          parts.add(item);
        } else if (item is Map<String, dynamic> && item['v'] != null) {
          parts.add(item['v'].toString());
        }
      }
      return parts.join('、');
    }
    return null;
  }
}
