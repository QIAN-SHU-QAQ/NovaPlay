import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/features/search/search_screen.dart';
import 'package:nova_play/models/video_model.dart';
import 'package:nova_play/providers/search_provider.dart';

import '../fakes.dart';

class ControlledScraper extends FakeScraper {
  final requests = <String, Completer<List<VideoModel>>>{};
  final queries = <String>[];

  @override
  Future<List<VideoModel>> search(String keyword, {int page = 1}) {
    queries.add(keyword);
    return (requests[keyword] = Completer<List<VideoModel>>()).future;
  }
}

void main() {
  test('latest search wins when an older response arrives last', () async {
    final scraper = ControlledScraper();
    final notifier = SearchNotifier(scraper);
    addTearDown(notifier.dispose);
    final old = notifier.search('old');
    final latest = notifier.search('latest');
    scraper.requests['latest']!.complete([
      VideoModel(id: '2', title: 'latest'),
    ]);
    await latest;
    scraper.requests['old']!.complete([VideoModel(id: '1', title: 'old')]);
    await old;
    expect(notifier.state.results.single.title, 'latest');
    expect(notifier.state.keyword, 'latest');
  });

  test('an older failure cannot replace a successful newer search', () async {
    final scraper = ControlledScraper();
    final notifier = SearchNotifier(scraper);
    addTearDown(notifier.dispose);
    final old = notifier.search('old');
    final latest = notifier.search('latest');
    scraper.requests['latest']!.complete([
      VideoModel(id: '2', title: 'latest'),
    ]);
    await latest;
    scraper.requests['old']!.completeError(Exception('old request failed'));
    await old;
    expect(notifier.state.error, isNull);
    expect(notifier.state.results.single.title, 'latest');
  });

  test('clear invalidates pending search responses', () async {
    final scraper = ControlledScraper();
    final notifier = SearchNotifier(scraper);
    addTearDown(notifier.dispose);
    final pending = notifier.search('old');
    notifier.clear();
    scraper.requests['old']!.complete([VideoModel(id: '1', title: 'old')]);
    await pending;
    expect(notifier.state.keyword, isEmpty);
    expect(notifier.state.results, isEmpty);
    expect(notifier.state.isLoading, false);
  });

  test('disposing a notifier safely ignores an in-flight completion', () async {
    final scraper = ControlledScraper();
    final notifier = SearchNotifier(scraper);
    final pending = notifier.search('old');
    notifier.dispose();
    scraper.requests['old']!.complete([VideoModel(id: '1', title: 'old')]);
    await expectLater(pending, completes);
  });

  test('new search trims the query and clears stale results', () async {
    final scraper = ControlledScraper();
    final notifier = SearchNotifier(scraper);
    addTearDown(notifier.dispose);
    final old = notifier.search('old');
    scraper.requests['old']!.complete([VideoModel(id: '1', title: 'old')]);
    await old;
    final latest = notifier.search('  latest  ');
    expect(scraper.queries.last, 'latest');
    expect(notifier.state.keyword, 'latest');
    expect(notifier.state.results, isEmpty);
    expect(notifier.state.isLoading, true);
    scraper.requests['latest']!.complete([]);
    await latest;
    expect(notifier.state.keyword, 'latest');
    expect(notifier.state.isLoading, false);
  });

  Future<void> showSearch(WidgetTester tester, SearchNotifier notifier) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [searchProvider.overrideWith((ref) => notifier)],
        child: const MaterialApp(home: SearchScreen()),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'empty successful search displays no-results instead of suggestions',
    (tester) async {
      final scraper = ControlledScraper();
      final notifier = SearchNotifier(scraper);
      await showSearch(tester, notifier);
      expect(find.text('热门搜索'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.tap(find.widgetWithText(TextButton, '搜索'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      scraper.requests['missing']!.complete([]);
      await tester.pump();
      expect(find.text('未找到相关动漫'), findsOneWidget);
      expect(find.text('热门搜索'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retry resubmits the failed keyword', (tester) async {
    final scraper = ControlledScraper();
    final notifier = SearchNotifier(scraper);
    await showSearch(tester, notifier);
    await tester.enterText(find.byType(TextField), 'failed');
    await tester.tap(find.widgetWithText(TextButton, '搜索'));
    await tester.pump();
    scraper.requests['failed']!.completeError(Exception('network unavailable'));
    await tester.pump();
    expect(find.text('搜索失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(scraper.queries, ['failed', 'failed']);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    scraper.requests['failed']!.complete([]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
