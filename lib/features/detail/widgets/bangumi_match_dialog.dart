import 'package:flutter/material.dart';

import '../../../services/bangumi_api.dart';

/// Bangumi 资料手动纠正对话框（R7）：列出搜索候选，选择后由调用方持久化。
///
/// 「恢复自动匹配」必须独立于候选搜索状态：加载中、搜索失败、无候选时
/// 仍要能解除已有手动关联，否则用户会被错误映射永久锁住。
class BangumiMatchDialog extends StatelessWidget {
  const BangumiMatchDialog({
    super.key,
    required this.future,
    required this.title,
    this.hasExistingMapping = false,
    this.existingLabel,
  });

  static const String clearValue = '__clear__';

  final Future<List<BangumiSubjectCandidate>> future;
  final String title;
  final bool hasExistingMapping;
  final String? existingLabel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('选择 Bangumi 资料 · $title'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: FutureBuilder<List<BangumiSubjectCandidate>>(
          future: future,
          builder: (context, snapshot) {
            final children = <Widget>[];
            if (hasExistingMapping) {
              children.add(
                ListTile(
                  leading: const Icon(Icons.link_off),
                  title: const Text('恢复自动匹配'),
                  subtitle:
                      existingLabel == null ? null : Text('当前：$existingLabel'),
                  onTap: () => Navigator.of(context).pop(clearValue),
                ),
              );
              children.add(const Divider(height: 1));
            }

            if (snapshot.connectionState != ConnectionState.done) {
              children.add(
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              );
            } else if (snapshot.hasError) {
              children.add(
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '搜索失败：${snapshot.error}',
                    style: TextStyle(color: colorScheme.error),
                  ),
                ),
              );
            } else {
              final candidates =
                  snapshot.data ?? const <BangumiSubjectCandidate>[];
              if (candidates.isEmpty) {
                children.add(
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: Text('没有找到候选条目')),
                  ),
                );
              } else {
                for (final candidate in candidates) {
                  final subtitleParts = <String>[
                    candidate.name,
                    if (candidate.date != null && candidate.date!.isNotEmpty)
                      candidate.date!,
                    '匹配度 ${(candidate.score * 100).round()}%',
                  ];
                  children.add(
                    ListTile(
                      leading: const Icon(Icons.movie_outlined),
                      title: Text(candidate.displayTitle),
                      subtitle: Text(subtitleParts.join(' · ')),
                      onTap: () => Navigator.of(context).pop(candidate),
                    ),
                  );
                }
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
