import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/history_item.dart';

/// 打开播放器：优先创建独立的播放窗口，关掉播放窗口不会退出主界面。
///
/// 如果当前平台/窗口创建失败（例如测试环境或非 Windows），回退到主窗口内路由播放。
Future<void> launchPlayer(
  BuildContext context, {
  required String videoUrl,
  required String title,
  List<Map<String, String>>? episodes,
  int currentIndex = 0,
  int startAt = 0,
  String? videoId,
  String? videoTitle,
  String? cover,
}) async {
  final extra = <String, dynamic>{
    'videoUrl': videoUrl,
    'title': title,
    'episodes': episodes,
    'currentIndex': currentIndex,
    'startAt': startAt,
    'videoId': videoId,
    'videoTitle': videoTitle,
    'cover': cover,
  };

  // flutter test 没有原生多窗口插件，直接走窗口内路由，保持测试可预期。
  final isTest =
      !kIsWeb &&
      (const bool.fromEnvironment('FLUTTER_TEST') ||
          Platform.environment['FLUTTER_TEST'] == 'true');
  final canCreateWindow = !kIsWeb && Platform.isWindows && !isTest;
  if (canCreateWindow) {
    try {
      final controller = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({'type': 'player', ...extra}),
          hiddenAtLaunch: true,
        ),
      );
      await controller.show();
      return;
    } catch (e) {
      debugPrint('创建独立播放窗口失败，回退到窗口内播放: $e');
    }
  }

  if (!context.mounted) return;
  context.push('/player', extra: extra);
}

/// 从历史条目续播：优先用剧集快照直达播放器，快照为空则回退详情页。
Future<void> launchHistoryResume(BuildContext context, HistoryItem item) async {
  if (item.episodes.isEmpty) {
    context.push('/detail/${Uri.encodeComponent(item.videoId)}');
    return;
  }
  final index = item.episodeIndex.clamp(0, item.episodes.length - 1);
  final episode = item.episodes[index];
  await launchPlayer(
    context,
    videoUrl: episode.playUrl ?? episode.url,
    title: '${item.title} - ${episode.title}',
    episodes:
        item.episodes
            .map((e) => {'title': e.title, 'url': e.playUrl ?? e.url})
            .toList(),
    currentIndex: index,
    startAt: item.position.inSeconds,
    videoId: item.videoId,
    videoTitle: item.title,
    cover: item.cover,
  );
}
