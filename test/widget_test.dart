import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nova_play/app.dart';
import 'package:nova_play/providers/scraper_provider.dart';

import 'fakes.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // 用 Fake 数据源覆盖，避免冒烟测试依赖真实网络（dio 超时 Timer 会挂起）
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentScraperProvider.overrideWithValue(FakeScraper()),
        ],
        child: const NovaPlayApp(),
      ),
    );
    await tester.pump();

    // 首页标题为「探索」（Rail 骨架下的探索首页）
    expect(find.text('探索'), findsOneWidget);
  });
}
