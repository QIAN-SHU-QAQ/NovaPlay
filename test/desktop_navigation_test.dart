import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/app.dart';
import 'package:nova_play/providers/scraper_provider.dart';
import 'fakes.dart';

void main() {
  for (final size in [const Size(1120, 720), const Size(1440, 900)]) {
    testWidgets('desktop navigation and search at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [currentScraperProvider.overrideWithValue(FakeScraper())],
          child: const NovaPlayApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('NovaPlay'), findsOneWidget);
      expect(find.text('发现'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(find.text('暂无收藏'), findsOneWidget);
      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      expect(find.text('暂无观看记录'), findsOneWidget);
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();
      expect(find.text('下载功能还在开发'), findsOneWidget);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('主题'), findsWidgets);
      await tester.tap(find.text('发现'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索作品'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
