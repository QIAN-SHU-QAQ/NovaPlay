import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart';

import '../../core/utils/play_launcher.dart';
import '../../models/bangumi_info.dart';
import '../../models/video_model.dart';
import '../../providers/bangumi_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/history_provider.dart';
import '../../providers/scraper_provider.dart';
import '../../providers/video_provider.dart';

class DetailScreen extends ConsumerStatefulWidget {
  final String id;

  const DetailScreen({super.key, required this.id});

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  @override
  Widget build(BuildContext context) {
    final videoDetail = ref.watch(videoDetailProvider(widget.id));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/'),
        ),
      ),
      body: videoDetail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline,
                  size: 64, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text('加载失败',
                  style: TextStyle(
                      fontSize: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              Text(error.toString(),
                  style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurfaceVariant
                          .withValues(alpha: 0.7))),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () =>
                    ref.invalidate(videoDetailProvider(widget.id)),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (video) => _buildThreeColumns(video),
      ),
    );
  }

  // ---------- 三栏布局 ----------

  Widget _buildThreeColumns(VideoModel video) {
    final bangumi = ref.watch(bangumiInfoProvider(video.title)).valueOrNull;
    final showDataColumn =
        bangumi != null && (bangumi.score != null || bangumi.staff.isNotEmpty);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPosterColumn(video),
        Expanded(child: _buildInfoColumn(video, bangumi)),
        // 数据列：Bangumi 有数据才出现（静默降级双栏）
        if (showDataColumn) _buildDataColumn(bangumi),
      ],
    );
  }

  // ---------- 海报列 ----------

  Widget _buildPosterColumn(VideoModel video) {
    final colorScheme = Theme.of(context).colorScheme;
    final isFavorite =
        ref.watch(favoritesProvider).any((v) => v.id == video.id);
    final genres = _splitGenres(video.genre);

    return SizedBox(
      width: 280,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 海报
            AspectRatio(
              aspectRatio: 2 / 3,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: colorScheme.surfaceContainerHigh,
                  boxShadow: [
                    BoxShadow(
                      color: colorScheme.shadow.withValues(alpha: 0.15),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: video.cover != null && video.cover!.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: video.cover!.startsWith('http')
                            ? video.cover!
                            : 'https://yhdm.me${video.cover}',
                        fit: BoxFit.cover,
                        errorWidget: (context, url, error) =>
                            _coverPlaceholder(colorScheme),
                      )
                    : _coverPlaceholder(colorScheme),
              ),
            ),
            const SizedBox(height: 20),

            // 整宽立即播放
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('立即播放'),
                onPressed: video.episodes != null && video.episodes!.isNotEmpty
                    ? () => _playEpisode(video, 0)
                    : null,
              ),
            ),
            const SizedBox(height: 10),

            // 整宽收藏
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: Icon(
                  isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: isFavorite ? colorScheme.error : null,
                ),
                label: Text(isFavorite ? '已收藏' : '收藏'),
                onPressed: () => _toggleFavorite(video),
              ),
            ),

            // 标签 chips
            if (genres.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: genres
                    .map((g) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            g,
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.movie_outlined,
            size: 64, color: colorScheme.onSurfaceVariant),
      ),
    );
  }

  // ---------- 信息列 ----------

  Widget _buildInfoColumn(VideoModel video, BangumiInfo? bangumi) {
    final colorScheme = Theme.of(context).colorScheme;
    // 历史"当前集"：有记录则描边标记
    final history = ref.watch(historyProvider);
    final watchedIndex = history
        .where((h) => h.videoId == video.id)
        .map((h) => h.episodeIndex)
        .firstOrNull;
    final episodes = video.episodes ?? const <EpisodeModel>[];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 4, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题 + meta
          Text(
            video.title,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (video.year != null)
                Text(
                  video.year!,
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              if (video.year != null && video.genre != null)
                Text(' · ', style: TextStyle(color: colorScheme.onSurfaceVariant)),
              if (video.genre != null)
                Expanded(
                  child: Text(
                    video.genre!,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // 简介
          if (video.description != null && video.description!.isNotEmpty)
            Text(
              video.description!,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
          const SizedBox(height: 24),

          // 选集缩略图卡
          if (episodes.isNotEmpty) ...[
            Row(
              children: [
                Text(
                  '选集 (${episodes.length})',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                if (watchedIndex != null &&
                    watchedIndex >= 0 &&
                    watchedIndex < episodes.length) ...[
                  const SizedBox(width: 12),
                  Icon(Icons.history, size: 14, color: colorScheme.primary),
                  const SizedBox(width: 4),
                  Text(
                    '看到第 ${watchedIndex + 1} 集',
                    style: TextStyle(
                        fontSize: 12, color: colorScheme.primary),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (var i = 0; i < episodes.length; i++)
                  _EpisodeThumbCard(
                    coverUrl: video.cover,
                    index: i,
                    isCurrent: i == watchedIndex,
                    onTap: () => _playEpisode(video, i),
                  ),
              ],
            ),
          ],

          // 角色行（Bangumi 有数据时）
          if (bangumi != null && bangumi.characters.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text(
              '角色',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 132,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: bangumi.characters.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) =>
                    _CharacterCard(character: bangumi.characters[index]),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------- 数据列 ----------

  Widget _buildDataColumn(BangumiInfo bangumi) {
    final colorScheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: 300,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 4, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 评分卡
            if (bangumi.score != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '评分',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            bangumi.score!.toStringAsFixed(1),
                            style: Theme.of(context)
                                .textTheme
                                .displaySmall
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.primary,
                                ),
                          ),
                          const SizedBox(width: 4),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              '/ 10',
                              style: TextStyle(
                                fontSize: 13,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const Spacer(),
                          if (bangumi.scoreCount != null)
                            Text(
                              '${bangumi.scoreCount} 人评分',
                              style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],

            // 制作人员卡
            if (bangumi.staff.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '制作人员',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 12),
                      for (final entry in bangumi.staff)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 76,
                                child: Text(
                                  entry.role,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colorScheme.onSurfaceVariant
                                        .withValues(alpha: 0.7),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  entry.name,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---------- 私有辅助 ----------

  List<String> _splitGenres(String? genre) {
    if (genre == null || genre.isEmpty) return const [];
    return genre
        .split(RegExp(r'[,，/、|]'))
        .map((g) => g.trim())
        .where((g) => g.isNotEmpty)
        .take(6)
        .toList();
  }

  void _playEpisode(VideoModel video, int index) async {
    final episode = video.episodes![index];

    // 如果有直接播放地址，直接播放
    if (episode.playUrl != null && episode.playUrl!.isNotEmpty) {
      _navigateToPlayer(video, index, episode.playUrl!);
      return;
    }

    // 否则显示加载中，获取播放地址
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(),
      ),
    );

    try {
      final scraper = ref.read(currentScraperProvider);
      final playUrls = await scraper.getPlayUrls(episode.url);

      if (mounted) Navigator.pop(context);

      if (playUrls.isNotEmpty) {
        _navigateToPlayer(video, index, playUrls.first);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('暂无可用播放源')),
          );
        }
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取播放地址失败: $e')),
        );
      }
    }
  }

  void _toggleFavorite(VideoModel video) {
    ref.read(favoritesProvider.notifier).toggle(video).then((_) {
      if (!mounted) return;
      final isFav =
          ref.read(favoritesProvider).any((v) => v.id == video.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isFav ? '已加入收藏' : '已取消收藏')),
      );
    });
  }

  void _navigateToPlayer(VideoModel video, int index, String videoUrl) {
    launchPlayer(
      context,
      videoUrl: videoUrl,
      title: '${video.title} - ${video.episodes![index].title}',
      episodes: video.episodes!
          .map((e) => {'title': e.title, 'url': e.playUrl ?? e.url})
          .toList(),
      currentIndex: index,
      videoId: video.id,
      videoTitle: video.title,
      cover: video.cover,
    );
  }
}

// ---------- 私有小部件 ----------

/// 选集缩略图卡：番剧封面做缩略 + 集数角标，当前集主色描边
class _EpisodeThumbCard extends StatelessWidget {
  final String? coverUrl;
  final int index;
  final bool isCurrent;
  final VoidCallback onTap;

  const _EpisodeThumbCard({
    required this.coverUrl,
    required this.index,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 148,
        height: 92,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isCurrent ? colorScheme.primary : colorScheme.outlineVariant,
            width: isCurrent ? 2 : 1,
          ),
          color: colorScheme.surfaceContainerHigh,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (coverUrl != null && coverUrl!.isNotEmpty)
              CachedNetworkImage(
                imageUrl: coverUrl!.startsWith('http')
                    ? coverUrl!
                    : 'https://yhdm.me$coverUrl',
                fit: BoxFit.cover,
                errorWidget: (context, url, error) => Center(
                  child: Icon(Icons.movie_outlined,
                      color: colorScheme.onSurfaceVariant),
                ),
              )
            else
              Center(
                child: Icon(Icons.movie_outlined,
                    color: colorScheme.onSurfaceVariant),
              ),
            // 集数角标
            Positioned(
              left: 0,
              bottom: 0,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isCurrent
                      ? colorScheme.primary
                      : Colors.black54,
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(10),
                  ),
                ),
                child: Text(
                  '第 ${index + 1} 集',
                  style: TextStyle(
                    color: isCurrent
                        ? colorScheme.onPrimary
                        : Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (isCurrent)
              Center(
                child: Icon(
                  Icons.play_circle_fill_rounded,
                  color: Colors.white.withValues(alpha: 0.9),
                  size: 30,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 角色卡：头像 + 角色名 + CV
class _CharacterCard extends StatelessWidget {
  final BangumiCharacter character;

  const _CharacterCard({required this.character});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: 84,
      child: Column(
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: character.imageUrl != null
                ? CachedNetworkImage(
                    imageUrl: character.imageUrl!,
                    fit: BoxFit.cover,
                    errorWidget: (context, url, error) => Icon(
                      Icons.person_outline,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  )
                : Icon(
                    Icons.person_outline,
                    color: colorScheme.onSurfaceVariant,
                  ),
          ),
          const SizedBox(height: 6),
          Text(
            character.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          if (character.cv != null)
            Text(
              character.cv!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
