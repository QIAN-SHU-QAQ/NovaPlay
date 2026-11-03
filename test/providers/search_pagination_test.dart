import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/models/video_model.dart';
import 'package:nova_play/providers/scraper_provider.dart';
import 'package:nova_play/providers/search_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes.dart';

class _PagedSearchScraper extends FakeScraper {
  final pages = <int, List<VideoModel>>{};
  final requestedPages = <int>[];

  @override
  Future<List<VideoModel>> search(String keyword, {int page = 1}) async {
    requestedPages.add(page);
    return pages[page] ?? const [];
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('搜索分页：loadMore 追加结果，空页后停止', () async {
    SharedPreferences.setMockInitialValues({});
    final scraper =
        _PagedSearchScraper()
          ..pages[1] = [VideoModel(id: 's1', title: '结果1')]
          ..pages[2] = [VideoModel(id: 's2', title: '结果2')];

    final container = ProviderContainer(
      overrides: [currentScraperProvider.overrideWithValue(scraper)],
    );
    addTearDown(container.dispose);

    await container.read(searchProvider.notifier).search('测试');
    await _settle();
    expect(container.read(searchProvider).results.map((v) => v.id), ['s1']);
    expect(container.read(searchProvider).hasMore, isTrue);

    await container.read(searchProvider.notifier).loadMore();
    await _settle();
    expect(container.read(searchProvider).results.map((v) => v.id), [
      's1',
      's2',
    ]);
    expect(scraper.requestedPages, [1, 2]);

    await container.read(searchProvider.notifier).loadMore();
    await _settle();
    expect(container.read(searchProvider).hasMore, isFalse);
    expect(scraper.requestedPages, [1, 2, 3]);
  });

  test('新搜索会重置分页状态', () async {
    SharedPreferences.setMockInitialValues({});
    final scraper =
        _PagedSearchScraper()..pages[1] = [VideoModel(id: 's1', title: '结果1')];

    final container = ProviderContainer(
      overrides: [currentScraperProvider.overrideWithValue(scraper)],
    );
    addTearDown(container.dispose);

    await container.read(searchProvider.notifier).search('第一');
    await _settle();
    await container.read(searchProvider.notifier).search('第二');
    await _settle();

    final state = container.read(searchProvider);
    expect(state.results.length, 1);
    expect(state.page, 2);
    expect(scraper.requestedPages.where((p) => p == 1).length, 2);
  });
}
