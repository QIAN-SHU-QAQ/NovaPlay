import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:nova_play/features/player/playback_session.dart';

class FakePlatform extends PlatformPlayer {
  FakePlatform() : super(configuration: const PlayerConfiguration());
  final opened = <String>[];
  final starts = <Duration?>[];
  final seeks = <Duration>[];
  Completer<void>? gate;
  bool fail = false;
  bool disposed = false;
  Duration mediaDuration = const Duration(minutes: 10);
  final disposal = Completer<void>();
  void emitBuffering(bool value) => bufferingController.add(value);
  void emitError(String message) => errorController.add(message);
  void emitPosition(Duration value) {
    state = state.copyWith(position: value);
    positionController.add(value);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final media = playable as Media;
    opened.add(media.uri);
    starts.add(media.start);
    await gate?.future;
    if (fail) throw StateError('offline');
    state = state.copyWith(position: Duration.zero, duration: mediaDuration);
  }

  @override
  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume);
    volumeController.add(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    state = state.copyWith(rate: rate);
    rateController.add(rate);
  }

  @override
  Future<void> seek(Duration duration) async => seeks.add(duration);
  @override
  Future<void> dispose() async {
    disposed = true;
    if (!disposal.isCompleted) disposal.complete();
    await super.dispose();
  }
}

Future<void> pumpEventQueue() => Future<void>.delayed(Duration.zero);

