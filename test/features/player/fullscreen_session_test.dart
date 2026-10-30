import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/features/player/fullscreen_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');
  final calls = <String>[];
  Completer<void>? gate;
  setUp(() {
    calls.clear();
    gate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method.endsWith('EnterNativeFullscreen')) await gate?.future;
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test('native fullscreen enters and exits with toggle', () async {
    final session = FullscreenSession();
    await session.toggle();
    expect(session.active, true);
    await session.toggle();
    expect(session.active, false);
    expect(calls, [
      'Utils.EnterNativeFullscreen',
      'Utils.ExitNativeFullscreen',
    ]);
    await session.close();
  });
  test(
    'closing during enter restores native window after enter completes',
    () async {
      final session = FullscreenSession();
      gate = Completer<void>();
      final entering = session.toggle();
      await Future<void>.delayed(Duration.zero);
      final closing = session.close();
      gate!.complete();
      await Future.wait([entering, closing]);
      expect(calls, [
        'Utils.EnterNativeFullscreen',
        'Utils.ExitNativeFullscreen',
      ]);
      expect(session.active, false);
    },
  );
}
