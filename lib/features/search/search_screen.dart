import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../core/config/theme.dart';
import '../../models/video_model.dart';
import '../../providers/search_provider.dart';
import '../../services/database_service.dart';
import '../../shared/widgets/poster_card.dart';

/// 全屏搜索页（覆盖整个窗口，不走 Rail shell）：
/// 胶囊搜索框 + 筛选 chips + 结果计数 + 海报/列表视图切换。
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final List<String> _searchHistory = [];
  final List<String> _hotSearches = ['鬼灭之刃', '进击的巨人', '咒术回战', '间谍过家家', '电锯人'];

  bool _showAsGrid = true;
  String? _genreFilter;

  @override
  void initState() {
    super.initState();
    _searchHistory.addAll(DatabaseService().getSearchHistory());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _performSearch(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;

    setState(() => _genreFilter = null);
    _searchFocus.unfocus();

    // 添加到搜索历史（本地展示 + 持久化）
    setState(() {
      _searchHistory.remove(trimmed);
      _searchHistory.insert(0, trimmed);
      if (_searchHistory.length > 10) {
        _searchHistory.removeLast();
      }
    });
    DatabaseService().addSearchHistory(trimmed);

    ref.read(searchProvider.notifier).search(trimmed);
  }

  /// 从结果的 genre 字段提取筛选项（去重，保序，最多 10 个）
  List<String> _extractGenres(List<VideoModel> results) {
    final genres = <String>{};
    for (final video in results) {
      final genre = video.genre;
      if (genre == null || genre.isEmpty) continue;
      for (final part in genre.split(RegExp(r'[,，/、|]'))) {
        final g = part.trim();
        if (g.isNotEmpty) genres.add(g);
        if (genres.length >= 10) return genres.toList();
      }
    }
    return genres.toList();
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchProvider);
    final colorScheme = Theme.of(context).colorScheme;

    final genres = _extractGenres(searchState.results);
    if (_genreFilter != null && !genres.contains(_genreFilter)) {
      _genreFilter = null;
    }
    final filtered = _genreFilter == null
        ? searchState.results
        : searchState.results
            .where((v) =>
                v.genre != null &&
                v.genre!.split(RegExp(r'[,，/、|]')).contains(_genreFilter))
            .toList();

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // 顶部：返回 + 胶囊搜索框 + 搜索按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => context.canPop()
                        ? context.pop()
                        : context.go('/'),
                  ),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocus,
                          textInputAction: TextInputAction.search,
                          onSubmitted: _performSearch,
                          decoration: const InputDecoration(
                            hintText: '搜索动漫...',
                            prefixIcon: Icon(Icons.search),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _performSearch(_searchController.text),
                    child: const Text('搜索'),
                  ),
                ],
              ),
            ),

            // 结果工具条：筛选 chips + 计数 + 视图切换
            if (searchState.results.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 40,
                        child: genres.isEmpty
                            ? const SizedBox.shrink()
                            : ListView(
                                scrollDirection: Axis.horizontal,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: FilterChip(
                                      label: const Text('全部'),
                                      selected: _genreFilter == null,
                                      onSelected: (_) =>
                                          setState(() => _genreFilter = null),
                                    ),
                                  ),
                                  for (final genre in genres)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(right: 8),
                                      child: FilterChip(
                                        label: Text(genre),
                                        selected: _genreFilter == genre,
                                        onSelected: (_) => setState(() =>
                                            _genreFilter =
                                                _genreFilter == genre
                                                    ? null
                                                    : genre),
                                      ),
                                    ),
                                ],
                              ),
                      ),
                    ),
                    Text(
                      '共 ${filtered.length} 条',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    IconButton(
                      tooltip: _showAsGrid ? '列表视图' : '海报视图',
                      icon: Icon(
                        _showAsGrid
                            ? Icons.view_list_outlined
                            : Icons.grid_view_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _showAsGrid = !_showAsGrid),
                    ),
                  ],
                ),
              ),
            ],

            Expanded(
              child: searchState.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : searchState.results.isNotEmpty
                      ? (filtered.isEmpty && _genreFilter != null)
                          ? Center(
                              child: Text(
                                '该筛选下暂无结果',
                                style: TextStyle(
                                    color: colorScheme.onSurfaceVariant),
                              ),
                            )
                          : _showAsGrid
                              ? _buildPosterGrid(context, filtered)
                              : _buildResultList(context, filtered)
                      : searchState.error != null
                          ? _buildError(context, searchState.error!)
                          : _buildSearchSuggestions(context),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 结果视图 ----------

  Widget _buildPosterGrid(BuildContext context, List<VideoModel> results) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 168,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.62,
      ),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final video = results[index];
        return PosterCard(
          video: video,
          onTap: () =>
              context.push('/detail/${Uri.encodeComponent(video.id)}'),
        );
      },
    );
  }

  Widget _buildResultList(BuildContext context, List<VideoModel> results) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: results.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final video = results[index];
            final cover = video.cover;
            return Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => context
                    .push('/detail/${Uri.encodeComponent(video.id)}'),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      Container(
                        width: 72,
                        height: 100,
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: cover != null && cover.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: cover.startsWith('http')
                                    ? cover
                                    : 'https://yhdm.me$cover',
                                fit: BoxFit.cover,
                                errorWidget: (context, url, error) => Icon(
                                  Icons.movie_outlined,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              )
                            : Icon(
                                Icons.movie_outlined,
                                color: colorScheme.onSurfaceVariant,
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              video.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if (video.year != null || video.genre != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  [
                                    video.year,
                                    video.genre,
                                  ].whereType<String>().join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            if (video.description != null &&
                                video.description!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  video.description!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.4,
                                    color: colorScheme.onSurfaceVariant
                                        .withValues(alpha: 0.7),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ---------- 建议页 ----------

  Widget _buildSearchSuggestions(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (_searchHistory.isNotEmpty) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '搜索历史',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() => _searchHistory.clear());
                      DatabaseService().clearSearchHistory();
                    },
                    child: Text(
                      '清除',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _searchHistory.map((query) {
                  return InputChip(
                    label: Text(query),
                    onPressed: () {
                      _searchController.text = query;
                      _performSearch(query);
                    },
                    onDeleted: () {
                      setState(() => _searchHistory.remove(query));
                      _persistHistory();
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 28),
            ],
            Text(
              '热门搜索',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _hotSearches.asMap().entries.map((entry) {
                final index = entry.key;
                final query = entry.value;
                return ActionChip(
                  avatar: index < 3
                      ? Icon(
                          Icons.local_fire_department,
                          size: 16,
                          color: index == 0
                              ? colorScheme.error
                              : index == 1
                                  ? context.nova.warning
                                  : colorScheme.primary,
                        )
                      : null,
                  label: Text(query),
                  onPressed: () {
                    _searchController.text = query;
                    _performSearch(query);
                  },
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  /// 单条删除后把剩余历史整体重写回 DB
  void _persistHistory() {
    DatabaseService().clearSearchHistory();
    for (final q in _searchHistory) {
      DatabaseService().addSearchHistory(q);
    }
  }

  // ---------- 错误 ----------

  Widget _buildError(BuildContext context, String error) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            '搜索失败',
            style: TextStyle(
              fontSize: 18,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            error,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => ref.read(searchProvider.notifier).clear(),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
