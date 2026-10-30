import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:nova_play/features/player/player_screen.dart';
import 'playback_session_test.dart' show FakePlatform;

void main() {
  testWidgets('error retry, episode title and Esc fullscreen restore', (
    tester,
  ) async {
    final previousFontFetching = GoogleFonts.config.allowRuntimeFetching;
    GoogleFonts.config.allowRuntimeFetching = false;
    addTearDown(
      () => GoogleFonts.config.allowRuntimeFetching = previousFontFetching,
    );
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final platform = FakePlatform()..fail = true;
    final calls = <String>[];
    const channel = MethodChannel('com.alexmercerind/media_kit_video');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerFactoryProvider.overrideWithValue(
            () => Player(platformPlayer: platform),
          ),
          playerSurfaceProvider.overrideWithValue(
            (_) => const ColoredBox(color: Colors.black),
          ),
        ],
        child: const MaterialApp(
          home: PlayerScreen(
            videoUrl: 'https://example.test/1.m3u8',
            title: 'Show - One',
            videoTitle: 'Show',
            episodes: [
              {'title': 'One', 'url': 'https://example.test/1.m3u8'},
              {'title': 'Two', 'url': 'https://example.test/2.m3u8'},
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final episodeLabel = find.text('选集 (2)');
    final panel = tester.widget<Container>(
      find.ancestor(of: episodeLabel, matching: find.byType(Container)).first,
    );
    expect(
      panel.color,
      Theme.of(tester.element(episodeLabel)).colorScheme.surfaceContainerLow,
      reason: '播放器控件应使用内部深色主题，即使应用外层是浅色主题',
    );
    expect(find.text('播放失败'), findsOneWidget);
    platform.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('播放失败'), findsNothing);
    await tester.tap(find.byTooltip('倍速'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5x'));
    await tester.pumpAndSettle();
    expect(find.text('1.5x'), findsOneWidget);
    await tester.tap(find.byTooltip('音量'));
    await tester.pumpAndSettle();
    final slider = find.byType(Slider);
    (tester.widget<Slider>(slider)).onChanged!(35);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider).value, 35);
    await tester.tapAt(const Offset(50, 50));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一集'));
    await tester.pumpAndSettle();
    expect(find.text('Show - Two'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    expect(calls, ['Utils.EnterNativeFullscreen']);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(calls, [
      'Utils.EnterNativeFullscreen',
      'Utils.ExitNativeFullscreen',
    ]);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(calls.last, 'Utils.ExitNativeFullscreen');
    expect(tester.takeException(), isNull);
  });
}
