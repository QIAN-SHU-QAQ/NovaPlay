import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart';

import '../../core/utils/play_launcher.dart';
import '../../models/bangumi_info.dart';
import '../../models/video_model.dart';
import '../../providers/bangumi_provider.dart';
import '../../providers/download_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/history_provider.dart';
import '../../providers/scraper_provider.dart';
import '../../providers/video_provider.dart';
import '../../services/bangumi_api.dart';
import '../../services/database_service.dart';
import 'widgets/bangumi_match_dialog.dart';

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
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
        ),
      ),
      body: videoDetail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:
            (error, stack) => Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 28,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '加载失败',
                    style: TextStyle(
                      fontSize: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    error.toString(),
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed:
                        () => ref.invalidate(videoDetailProvider(widget.id)),
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
    final bangumiLookup =
        ref
            .watch(
              bangumiInfoProvider(
                BangumiQuery(videoId: video.id, title: video.title),
              ),
            )
            .valueOrNull;
    final bangumi = bangumiLookup?.info;
    final showDataColumn =
        bangumi != null && (bangumi.score != null || bangumi.staff.isNotEmpty);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1200;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (constraints.maxWidth >= 600) _buildPosterColumn(video),
            Expanded(
              child: _buildInfoColumn(
                video,
                bangumi,
                showInlineData: !wide && showDataColumn,
                showPoster: constraints.maxWidth < 600,
              ),
            ),
            if (wide && showDataColumn)
              _buildDataColumn(bangumi, video.id, video.title),
          ],
        );
      },
    );
  }

  /// Bangumi 资料状态与手动匹配入口。
  ///
  /// 无论自动匹配为空、资料服务不可用还是角色接口部分降级，这里都能显示
  /// 可操作的提示；宽/窄布局共用，避免窄屏只能在数据栏里找到手选入口。
  Widget _buildBangumiStatus(VideoModel video) {
    final query = BangumiQuery(videoId: video.id, title: video.title);
    final async = ref.watch(bangumiInfoProvider(query));
    final lookup = async.valueOrNull;
    final colors = Theme.of(context).colorScheme;

    if (async.isLoading && lookup == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              '正在加载 Bangumi 资料…',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      );
    }

    final unavailable =
        async.hasError ||
        lookup == null ||
        lookup.status == BangumiLookupStatus.unavailable;
    final noMatch = lookup?.status == BangumiLookupStatus.noMatch;
    final partial = lookup?.partial == true;
    final info = lookup?.info;
    // 只有角色资料（没有评分/制作人员）时，宽屏数据栏与窄屏展开区都不会
    // 出现手选入口；这里单独提供，避免用户无法纠正或解除已有映射。
    final incomplete =
        lookup?.status == BangumiLookupStatus.success &&
        !partial &&
        info != null &&
        info.score == null &&
        info.staff.isEmpty;
    if (!unavailable && !noMatch && !partial && !incomplete) {
      return const SizedBox.shrink();
    }

    final title =
        unavailable
            ? 'Bangumi 资料暂不可用'
            : noMatch
            ? '暂无可靠的 Bangumi 匹配'
            : partial
            ? '部分 Bangumi 资料不可用'
            : 'Bangumi 资料不完整';
    final subtitle =
        unavailable
            ? '可重试，或手动选择对应条目'
            : noMatch
            ? '可手动选择对应条目'
            : partial
            ? '评分与制作人员可用，角色资料缺失'
            : '仅有角色资料，可手动选择条目';

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Card(
        margin: EdgeInsets.zero,
        color: colors.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (unavailable)
                TextButton(
                  onPressed: () => ref.invalidate(bangumiInfoProvider(query)),
                  child: const Text('重试'),
                ),
              TextButton.icon(
                onPressed: () => _showBangumiMatchDialog(video.id, video.title),
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('手动匹配'),
              ),
            ],
          ),
        ),
      ),
    );
  }
  // ---------- 海报列 ----------

  Widget _buildPosterColumn(VideoModel video) {
    final colorScheme = Theme.of(context).colorScheme;
    final isFavorite = ref
        .watch(favoritesProvider)
        .any((v) => v.id == video.id);
    final genres = _splitGenres(video.genre);

    return SizedBox(
      width: 220,
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
                  borderRadius: BorderRadius.circular(6),
                  color: colorScheme.surfaceContainerHigh,
                ),
                clipBehavior: Clip.antiAlias,
                child:
                    video.cover != null && video.cover!.isNotEmpty
                        ? CachedNetworkImage(
                          imageUrl:
                              video.cover!.startsWith('http')
                                  ? video.cover!
                                  : 'https://yhdm.me${video.cover}',
                          fit: BoxFit.cover,
                          errorWidget:
                              (context, url, error) =>
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
                onPressed:
                    video.episodes != null && video.episodes!.isNotEmpty
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
                children:
                    genres
                        .map(
                          (g) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              g,
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        )
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
        child: Icon(
          Icons.movie_outlined,
          size: 28,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  // ---------- 信息列 ----------

  Widget _buildInfoColumn(
    VideoModel video,
    BangumiInfo? bangumi, {
    bool showInlineData = false,
    bool showPoster = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    // 历史"当前集"：有记录则描边标记
    final history = ref.watch(historyProvider);
    final watchedIndex =
        history
            .where((h) => h.videoId == video.id)
            .map((h) => h.episodeIndex)
            .firstOrNull;
    final episodes = video.episodes ?? const <EpisodeModel>[];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showPoster) _buildPosterColumn(video),
          // 标题 + meta
          Text(
            video.title,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
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
                Text(
                  ' · ',
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
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

          // Bangumi 资料状态 / 手动匹配入口（窄布局、空匹配、不可用时也可达）
          _buildBangumiStatus(video),

          // 选集
          if (episodes.isNotEmpty) ...[
            Row(
              children: [
                Text(
                  '选集 (${episodes.length})',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (watchedIndex != null &&
                    watchedIndex >= 0 &&
                    watchedIndex < episodes.length) ...[
                  const SizedBox(width: 12),
                  Icon(Icons.history, size: 14, color: colorScheme.primary),
                  const SizedBox(width: 4),
                  Text(
                    '看到第 ${watchedIndex + 1} 集',
                    style: TextStyle(fontSize: 12, color: colorScheme.primary),
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
                    title: episodes[i].title,
                    index: i,
                    isCurrent: i == watchedIndex,
                    onTap: () => _playEpisode(video, i),
                    onDownload: () => _downloadEpisode(video, i),
                  ),
              ],
            ),
          ],

          if (showInlineData && bangumi != null) ...[
            const SizedBox(height: 24),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                bangumi.score == null
                    ? '制作资料'
                    : '评分 ${bangumi.score!.toStringAsFixed(1)} · 制作资料',
              ),
              subtitle:
                  bangumi.scoreCount == null
                      ? null
                      : Text('${bangumi.scoreCount} 人评分'),
              children: [
                for (final entry in bangumi.staff)
                  ListTile(
                    dense: true,
                    title: Text(entry.name),
                    subtitle: Text(entry.role),
                  ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.tune, size: 18),
                  title: const Text('资料不准确？手动匹配'),
                  onTap: () => _showBangumiMatchDialog(video.id, video.title),
                ),
              ],
            ),
          ],
          // 角色行（Bangumi 有数据时）
          if (bangumi != null && bangumi.characters.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text(
              '角色',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 132,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: bangumi.characters.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder:
                    (context, index) =>
                        _CharacterCard(character: bangumi.characters[index]),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------- 数据列 ----------

  Widget _buildDataColumn(BangumiInfo bangumi, String videoId, String title) {
    final colorScheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: 300,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 4, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _showBangumiMatchDialog(videoId, title),
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('资料不准确？手动匹配'),
              ),
            ),
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
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
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
                            style: Theme.of(
                              context,
                            ).textTheme.displaySmall?.copyWith(
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
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
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

  /// R7：手动选择 Bangumi 条目并按完整视频 ID 持久化，避免自动匹配到
  /// 错误作品/季数，也避免同名不同作品共用一份关联。
  Future<void> _showBangumiMatchDialog(String videoId, String title) async {
    final api = ref.read(bangumiApiProvider);
    final existing = DatabaseService().getBangumiMapping(videoId);
    final selected = await showDialog<Object?>(
      context: context,
      builder:
          (_) => BangumiMatchDialog(
            future: api.searchSubjects(title),
            title: title,
            hasExistingMapping: existing != null,
            existingLabel: existing?['name']?.toString(),
          ),
    );
    if (selected == null || !mounted) return;
    if (selected is String && selected == BangumiMatchDialog.clearValue) {
      await DatabaseService().removeBangumiMapping(videoId);
    } else if (selected is BangumiSubjectCandidate) {
      await DatabaseService().setBangumiMapping(videoId, {
        'subjectId': selected.subjectId,
        'name': selected.displayTitle,
        'updatedAt': DateTime.now().toIso8601String(),
      });
    }
    ref.invalidate(
      bangumiInfoProvider(BangumiQuery(videoId: videoId, title: title)),
    );
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
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final scraper = ref.read(currentScraperProvider);
      final playUrls = await scraper.getPlayUrls(episode.url);

      if (mounted) Navigator.pop(context);

      if (playUrls.isNotEmpty) {
        _navigateToPlayer(video, index, playUrls.first);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('暂无可用播放源')));
        }
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取播放地址失败: $e')));
      }
    }
  }

  Future<void> _downloadEpisode(VideoModel video, int index) async {
    final episode = video.episodes![index];
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('正在解析下载地址...')));

    try {
      var url = episode.playUrl;
      if (url == null || url.isEmpty) {
        final scraper = ref.read(currentScraperProvider);
        final playUrls = await scraper.getPlayUrls(episode.url);
        if (playUrls.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('暂无可用播放源，无法下载')));
          return;
        }
        url = playUrls.first;
      }

      await ref
          .read(downloadTasksProvider.notifier)
          .addTask(
            title: '${video.title} - ${episode.title}',
            url: url,
            videoId: video.id,
            cover: video.cover,
          );

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已加入下载队列，可在「下载」页查看')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('添加下载失败: $e')));
    }
  }

  void _toggleFavorite(VideoModel video) {
    ref.read(favoritesProvider.notifier).toggle(video).then((_) {
      if (!mounted) return;
      final isFav = ref.read(favoritesProvider).any((v) => v.id == video.id);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(isFav ? '已加入收藏' : '已取消收藏')));
    });
  }

  void _navigateToPlayer(VideoModel video, int index, String videoUrl) {
    launchPlayer(
      context,
      videoUrl: videoUrl,
      title: '${video.title} - ${video.episodes![index].title}',
      episodes:
          video.episodes!
              .map(
                (e) => {
                  'id': e.id,
                  'title': e.title,
                  'url': e.playUrl ?? e.url,
                  'pageUrl': e.url,
                  'media': e.urlIsMediaPlayback ? 'true' : 'false',
                },
              )
              .toList(),
      currentIndex: index,
      videoId: video.id,
      videoTitle: video.title,
      cover: video.cover,
      sourceId: video.source,
    );
  }
}

// ---------- 私有小部件 ----------

/// 选集按钮，当前观看集描边提示；右上角可单独下载该集。
class _EpisodeThumbCard extends StatelessWidget {
  final String title;
  final int index;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback? onDownload;

  const _EpisodeThumbCard({
    required this.title,
    required this.index,
    required this.isCurrent,
    required this.onTap,
    this.onDownload,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 136,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        OutlinedButton(
          onPressed: onTap,
          style:
              isCurrent
                  ? OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    foregroundColor: Theme.of(context).colorScheme.primary,
                  )
                  : null,
          child: Text(
            title.isEmpty ? '第 ${index + 1} 集' : title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (onDownload != null)
          Positioned(
            top: -6,
            right: -6,
            child: IconButton(
              tooltip: '下载本集',
              iconSize: 16,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              icon: const Icon(Icons.download_outlined),
              onPressed: onDownload,
            ),
          ),
      ],
    ),
  );
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
              borderRadius: BorderRadius.circular(6),
            ),
            clipBehavior: Clip.antiAlias,
            child:
                character.imageUrl != null
                    ? CachedNetworkImage(
                      imageUrl: character.imageUrl!,
                      fit: BoxFit.cover,
                      errorWidget:
                          (context, url, error) => Icon(
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
