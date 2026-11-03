import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/play_launcher.dart';
import '../../providers/download_provider.dart';
import '../../services/download_service.dart';

class DownloadScreen extends ConsumerWidget {
  const DownloadScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(downloadTasksProvider);
    final notifier = ref.read(downloadTasksProvider.notifier);
    final colors = Theme.of(context).colorScheme;
    final hasCompleted = tasks.any((t) => t.status == DownloadStatus.completed);

    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: [
          if (hasCompleted)
            TextButton.icon(
              onPressed: notifier.clearCompleted,
              icon: const Icon(Icons.cleaning_services_outlined, size: 18),
              label: const Text('清除已完成'),
            ),
        ],
      ),
      body:
          tasks.isEmpty
              ? _EmptyState(colors: colors)
              : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: tasks.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder:
                        (context, index) => _DownloadTaskTile(
                          task: tasks[index],
                          onPause: () => notifier.pause(tasks[index].id),
                          onResume: () => notifier.resume(tasks[index].id),
                          onRemove: () => notifier.remove(tasks[index].id),
                          onShowInFolder:
                              tasks[index].status == DownloadStatus.completed
                                  ? () => _showInFolder(tasks[index])
                                  : null,
                          onPlay:
                              tasks[index].status == DownloadStatus.completed
                                  ? () => launchPlayer(
                                    context,
                                    videoUrl: tasks[index].savePath,
                                    title: tasks[index].title,
                                    videoId: tasks[index].videoId,
                                    videoTitle: tasks[index].title,
                                  )
                                  : null,
                        ),
                  ),
                ),
              ),
    );
  }

  Future<void> _showInFolder(DownloadTask task) async {
    if (!Platform.isWindows) return;
    try {
      final file = File(task.savePath);
      if (await file.exists()) {
        await Process.run('explorer.exe', ['/select,', file.path]);
        return;
      }
      final parent = file.parent;
      if (await parent.exists()) {
        await Process.run('explorer.exe', [parent.path]);
      }
    } catch (e) {
      debugPrint('打开下载文件夹失败: $e');
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.download_for_offline_outlined,
              size: 32,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            const Text('还没有下载任务'),
            const SizedBox(height: 6),
            Text(
              '在作品详情页的选集卡片上点击下载按钮，即可离线保存。',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadTaskTile extends StatelessWidget {
  const _DownloadTaskTile({
    required this.task,
    required this.onPause,
    required this.onResume,
    required this.onRemove,
    this.onShowInFolder,
    this.onPlay,
  });

  final DownloadTask task;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onRemove;
  final VoidCallback? onShowInFolder;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final failed = task.status == DownloadStatus.failed;
    final completed = task.status == DownloadStatus.completed;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onPlay,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _statusText(),
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                failed ? colors.error : colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (task.status == DownloadStatus.queued ||
                      task.status == DownloadStatus.resolving ||
                      task.status == DownloadStatus.downloading ||
                      task.status == DownloadStatus.merging)
                    IconButton(
                      tooltip: '暂停',
                      icon: const Icon(Icons.pause_circle_outline),
                      onPressed: onPause,
                    )
                  else if (task.status == DownloadStatus.paused || failed)
                    IconButton(
                      tooltip: failed ? '重试' : '继续',
                      icon: const Icon(Icons.play_circle_outline),
                      onPressed: onResume,
                    )
                  else
                    Icon(Icons.check_circle_outline, color: colors.primary),
                  if (completed && onShowInFolder != null)
                    IconButton(
                      tooltip: '在文件夹中显示',
                      icon: const Icon(Icons.folder_open_outlined),
                      onPressed: onShowInFolder,
                    ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: onRemove,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: completed ? 1 : task.progress,
                  minHeight: 4,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                completed
                    ? '已保存：${task.savePath}'
                    : (task.error ??
                        '进度 ${(task.progress * 100).toStringAsFixed(0)}%'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusText() {
    if (task.status == DownloadStatus.downloading) {
      return '${task.status.label} · ${(task.progress * 100).toStringAsFixed(0)}%';
    }
    if (task.status == DownloadStatus.completed) {
      return '${task.status.label} · 点击播放';
    }
    return task.status.label;
  }
}
