import 'package:flutter/material.dart';

import '../../../services/bangumi_api.dart';

/// Bangumi 资料手动纠正对话框（R7）：列出搜索候选，选择后由调用方持久化。
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
    return AlertDialog(
      title: Text('选择 Bangumi 资料 · $title'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: FutureBuilder<List<BangumiSubjectCandidate>>(
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
            final candidates =
                snapshot.data ?? const <BangumiSubjectCandidate>[];
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
            if (candidates.isEmpty) {
              children.add(const Center(child: Text('没有找到候选条目')));
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
