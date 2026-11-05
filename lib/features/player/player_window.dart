import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/theme.dart';
import '../../core/window/player_window_bridge.dart';
import 'player_screen.dart';

/// 独立播放进程的根 Widget。
///
/// 主进程通过 `--player <json>` 启动新的本程序进程，main() 解析参数后交给本类。
class PlayerWindowApp extends StatefulWidget {
  const PlayerWindowApp({super.key, required this.arguments});

  final Map<String, dynamic> arguments;

  @override
  State<PlayerWindowApp> createState() => _PlayerWindowAppState();
}

class _PlayerWindowAppState extends State<PlayerWindowApp> {
  @override
  void initState() {
    super.initState();
    final title =
        widget.arguments['videoTitle'] as String? ??
        widget.arguments['title'] as String?;
    if (title != null && title.isNotEmpty) {
      PlayerWindowBridge.setTitle(title);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        home: _buildPlayer(),
      ),
    );
  }

  PlayerScreen _buildPlayer() {
    final args = widget.arguments;
    final rawEpisodes = args['episodes'];
    List<Map<String, String>>? episodes;
    if (rawEpisodes is List) {
      episodes =
          rawEpisodes
              .whereType<Map>()
              .map(
                (item) => item.map(
                  (key, value) => MapEntry(key.toString(), value.toString()),
                ),
              )
              .toList();
    }

    return PlayerScreen(
      videoUrl: (args['videoUrl'] as String?) ?? '',
      title: (args['title'] as String?) ?? '播放',
      episodes: episodes,
      currentIndex: (args['currentIndex'] as num?)?.toInt() ?? 0,
      startAt: (args['startAt'] as num?)?.toInt() ?? 0,
      videoId: args['videoId'] as String?,
      videoTitle: args['videoTitle'] as String?,
      cover: args['cover'] as String?,
      sourceId: args['sourceId'] as String?,
    );
  }
}
