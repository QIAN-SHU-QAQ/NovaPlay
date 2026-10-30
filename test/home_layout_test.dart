import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nova_play/features/home/home_screen.dart';
import 'package:nova_play/features/home/widgets/category_tabs.dart';
import 'package:nova_play/models/video_model.dart';
import 'package:nova_play/models/history_item.dart';
import 'package:nova_play/providers/history_provider.dart';
import 'package:nova_play/providers/scraper_provider.dart';
import 'package:nova_play/shared/widgets/poster_card.dart';

import 'fakes.dart';

class LibraryScraper extends FakeScraper {
  final homePages = <int>[];
  bool failHome = false;
  bool empty = false;

  List<VideoModel> get videos => List.generate(
    24,
    (i) =>
        VideoModel(id: 'video-$i', title: '作品 $i', year: '2026', genre: '动画'),
  );

  @override
  Future<List<String>> getCategories() async => ['全部', '动画'];

  @override
  Future<List<VideoModel>> getHome({int page = 1}) async {
    homePages.add(page);
    if (failHome) throw StateError('测试数据加载失败');
    return page == 1 && !empty ? videos : [];
  }

  @override
  Future<List<VideoModel>> getByCategory(
    String category, {
    int page = 1,
  }) async => videos;
}

class SeededHistory extends HistoryNotifier {
  SeededHistory(List<HistoryItem> items) {
    state = items;
  }
}

Future<void> pumpHome(
  WidgetTester tester,
  LibraryScraper scraper,
  Size size, {
  List<HistoryItem> history = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(
        path: '/search',
        builder: (_, __) => const Scaffold(body: Text('搜索页面')),
      ),
      GoRoute(
        path: '/detail/:id',
        builder:
            (_, state) =>
                Scaffold(body: Text('详情 ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/player',
        builder: (_, state) {
          final extra = state.extra! as Map<String, dynamic>;
          return Scaffold(
            body: Text('续播 ${extra['videoId']} ${extra['startAt']}'),
          );
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentScraperProvider.overrideWithValue(scraper),
        historyProvider.overrideWith((ref) => SeededHistory(history)),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Empty feed offers retry', (tester) async {
    final scraper = LibraryScraper()..empty = true;
    await pumpHome(tester, scraper, const Size(1120, 720));
    expect(find.text('暂无内容'), findsOneWidget);
    scraper.empty = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('作品 0'), findsOneWidget);
  });

  testWidgets('Compact continuation preserves the saved episode position', (
    tester,
  ) async {
    await pumpHome(
      tester,
      LibraryScraper(),
      const Size(1120, 720),
      history: [
        HistoryItem(
          videoId: 'saved',
          title: '昨日观看',
          episodeIndex: 0,
          position: const Duration(seconds: 125),
          duration: const Duration(minutes: 24),
          watchedAt: DateTime(2026),
          episodes: [
            EpisodeModel(
              id: 'ep',
              title: '第 1 集',
              url: 'https://fake.local/ep',
            ),
          ],
        ),
      ],
    );
    expect(find.text('继续观看'), findsOneWidget);
    expect(find.text('第 1 集'), findsOneWidget);
    expect(
      tester
          .getSize(
            find
                .ancestor(of: find.text('昨日观看'), matching: find.byType(InkWell))
                .first,
          )
          .height,
      lessThanOrEqualTo(100),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('昨日观看'));
    await tester.pumpAndSettle();
    expect(find.text('续播 saved 125'), findsOneWidget);
  });

  for (final size in [
    const Size(616, 600),
    const Size(800, 600),
    const Size(1120, 720),
    const Size(1280, 800),
  ]) {
    testWidgets('One discovery grid fits $size and opens a title', (
      tester,
    ) async {
      await pumpHome(tester, LibraryScraper(), size);
      expect(find.text('发现'), findsOneWidget);
      expect(find.text('热门推荐'), findsNothing);
      expect(find.byType(PosterCard), findsWidgets);
      expect(find.text('作品 0'), findsOneWidget);
      expect(find.text('2026 · 动画'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('作品 0'));
      await tester.pumpAndSettle();
      expect(find.text('详情 video-0'), findsOneWidget);
    });
  }

  testWidgets('Category scroll never paginates the hidden home feed', (
    tester,
  ) async {
    final scraper = LibraryScraper();
    await pumpHome(tester, scraper, const Size(1120, 720));
    await tester.tap(find.text('动画'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(scraper.homePages, [1]);
  });

  testWidgets('Refresh action recovers an error and search opens', (
    tester,
  ) async {
    final scraper = LibraryScraper()..failHome = true;
    await pumpHome(tester, scraper, const Size(1120, 720));
    expect(find.text('加载失败'), findsOneWidget);
    scraper.failHome = false;
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('作品 0'), findsOneWidget);
    await tester.tap(find.text('搜索作品'));
    await tester.pumpAndSettle();
    expect(find.text('搜索页面'), findsOneWidget);
  });

  testWidgets('Category tabs support keyboard activation', (tester) async {
    String? selection;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CategoryTabs(
            categories: const ['全部', '动画'],
            selectedCategory: '全部',
            onCategorySelected: (value) => selection = value,
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selection, '全部');
  });
}
