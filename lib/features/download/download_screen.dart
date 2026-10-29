import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config/theme.dart';

class DownloadScreen extends ConsumerStatefulWidget {
  const DownloadScreen({super.key});

  @override
  ConsumerState<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends ConsumerState<DownloadScreen> {
  // Mock download tasks
  final List<Map<String, dynamic>> _downloads = [
    {
      'title': '视频标题 1',
      'progress': 0.75,
      'size': '1.2 GB',
      'status': 'downloading',
    },
    {
      'title': '视频标题 2',
      'progress': 1.0,
      'size': '800 MB',
      'status': 'completed',
    },
    {
      'title': '视频标题 3',
      'progress': 0.3,
      'size': '2.1 GB',
      'status': 'paused',
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: [
          TextButton(
            onPressed: () {},
            child: const Text('编辑'),
          ),
        ],
      ),
      body: _downloads.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _downloads.length,
              itemBuilder: (context, index) {
                final download = _downloads[index];
                return _buildDownloadItem(download);
              },
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.download_done_rounded,
            size: 80,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            '暂无下载任务',
            style: TextStyle(
              fontSize: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '在视频详情页点击下载按钮开始下载',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadItem(Map<String, dynamic> download) {
    final status = download['status'] as String;
    final progress = download['progress'] as double;

    final colorScheme = Theme.of(context).colorScheme;
    final nova = context.nova;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // Thumbnail placeholder
            Container(
              width: 80,
              height: 60,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Icon(
                  Icons.movie_outlined,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    download['title'] as String,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    download['size'] as String,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Progress bar
                  LinearProgressIndicator(
                    value: progress,
                    backgroundColor:
                        colorScheme.onSurfaceVariant.withValues(alpha: 0.2),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      status == 'completed'
                          ? nova.success
                          : status == 'paused'
                              ? nova.warning
                              : colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    status == 'completed'
                        ? '已完成'
                        : status == 'paused'
                            ? '已暂停'
                            : '${(progress * 100).toInt()}%',
                    style: TextStyle(
                      fontSize: 12,
                      color: status == 'completed'
                          ? nova.success
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),

            // Action button
            IconButton(
              icon: Icon(
                status == 'completed'
                    ? Icons.play_circle_outline
                    : status == 'paused'
                        ? Icons.play_arrow
                        : Icons.pause,
                color: colorScheme.primary,
              ),
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
  }
}
