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
  final _scrollController = ScrollController();

  static const _gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 180,
    childAspectRatio: 0.57,
    crossAxisSpacing: 16,
    mainAxisSpacing: 24,
  );

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
    if (ref.read(selectedCategoryProvider) != '全部') return;
    if (_scrollController.position.extentAfter < 200) {
      ref.read(videoListProvider.notifier).loadMore();
    }
  }

  Future<void> _refresh() async {
    final category = ref.read(selectedCategoryProvider);
    if (category == '全部') {
      await ref.read(videoListProvider.notifier).refresh();
    } else {
      ref.invalidate(categoryVideosProvider(category));
      await ref
          .read(categoryVideosProvider(category).future)
          .catchError((_) => <VideoModel>[]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedCategory = ref.watch(selectedCategoryProvider);
    final videoState = ref.watch(videoListProvider);
    final history = ref.watch(historyProvider);
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _header(context)),
            if (history.isNotEmpty)
              SliverToBoxAdapter(child: _continueWatching(context, history)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
                child: ref
                    .watch(categoriesProvider)
                    .maybeWhen(
                      data:
                          (categories) => CategoryTabs(
                            categories:
                                categories.isEmpty ? const ['全部'] : categories,
                            selectedCategory: selectedCategory,
                            onCategorySelected: (category) {
                              ref
                                  .read(selectedCategoryProvider.notifier)
                                  .state = category;
                              if (_scrollController.hasClients) {
                                _scrollController.jumpTo(0);
                              }
                            },
                          ),
                      orElse: () => const SizedBox(height: 44),
                    ),
              ),
            ),
            if (selectedCategory == '全部')
              _feed(videoState)
            else
              _category(selectedCategory),
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 26, 28, 16),
      child: LayoutBuilder(
        builder:
            (context, constraints) => Row(
              children: [
                Expanded(
                  child: Text(
                    '发现',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                SizedBox(
                  width: (constraints.maxWidth * 0.45).clamp(140.0, 240.0),
                  height: 38,
                  child: OutlinedButton.icon(
                    onPressed: () => context.push('/search'),
                    icon: const Icon(Icons.search, size: 18),
                    label: const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('搜索作品'),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.onSurfaceVariant,
                      side: BorderSide(color: colors.outlineVariant),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
      ),
    );
  }

  Widget _continueWatching(BuildContext context, List<HistoryItem> history) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 4, 28, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '继续观看',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => context.go('/history'),
                  child: const Text('观看记录'),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 94,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 28),
              itemCount: history.take(12).length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder:
                  (context, index) => _ContinueCard(
                    item: history[index],
                    onTap: () => launchHistoryResume(context, history[index]),
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _feed(VideoListState state) {
    if (state.isLoading && state.videos.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (state.error != null && state.videos.isEmpty) {
      return _message('加载失败', detail: state.error, onRetry: _refresh);
    }
    if (state.videos.isEmpty) return _message('暂无内容', onRetry: _refresh);
    return SliverMainAxisGroup(
      slivers: [
        _grid(state.videos),
        if (state.isLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (state.error != null)
          SliverToBoxAdapter(
            child: Center(
              child: TextButton(
                onPressed:
                    () => ref.read(videoListProvider.notifier).loadMore(),
                child: const Text('加载更多失败，重试'),
              ),
            ),
          ),
      ],
    );
  }

  Widget _category(String category) {
    return ref
        .watch(categoryVideosProvider(category))
        .when(
          loading:
              () => const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              ),
          error: (error, _) => _message('分类加载失败', onRetry: _refresh),
          data:
              (videos) => videos.isEmpty ? _message('该分类暂无内容') : _grid(videos),
        );
  }

  Widget _grid(List<VideoModel> videos) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      sliver: SliverGrid(
        gridDelegate: _gridDelegate,
        delegate: SliverChildBuilderDelegate(
          (context, index) => VideoCard(
            video: videos[index],
            onTap:
                () => context.push(
                  '/detail/${Uri.encodeComponent(videos[index].id)}',
                ),
          ),
          childCount: videos.length,
        ),
      ),
    );
  }

  Widget _message(String title, {String? detail, VoidCallback? onRetry}) {
    final colors = Theme.of(context).colorScheme;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (detail != null) ...[
                const SizedBox(height: 8),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ],
              if (onRetry != null) ...[
                const SizedBox(height: 16),
                OutlinedButton(onPressed: onRetry, child: const Text('重试')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ContinueCard extends StatelessWidget {
  final HistoryItem item;
  final VoidCallback onTap;

  const _ContinueCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cover = item.cover;
    final subtitle =
        item.episodeTitle ?? '已看 ${_formatDuration(item.position)}';
    return SizedBox(
      width: 304,
      child: Material(
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: colors.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          focusColor: colors.primary.withValues(alpha: 0.16),
          child: Row(
            children: [
              SizedBox(
                width: 76,
                height: 94,
                child:
                    cover != null && cover.isNotEmpty
                        ? CachedNetworkImage(
                          imageUrl:
                              cover.startsWith('http')
                                  ? cover
                                  : 'https://yhdm.me$cover',
                          fit: BoxFit.cover,
                          placeholder:
                              (_, __) => ColoredBox(
                                color: colors.surfaceContainerHigh,
                              ),
                          errorWidget:
                              (_, __, ___) => Icon(
                                Icons.movie_outlined,
                                color: colors.onSurfaceVariant,
                              ),
                        )
                        : ColoredBox(
                          color: colors.surfaceContainerHigh,
                          child: Icon(
                            Icons.movie_outlined,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      if (item.progress > 0) ...[
                        const SizedBox(height: 10),
                        LinearProgressIndicator(
                          value: item.progress,
                          minHeight: 2,
                          backgroundColor: colors.outlineVariant,
                          color: colors.primary,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final m = duration.inMinutes;
    final s = duration.inSeconds % 60;
    if (m >= 60) {
      return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
