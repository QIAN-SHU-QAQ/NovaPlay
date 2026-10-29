import 'video_model.dart';

/// 观看历史条目
/// episodes 保存播放时的剧集快照，历史页可直接续播，无需重新请求详情
class HistoryItem {
  final String videoId;
  final String title;
  final String? cover;
  final List<EpisodeModel> episodes;
  final int episodeIndex;
  final Duration position;
  final Duration duration;
  final DateTime watchedAt;

  HistoryItem({
    required this.videoId,
    required this.title,
    this.cover,
    this.episodes = const [],
    required this.episodeIndex,
    required this.position,
    this.duration = Duration.zero,
    required this.watchedAt,
  });

  /// 观看进度 0.0 ~ 1.0（时长未知时返回 0）
  double get progress => duration.inMilliseconds > 0
      ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
      : 0.0;

  String? get episodeTitle =>
      episodeIndex >= 0 && episodeIndex < episodes.length
          ? episodes[episodeIndex].title
          : null;

  factory HistoryItem.fromJson(Map<String, dynamic> json) {
    return HistoryItem(
      videoId: json['videoId'] as String,
      title: json['title'] as String,
      cover: json['cover'] as String?,
      episodes: (json['episodes'] as List?)
              ?.map((e) => EpisodeModel.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      episodeIndex: json['episodeIndex'] as int? ?? 0,
      position: Duration(milliseconds: json['positionMs'] as int? ?? 0),
      duration: Duration(milliseconds: json['durationMs'] as int? ?? 0),
      watchedAt:
          DateTime.tryParse(json['watchedAt'] as String? ?? '') ??
              DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'videoId': videoId,
      'title': title,
      'cover': cover,
      'episodes': episodes.map((e) => e.toJson()).toList(),
      'episodeIndex': episodeIndex,
      'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
      'watchedAt': watchedAt.toIso8601String(),
    };
  }
}
