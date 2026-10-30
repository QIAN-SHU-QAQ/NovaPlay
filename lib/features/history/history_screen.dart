import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/play_launcher.dart';
import '../../models/history_item.dart';
import '../../providers/history_provider.dart';
import '../../shared/widgets/wide_media_card.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('历史'),
        actions: [
          TextButton(
            onPressed:
                history.isEmpty ? null : () => _confirmClear(context, ref),
            child: const Text('清除'),
          ),
        ],
      ),
      body:
          history.isEmpty
              ? _buildEmptyState(context)
              : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: history.length,
                    itemBuilder:
                        (context, index) =>
                            _buildHistoryCard(context, ref, history[index]),
                  ),
                ),
              ),
    );
  }

  void _confirmClear(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('清除历史'),
            content: const Text('确定要清除所有观看历史吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  ref.read(historyProvider.notifier).clear();
                  Navigator.pop(context);
                },
                child: const Text('确定'),
              ),
            ],
          ),
    );
  }

  Widget _buildHistoryCard(
    BuildContext context,
    WidgetRef ref,
    HistoryItem item,
  ) {
    return WideMediaCard(
      title: item.title,
      coverUrl: item.cover,
      subtitle: item.episodeTitle ?? '已看 ${_formatDuration(item.position)}',
      meta: _formatTime(item.watchedAt),
      progress: item.progress > 0 ? item.progress : null,
      onTap: () => launchHistoryResume(context, item),
      onResume: () => launchHistoryResume(context, item),
      onRemove: () => ref.read(historyProvider.notifier).remove(item.videoId),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.history_rounded,
            size: 28,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            '暂无观看记录',
            style: TextStyle(fontSize: 15, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Text(
            '观看视频后会自动记录在这里',
            style: TextStyle(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final m = duration.inMinutes;
    final s = duration.inSeconds % 60;
    if (m >= 60) {
      final h = m ~/ 60;
      return '$h:${(m % 60).toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 60) {
      return '${diff.inMinutes} 分钟前';
    } else if (diff.inHours < 24) {
      return '${diff.inHours} 小时前';
    } else if (diff.inDays < 7) {
      return '${diff.inDays} 天前';
    } else {
      return '${time.month}/${time.day}';
    }
  }
}
