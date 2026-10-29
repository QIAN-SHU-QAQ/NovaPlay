import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/history_item.dart';

/// 直达播放器的统一入口，extra 键与 routes.dart 中 /player 的解析一一对应。
void launchPlayer(
  BuildContext context, {
  required String videoUrl,
  required String title,
  List<Map<String, String>>? episodes,
  int currentIndex = 0,
  int startAt = 0,
  String? videoId,
  String? videoTitle,
  String? cover,
}) {
  context.push('/player', extra: {
    'videoUrl': videoUrl,
    'title': title,
    'episodes': episodes,
    'currentIndex': currentIndex,
    'startAt': startAt,
    'videoId': videoId,
    'videoTitle': videoTitle,
    'cover': cover,
  });
}

/// 从历史条目续播：优先用剧集快照直达播放器，快照为空则回退详情页。
void launchHistoryResume(BuildContext context, HistoryItem item) {
  if (item.episodes.isEmpty) {
    context.push('/detail/${Uri.encodeComponent(item.videoId)}');
    return;
  }
  final index = item.episodeIndex.clamp(0, item.episodes.length - 1);
  final episode = item.episodes[index];
  launchPlayer(
    context,
    videoUrl: episode.playUrl ?? episode.url,
    title: '${item.title} - ${episode.title}',
    episodes: item.episodes
        .map((e) => {'title': e.title, 'url': e.playUrl ?? e.url})
        .toList(),
    currentIndex: index,
    startAt: item.position.inSeconds,
    videoId: item.videoId,
    videoTitle: item.title,
    cover: item.cover,
  );
}
