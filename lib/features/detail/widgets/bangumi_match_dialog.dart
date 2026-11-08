import 'package:flutter/material.dart';

import '../../../services/bangumi_api.dart';

/// Bangumi 资料手动纠正对话框（R7）：列出搜索候选，选择后由调用方持久化。
///
/// 「恢复自动匹配」必须独立于候选搜索状态：加载中、搜索失败、无候选时
/// 仍要能解除已有手动关联，否则用户会被错误映射永久锁住。
///
/// 候选为空或搜错关键词时，用户可以在弹窗内修改关键词重新搜索，
/// 避免「空候选可手选」只有入口而没有实际可选内容。
class BangumiMatchDialog extends StatefulWidget {
  const BangumiMatchDialog({
    super.key,
    required this.search,
    required this.initialQuery,
    required this.title,
    this.hasExistingMapping = false,
    this.existingLabel,
  });

  static const String clearValue = '__clear__';

  final Future<List<BangumiSubjectCandidate>> Function(String query) search;
  final String initialQuery;
  final String title;
  final bool hasExistingMapping;
  final String? existingLabel;

  @override
  State<BangumiMatchDialog> createState() => _BangumiMatchDialogState();
}

class _BangumiMatchDialogState extends State<BangumiMatchDialog> {
  late final TextEditingController _queryController;
  late Future<List<BangumiSubjectCandidate>> _future;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.initialQuery);
    _future = widget.search(widget.initialQuery);
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  void _runSearch() {
    final query = _queryController.text.trim();
    setState(() {
      _future =
          query.isEmpty
              ? Future.value(const <BangumiSubjectCandidate>[])
              : widget.search(query);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('选择 Bangumi 资料 · ${widget.title}'),
      content: SizedBox(
        width: 560,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: _queryController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _runSearch(),
              decoration: InputDecoration(
                labelText: '搜索关键词',
                hintText: '可换关键词或输入作品名',
                isDense: true,
                suffixIcon: IconButton(
                  tooltip: '搜索候选',
                  icon: const Icon(Icons.search),
                  onPressed: _runSearch,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<BangumiSubjectCandidate>>(
                future: _future,
                builder: (context, snapshot) {
                  final children = <Widget>[];
                  if (widget.hasExistingMapping) {
                    children.add(
                      ListTile(
                        leading: const Icon(Icons.link_off),
                        title: const Text('恢复自动匹配'),
                        subtitle:
                            widget.existingLabel == null
                                ? null
                                : Text('当前：${widget.existingLabel}'),
                        onTap:
                            () => Navigator.of(
                              context,
                            ).pop(BangumiMatchDialog.clearValue),
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
                          if (candidate.date != null &&
                              candidate.date!.isNotEmpty)
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
          ],
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
