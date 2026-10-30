import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/models/video_model.dart';
import 'package:nova_play/providers/home_provider.dart';
import 'package:nova_play/providers/scraper_provider.dart';
import 'package:nova_play/providers/settings_provider.dart';
import 'package:nova_play/services/database_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes.dart';

class _PagedScraper extends FakeScraper {
  final pages = <int, List<VideoModel>>{};
  final requestedPages = <int>[];

  @override
  Future<List<VideoModel>> getByCategory(
    String category, {
    int page = 1,
  }) async {
    requestedPages.add(page);
    return pages[page] ?? const [];
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _initDatabase() async {
  SharedPreferences.setMockInitialValues({});
  final db = DatabaseService()..resetForTest();
  await db.init();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('分类流：自动加载第一页，loadMore 追加并按空页停止', () async {
    await _initDatabase();
    final scraper =
        _PagedScraper()
          ..pages[1] = [VideoModel(id: 'a', title: 'A')]
          ..pages[2] = [VideoModel(id: 'b', title: 'B')];

    final container = ProviderContainer(
      overrides: [currentScraperProvider.overrideWithValue(scraper)],
    );
    addTearDown(container.dispose);

    final provider = categoryFeedProvider('国产动漫');
    container.read(provider); // 触发 notifier 构造与首页加载
    await _settle();
    expect(container.read(provider).videos.map((v) => v.id), ['a']);
    expect(scraper.requestedPages, [1]);

    await container.read(provider.notifier).loadMore();
    await _settle();
    expect(container.read(provider).videos.map((v) => v.id), ['a', 'b']);
    expect(scraper.requestedPages, [1, 2]);

    // 第三页为空：hasMore=false，再调用不会再请求
    await container.read(provider.notifier).loadMore();
    await _settle();
    expect(container.read(provider).hasMore, isFalse);
    expect(scraper.requestedPages, [1, 2, 3]);
    await container.read(provider.notifier).loadMore();
    await _settle();
    expect(scraper.requestedPages, [1, 2, 3]);
  });

  test('播放器设置：默认值、倍速归一化与持久化', () async {
    await _initDatabase();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(playerSettingsProvider).autoPlayNext, isTrue);
    expect(container.read(playerSettingsProvider).playbackSpeed, 1.0);

    await container.read(playerSettingsProvider.notifier).setPlaybackSpeed(1.5);
    await container
        .read(playerSettingsProvider.notifier)
        .setAutoPlayNext(false);
    await _settle();

    expect(container.read(playerSettingsProvider).playbackSpeed, 1.5);
    expect(container.read(playerSettingsProvider).autoPlayNext, isFalse);
    expect(normalizePlaybackSpeed(3.0), 1.0);

    // 新容器从磁盘恢复
    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    expect(restarted.read(playerSettingsProvider).playbackSpeed, 1.5);
    expect(restarted.read(playerSettingsProvider).autoPlayNext, isFalse);
  });
}
