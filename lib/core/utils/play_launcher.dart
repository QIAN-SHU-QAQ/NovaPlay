import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/history_item.dart';
import '../../models/video_model.dart';
import '../../services/prefs_bridge.dart';
import 'history_resume.dart';

/// 当前进程是否运行在 `flutter test` 里（测试环境不启动独立进程）。
bool get _isFlutterTest =>
    !kIsWeb &&
    (const bool.fromEnvironment('FLUTTER_TEST') ||
        Platform.environment['FLUTTER_TEST'] == 'true');

/// 打开播放器：启动一个独立的本程序进程来显示播放窗口。
///
/// 独立进程的好处：关闭播放窗口只结束该进程，主界面完全不受影响。
/// 如果启动失败（例如 flutter test 或非 Windows），回退到主窗口内路由播放。
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
    // 主进程配置桥端口：播放器的进度/设置写入经由主进程持久化。
    'bridgePort': PrefsBridgeServer.instance?.port,
  };

  if (!kIsWeb && Platform.isWindows && !_isFlutterTest) {
    try {
      await Process.start(Platform.resolvedExecutable, [
        '--player',
        jsonEncode(extra),
      ], mode: ProcessStartMode.detached);
      return;
    } catch (e) {
      debugPrint('启动独立播放进程失败，回退到窗口内播放: $e');
    }
  }

  if (!context.mounted) return;
  context.push('/player', extra: extra);
}

/// 正在解析续播目标的作品，防止双击重复打开播放器。
final Set<String> _resuming = <String>{};

/// 从历史条目续播（R4）。
///
/// 不直接使用历史快照里的播放地址（可能已过期）：先通过 [fetchDetail]
/// 刷新作品详情，重新定位剧集与播放地址；刷新失败或找不到对应集时回退
/// 到作品详情页，避免播放错误地址。
Future<void> launchHistoryResume(
  BuildContext context,
  HistoryItem item, {
  Future<VideoModel?> Function()? fetchDetail,
}) async {
  if (_resuming.contains(item.videoId)) return;
  _resuming.add(item.videoId);
  try {
    HistoryResumeTarget? target;
    if (fetchDetail != null) {
      target = await resolveHistoryResumeTarget(item, fetchDetail: fetchDetail);
    } else if (item.episodes.isNotEmpty) {
      // 没有详情刷新入口时（测试/降级）仍使用快照，保持行为可用。
      final index = item.episodeIndex.clamp(0, item.episodes.length - 1);
      final episode = item.episodes[index];
      target = HistoryResumeTarget(
        videoUrl: episode.playUrl ?? episode.url,
        title: '${item.title} - ${episode.title}',
        episodes:
            item.episodes
                .map((e) => {'title': e.title, 'url': e.playUrl ?? e.url})
                .toList(),
        index: index,
        videoTitle: item.title,
        cover: item.cover,
      );
    }

    if (target == null) {
      if (context.mounted) {
        context.push('/detail/${Uri.encodeComponent(item.videoId)}');
      }
      return;
    }
    if (!context.mounted) return;
    await launchPlayer(
      context,
      videoUrl: target.videoUrl,
      title: target.title,
      episodes: target.episodes,
      currentIndex: target.index,
      startAt: item.position.inSeconds,
      videoId: item.videoId,
      videoTitle: target.videoTitle,
      cover: target.cover,
    );
  } finally {
    _resuming.remove(item.videoId);
  }
}
