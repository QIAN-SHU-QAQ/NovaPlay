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

    expect(find.text('NovaPlay'), findsOneWidget);
    expect(find.text('发现'), findsWidgets);
  });
}
