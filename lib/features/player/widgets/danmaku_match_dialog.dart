import 'package:flutter/material.dart';

import '../../../services/danmaku/dandanplay_client.dart';

/// 手动匹配弹幕对话框（R5）：列出弹弹play 搜索候选，选择后由调用方持久化。
class DanmakuMatchDialog extends StatelessWidget {
  const DanmakuMatchDialog({
    super.key,
    required this.future,
    required this.animeTitle,
    this.hasExistingMapping = false,
    this.existingLabel,
  });

  /// 用户选择「清除手动匹配」时返回的标记。
  static const String clearValue = '__clear__';

  final Future<List<DanmakuEpisodeMatch>> future;
  final String animeTitle;
  final bool hasExistingMapping;
  final String? existingLabel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('手动匹配弹幕 · $animeTitle'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: FutureBuilder<List<DanmakuEpisodeMatch>>(
          future: future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text(
                  '搜索失败：${snapshot.error}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              );
            }
            final matches = snapshot.data ?? const <DanmakuEpisodeMatch>[];
            final children = <Widget>[];
            if (hasExistingMapping) {
              children.add(
                ListTile(
                  leading: const Icon(Icons.link_off),
                  title: const Text('清除手动匹配（恢复自动匹配）'),
                  subtitle:
                      existingLabel == null ? null : Text('当前：$existingLabel'),
                  onTap: () => Navigator.of(context).pop(clearValue),
                ),
              );
              children.add(const Divider(height: 1));
            }
            if (matches.isEmpty) {
              children.add(const Center(child: Text('没有找到候选剧集')));
            } else {
              for (final match in matches) {
                children.add(
                  ListTile(
                    leading: const Icon(Icons.subtitles_outlined),
                    title: Text('${match.animeTitle} · ${match.episodeTitle}'),
                    subtitle: Text(
                      '第 ${match.episodeNumber ?? '?'} 集 · episodeId ${match.episodeId}',
                    ),
                    onTap: () => Navigator.of(context).pop(match),
                  ),
                );
              }
            }
            return ListView(children: children);
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
