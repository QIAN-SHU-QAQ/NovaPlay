import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/app.dart';
import 'package:nova_play/providers/scraper_provider.dart';

import 'fakes.dart';

void main() {
  testWidgets('tap settings in rail', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentScraperProvider.overrideWithValue(FakeScraper()),
        ],
        child: const NovaPlayApp(),
      ),
    );
    await tester.pump();

    final settingsItem = find.text('设置');
    expect(settingsItem, findsOneWidget);
    await tester.tap(settingsItem);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final exception = tester.takeException();
    debugPrint('EXCEPTION: $exception');
    // 外观分组内容应出现
    expect(find.text('主题'), findsWidgets);
  });
}
