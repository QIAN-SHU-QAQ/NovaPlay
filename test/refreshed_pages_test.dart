import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/features/detail/detail_screen.dart';
import 'package:nova_play/features/download/download_screen.dart';
import 'package:nova_play/features/favorites/favorites_screen.dart';
import 'package:nova_play/features/settings/settings_screen.dart';
import 'package:nova_play/features/search/search_screen.dart';
import 'package:nova_play/models/bangumi_info.dart';
import 'package:nova_play/models/video_model.dart';
import 'package:nova_play/providers/bangumi_provider.dart';
import 'package:nova_play/providers/favorites_provider.dart';
import 'package:nova_play/providers/theme_provider.dart';
import 'package:nova_play/providers/video_provider.dart';
import 'package:nova_play/providers/scraper_provider.dart';
import 'package:nova_play/shared/widgets/wide_media_card.dart';

import 'fakes.dart';

class _GenreScraper extends FakeScraper {
  @override
  Future<List<VideoModel>> search(String keyword, {int page = 1}) async => [
    VideoModel(id: 'one', title: '科幻片', genre: ' 动画 / 科幻 '),
    VideoModel(id: 'two', title: '剧情片', genre: '剧情'),
  ];
}

void main() {
  testWidgets('search filters normalize genre spaces and retain list toggle', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [currentScraperProvider.overrideWithValue(_GenreScraper())],
        child: const MaterialApp(home: SearchScreen()),
      ),
    );
    await tester.enterText(find.byType(TextField), '测试');
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    expect(find.text('剧情片'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, '科幻'));
    await tester.pumpAndSettle();
    expect(find.text('科幻片'), findsOneWidget);
    expect(find.text('剧情片'), findsNothing);
    await tester.tap(find.byTooltip('列表视图'));
    await tester.pumpAndSettle();
    expect(find.text('科幻片'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('theme choices work and unfinished settings are disabled', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    for (final option in [
      ('深色', ThemeMode.dark),
      ('浅色', ThemeMode.light),
      ('跟随系统', ThemeMode.system),
    ]) {
      await tester.tap(find.text(option.$1));
      await tester.pump();
      expect(container.read(themeModeProvider), option.$2);
    }
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text('自动播放下一集'), matching: find.byType(ListTile)),
    );
    expect(tile.enabled, isFalse);
    expect(tile.onTap, isNull);
    expect(find.text('尚未开放'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('favorite remove button confirms before removing', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final video = VideoModel(id: 'favorite', title: '收藏测试');
    await container.read(favoritesProvider.notifier).toggle(video);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: FavoritesScreen()),
      ),
    );
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    expect(find.text('移除收藏'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(container.read(favoritesProvider), hasLength(1));
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(container.read(favoritesProvider), isEmpty);
    expect(find.text('暂无收藏'), findsOneWidget);
  });

  testWidgets('download page explains availability without simulated tasks', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: DownloadScreen()));
    expect(find.text('下载功能还在开发'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('编辑'), findsNothing);
  });

  testWidgets('library row remains usable with long text at narrow width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var resumed = false;
    var removed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WideMediaCard(
            title: '很长的片名' * 20,
            subtitle: '很长的集名' * 20,
            meta: '刚刚观看',
            progress: 0.5,
            onResume: () => resumed = true,
            onRemove: () => removed = true,
          ),
        ),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.byTooltip('继续观看'));
    await tester.tap(find.byTooltip('删除'));
    expect(resumed, isTrue);
    expect(removed, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final width in [420.0, 960.0, 1440.0]) {
    testWidgets('detail retains episodes and metadata at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final video = VideoModel(
        id: 'detail',
        title: '详情测试',
        description: '简介',
        episodes: [EpisodeModel(id: 'ep', title: '第一集 起点', url: 'episode')],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            videoDetailProvider('detail').overrideWith((ref) async => video),
            bangumiInfoProvider(video.title).overrideWith(
              (ref) async => const BangumiInfo(
                score: 8.2,
                staff: [BangumiStaffEntry(role: '导演', name: '制作测试')],
              ),
            ),
          ],
          child: const MaterialApp(home: DetailScreen(id: 'detail')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第一集 起点'), findsOneWidget);
      if (width < 1200) {
        await tester.ensureVisible(find.byType(ExpansionTile));
        await tester.tap(find.byType(ExpansionTile));
        await tester.pumpAndSettle();
      }
      expect(find.text('制作测试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
