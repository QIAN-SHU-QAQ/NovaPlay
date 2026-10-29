import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/utils/play_launcher.dart';
import '../../models/video_model.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/history_provider.dart';
import '../../shared/widgets/wide_media_card.dart';

class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(favoritesProvider);
    // 反查观看历史：收藏卡上展示进度并支持一键续播
    final historyMap = {
      for (final item in ref.watch(historyProvider)) item.videoId: item,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('收藏'),
        actions: [
          TextButton(
            onPressed: () {},
            child: Text(
              '${favorites.length} 部',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      body: favorites.isEmpty
          ? _buildEmptyState(context)
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: favorites.length,
                  itemBuilder: (context, index) {
                    final video = favorites[index];
                    final history = historyMap[video.id];
                    return WideMediaCard(
                      title: video.title,
                      coverUrl: video.cover,
                      subtitle: video.genre,
                      meta: video.episodes == null
                          ? null
                          : '共 ${video.episodes!.length} 集',
                      progress: history?.progress,
                      onTap: () => context
                          .push('/detail/${Uri.encodeComponent(video.id)}'),
                      onResume: () {
                        if (history != null) {
                          launchHistoryResume(context, history);
                        } else {
                          context.push(
                              '/detail/${Uri.encodeComponent(video.id)}');
                        }
                      },
                      onLongPress: () => _confirmRemove(context, ref, video),
                    );
                  },
                ),
              ),
            ),
    );
  }

  void _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    VideoModel video,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除收藏'),
        content: Text('确定要移除「${video.title}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              ref.read(favoritesProvider.notifier).toggle(video);
              Navigator.pop(context);
            },
            child: const Text('移除'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.favorite_border_rounded,
            size: 80,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            '暂无收藏',
            style: TextStyle(
              fontSize: 18,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '点击视频详情页的心形按钮添加收藏',
            style: TextStyle(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
