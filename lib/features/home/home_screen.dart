import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../core/utils/play_launcher.dart';
import '../../models/history_item.dart';
import '../../models/video_model.dart';
import '../../providers/home_provider.dart';
import '../../providers/history_provider.dart';
import '../../providers/video_provider.dart';
import 'widgets/video_card.dart';
import 'widgets/category_tabs.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(videoListProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final videoState = ref.watch(videoListProvider);
    final selectedCategory = ref.watch(selectedCategoryProvider);
    final isFeed = selectedCategory == '全部';

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          if (isFeed) {
            await ref.read(videoListProvider.notifier).refresh();
          } else {
            ref.invalidate(categoryVideosProvider(selectedCategory));
            // RefreshIndicator 需要等待一个 Future，等分类流重建完成
            await ref.read(categoryVideosProvider(selectedCategory).future)
                .catchError((_) => <VideoModel>[]);
          }
        },
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
            // 顶部：探索标题 + 胶囊搜索
            SliverToBoxAdapter(child: _buildHeader(context)),

            // 热门推荐：16:9 横向大卡
            if (isFeed && videoState.videos.isNotEmpty)
              SliverToBoxAdapter(child: _buildHotSection(context, videoState.videos)),

            // 继续观看：历史数据横向卡
            SliverToBoxAdapter(
              child: Consumer(builder: (context, ref, _) {
                final history = ref.watch(historyProvider);
                if (history.isEmpty) return const SizedBox.shrink();
                return _buildContinueWatching(context, history);
              }),
            ),

            // 分类 chips
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
                child: _buildCategoryBar(context, selectedCategory),
              ),
            ),

            // 海报网格（推荐流或分类结果）
            if (isFeed) _buildFeedGrid(context, videoState)
            else _buildCategoryGrid(context, selectedCategory),

            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  // ---------- 顶部 ----------

  Widget _buildHeader(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '探索',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  '发现你的下一部番剧',
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: GestureDetector(
              onTap: () => context.push('/search'),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search,
                        size: 20, color: colorScheme.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Text(
                      '搜索动漫...',
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 热门推荐 ----------

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  Widget _buildHotSection(BuildContext context, List<VideoModel> videos) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle('热门推荐'),
        SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            itemCount: videos.take(12).length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) =>
                _HotCard(video: videos[index]),
          ),
        ),
      ],
    );
  }

  // ---------- 继续观看 ----------

  Widget _buildContinueWatching(BuildContext context, List<HistoryItem> history) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle('继续观看'),
        SizedBox(
          height: 172,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            itemCount: history.take(12).length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = history[index];
              return _ContinueCard(
                item: item,
                onTap: () => launchHistoryResume(context, item),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------- 分类 ----------

  Widget _buildCategoryBar(BuildContext context, String selected) {
    final categories = ref.watch(categoriesProvider);
    return categories.maybeWhen(
      data: (list) => CategoryTabs(
        categories: list.isEmpty ? const ['全部'] : list,
        selectedCategory: selected,
        onCategorySelected: (category) => ref
            .read(selectedCategoryProvider.notifier)
            .state = category,
      ),
      orElse: () => const SizedBox(height: 40),
    );
  }

  // ---------- 网格 ----------

  Widget _buildFeedGrid(BuildContext context, VideoListState videoState) {
    final colorScheme = Theme.of(context).colorScheme;

    if (videoState.isLoading && videoState.videos.isEmpty) {
      return const SliverFillRemaining(
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (videoState.error != null && videoState.videos.isEmpty) {
      return SliverFillRemaining(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline,
                  size: 64, color: colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                '加载失败',
                style: TextStyle(
                  fontSize: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                videoState.error!,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () =>
                    ref.read(videoListProvider.notifier).refresh(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 172,
          childAspectRatio: 0.68,
          crossAxisSpacing: 12,
          mainAxisSpacing: 16,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            if (index == videoState.videos.length) {
              if (videoState.isLoading) {
                return const Center(child: CircularProgressIndicator());
              }
              return null;
            }
            final video = videoState.videos[index];
            return VideoCard(
              video: video,
              onTap: () =>
                  context.push('/detail/${Uri.encodeComponent(video.id)}'),
            );
          },
          childCount: videoState.videos.length + (videoState.hasMore ? 1 : 0),
        ),
      ),
    );
  }

  Widget _buildCategoryGrid(BuildContext context, String category) {
    final async = ref.watch(categoryVideosProvider(category));

    return async.when(
      loading: () => const SliverFillRemaining(
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                '分类加载失败',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () =>
                    ref.invalidate(categoryVideosProvider(category)),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
      data: (videos) {
        if (videos.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Center(
                child: Text(
                  '该分类暂无内容',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          );
        }
        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 172,
              childAspectRatio: 0.68,
              crossAxisSpacing: 12,
              mainAxisSpacing: 16,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final video = videos[index];
                return VideoCard(
                  video: video,
                  onTap: () =>
                      context.push('/detail/${Uri.encodeComponent(video.id)}'),
                );
              },
              childCount: videos.length,
            ),
          ),
        );
      },
    );
  }
}

// ---------- 私有小部件 ----------



/// 热门推荐 16:9 横向大卡
class _HotCard extends StatelessWidget {
  final VideoModel video;

  const _HotCard({required this.video});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final cover = video.cover;
    final fullCover =
        cover == null || cover.isEmpty ? null : (cover.startsWith('http') ? cover : 'https://yhdm.me$cover');

    return GestureDetector(
      onTap: () => context.push('/detail/${Uri.encodeComponent(video.id)}'),
      child: Container(
        width: 300,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: colorScheme.surfaceContainerHigh,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (fullCover != null)
              CachedNetworkImage(
                imageUrl: fullCover,
                fit: BoxFit.cover,
                placeholder: (context, url) => Container(
                  color: colorScheme.surfaceContainerHighest,
                ),
                errorWidget: (context, url, error) => Container(
                  color: colorScheme.surfaceContainerHighest,
                  child: Icon(Icons.movie_outlined,
                      color: colorScheme.onSurfaceVariant),
                ),
              )
            else
              Container(
                color: colorScheme.surfaceContainerHighest,
                child: Icon(Icons.movie_outlined,
                    color: colorScheme.onSurfaceVariant),
              ),
            // 底部渐变信息
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.transparent, Colors.black87],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      video.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [video.year, video.genre].whereType<String>().join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 评分徽章
            if (video.rating != null)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '★ ${video.rating!.toStringAsFixed(1)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 继续观看横向卡
class _ContinueCard extends StatelessWidget {
  final HistoryItem item;
  final VoidCallback onTap;

  const _ContinueCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final subtitle = item.episodeTitle ?? '已看 ${_formatDuration(item.position)}';

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 260,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: colorScheme.surfaceContainerHigh,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (item.cover != null && item.cover!.isNotEmpty)
              CachedNetworkImage(
                imageUrl: item.cover!,
                fit: BoxFit.cover,
                placeholder: (context, url) => Container(
                  color: colorScheme.surfaceContainerHighest,
                ),
                errorWidget: (context, url, error) => Container(
                  color: colorScheme.surfaceContainerHighest,
                ),
              )
            else
              Container(color: colorScheme.surfaceContainerHighest),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding:
                    const EdgeInsets.fromLTRB(12, 28, 12, 10),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.transparent, Colors.black87],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 中央播放按钮
            Center(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white70, width: 1.5),
                ),
                child: const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 26),
              ),
            ),
            // 进度条
            if (item.progress > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: item.progress,
                  backgroundColor: Colors.black38,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(colorScheme.primary),
                  minHeight: 3,
                ),
              ),
          ],
        ),
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
}