void main() {
  late FakePlatform platform;
  late PlaybackSession session;
  setUp(() {
    platform = FakePlatform();
    session = PlaybackSession(
      player: Player(platformPlayer: platform),
      initialUrl: 'https://example.test/1.m3u8',
      initialTitle: 'Show - One',
      videoTitle: 'Show',
      episodes: const [
        {'title': 'One', 'url': 'https://example.test/1.m3u8'},
        {'title': 'Two', 'url': 'https://example.test/2.m3u8'},
      ],
      startAt: 60,
    );
  });
  tearDown(() async => session.close());

  test('续播起点在加载时传入，确认前保持 pending 且不改写历史进度', () async {
    await session.open();
    expect(session.ready, true);
    expect(platform.opened.single, 'https://example.test/1.m3u8');
    expect(platform.starts.single, const Duration(seconds: 60));
    expect(platform.seeks, isEmpty, reason: '不允许 open 后立即 seek');
    expect(session.resumePending, true);
    expect(session.confirmedPosition, const Duration(seconds: 60));

    // 媒体未可定位时先发出的 0/5 秒位置不能覆盖 60 秒进度。
    platform.emitPosition(Duration.zero);
    platform.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(session.resumePending, true);
    expect(session.confirmedPosition, const Duration(seconds: 60));

    // 抵达目标（在容差窗口内）后才确认。
    platform.emitPosition(const Duration(seconds: 60));
    await pumpEventQueue();
    expect(session.resumePending, false);
    expect(session.confirmedPosition, const Duration(seconds: 60));
  });

  test('180 秒续播：确认前保持待完成，确认后历史门禁解除', () async {
    await session.close();
    platform = FakePlatform();
    session = PlaybackSession(
      player: Player(platformPlayer: platform),
      initialUrl: 'https://example.test/1.m3u8',
      initialTitle: 'Show - One',
      startAt: 180,
    );
    await session.open();
    expect(session.resumePending, true);
    platform.emitPosition(Duration.zero);
    platform.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(session.resumePending, true, reason: '5 秒不能确认 180 秒续播');
    expect(session.confirmedPosition, const Duration(seconds: 180));

    platform.emitPosition(const Duration(seconds: 181));
    await pumpEventQueue();
    expect(session.resumePending, false);
    expect(session.confirmedPosition, const Duration(seconds: 181));
    expect(platform.starts.single, const Duration(seconds: 180));
  });

  test('时长未知时要求连续两次落在目标窗口内的位置事件', () async {
    await session.close();
    platform = FakePlatform()..mediaDuration = Duration.zero;
    session = PlaybackSession(
      player: Player(platformPlayer: platform),
      initialUrl: 'https://example.test/1.m3u8',
      initialTitle: 'Show - One',
      startAt: 120,
    );
    await session.open();
    expect(session.resumePending, true);
    platform.emitPosition(const Duration(seconds: 120));
    await pumpEventQueue();
    expect(session.resumePending, true, reason: '单次事件不足以确认');
    platform.emitPosition(const Duration(seconds: 121));
    await pumpEventQueue();
    expect(session.resumePending, false);
    expect(session.confirmedPosition, const Duration(seconds: 121));
  });

  test('switch preserves volume and rate and updates title', () async {
    await session.open();
    await session.player.setVolume(35);
    await session.player.setRate(1.5);
    await session.switchEpisode(1);
    expect(platform.state.volume, 35);
    expect(platform.state.rate, 1.5);
    expect(session.title, 'Show - Two');
    expect(platform.starts, [const Duration(seconds: 60), null]);
    expect(platform.seeks, isEmpty);
  });

  test('failed initial open can retry and still use resume position', () async {
    platform.fail = true;
    await session.open();
    expect(session.error, isNotNull);
    expect(session.loading, false);
    platform.fail = false;
    await session.open();
    expect(session.error, isNull);
    expect(session.ready, true);
    expect(platform.starts, [
      const Duration(seconds: 60),
      const Duration(seconds: 60),
    ]);
    expect(platform.seeks, isEmpty);
  });

  test('native error and buffering events update observable state', () async {
    await session.open();
    platform.emitBuffering(true);
    await pumpEventQueue();
    expect(session.buffering, true);
    platform.emitError('HTTP 403');
    await pumpEventQueue();
    expect(session.error, contains('HTTP 403'));
    expect(session.ready, false);
  });

  test('确认前失败：重试仍从原始续播点开始', () async {
    await session.open();
    platform.emitPosition(Duration.zero);
    platform.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    platform.emitError('HTTP 403');
    await pumpEventQueue();
    expect(session.resumePending, false);
    expect(session.confirmedPosition, const Duration(seconds: 60));

    await session.open();
    expect(platform.starts, [
      const Duration(seconds: 60),
      const Duration(seconds: 60),
    ]);
    expect(session.resumePending, true);
  });

  test('确认后失败：重试使用最后一次已确认进度', () async {
    await session.close();
    platform = FakePlatform();
    session = PlaybackSession(
      player: Player(platformPlayer: platform),
      initialUrl: 'https://example.test/1.m3u8',
      initialTitle: 'Show - One',
      startAt: 180,
    );
    await session.open();
    platform.emitPosition(const Duration(seconds: 181));
    await pumpEventQueue();
    expect(session.resumePending, false);
    // 失败解复用器可能在 error 前把位置重置为 0。
    platform.emitPosition(Duration.zero);
    platform.emitError('connection reset');
    await pumpEventQueue();
    await session.open();
    expect(platform.starts.last, const Duration(seconds: 181));
  });

  test('快速切集：旧请求不完成新请求，新集从自身起点开始', () async {
    platform.gate = Completer<void>();
    final first = session.open();
    await pumpEventQueue();
    final old = session.switchEpisode(0);
    final latest = session.switchEpisode(1);
    platform.gate!.complete();
    await Future.wait([first, old, latest]);
    expect(platform.opened.length, 2);
    expect(platform.opened.last, endsWith('/2.m3u8'));
    expect(session.index, 1);
    expect(platform.starts.first, const Duration(seconds: 60));
    expect(platform.starts.last, isNull);
    expect(session.resumePending, false);
    expect(platform.seeks, isEmpty);
  });

  test('用户主动跳转结束待确认并允许保存新位置', () async {
    await session.open();
    platform.emitPosition(Duration.zero);
    platform.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(session.resumePending, true);

    session.noteUserSeek(const Duration(seconds: 30));
    expect(session.resumePending, false);
    expect(session.confirmedPosition, const Duration(seconds: 30));

    platform.emitError('later failure');
    await pumpEventQueue();
    await session.open();
    expect(platform.starts.last, const Duration(seconds: 30));
  });

  test('从头播放把 0 秒视为明确意图，允许历史写入', () async {
    await session.open();
    platform.emitPosition(Duration.zero);
    platform.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(session.resumePending, true);
    session.startFromBeginning();
    expect(session.resumePending, false);
    expect(session.confirmedPosition, Duration.zero);
  });

  test(
    'close while opening suppresses callbacks and disposes after open',
    () async {
      platform.gate = Completer<void>();
      final opening = session.open();
      await pumpEventQueue();
      final closing = session.close();
      platform.gate!.complete();
      await Future.wait([opening, closing]);
      expect(platform.disposed, true);
      expect(platform.seeks, isEmpty);
    },
  );
}
