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
  void emitCompleted() => completedController.add(true);
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

PlaybackSession makeSession(
  FakePlatform platform, {
  int startAt = 60,
  Duration resumeTimeout = const Duration(seconds: 20),
  Duration seekTimeout = const Duration(seconds: 8),
  Duration ambiguousErrorGrace = const Duration(milliseconds: 1500),
}) {
  return PlaybackSession(
    player: Player(platformPlayer: platform),
    initialUrl: 'https://example.test/1.m3u8',
    initialTitle: 'Show - One',
    videoTitle: 'Show',
    episodes: const [
      {'title': 'One', 'url': 'https://example.test/1.m3u8'},
      {'title': 'Two', 'url': 'https://example.test/2.m3u8'},
    ],
    startAt: startAt,
    resumeTimeout: resumeTimeout,
    seekTimeout: seekTimeout,
    ambiguousErrorGrace: ambiguousErrorGrace,
  );
}

void main() {
  late FakePlatform platform;
  late PlaybackSession session;
  setUp(() {
    platform = FakePlatform();
    session = makeSession(platform);
  });
  tearDown(() async => session.close());

  test('续播起点在加载时传入，确认前保持 pending 且不改写历史进度', () async {
    await session.open();
    expect(session.ready, true);
    expect(platform.starts.single, const Duration(seconds: 60));
    expect(platform.seeks, isEmpty);
    expect(session.resumePending, true);
    expect(session.confirmedPosition, const Duration(seconds: 60));

    platform.emitPosition(Duration.zero);
    platform.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(session.resumePending, true);
    expect(session.confirmedPosition, const Duration(seconds: 60));

    platform.emitPosition(const Duration(seconds: 60));
    platform.emitPosition(const Duration(seconds: 61));
    await pumpEventQueue();
    expect(session.resumePending, false);
    expect(session.confirmedPosition, const Duration(seconds: 61));
  });

  test('180 秒续播：确认前保持待完成，确认后历史门禁解除', () async {
    await session.close();
    platform = FakePlatform();
    session = makeSession(platform, startAt: 180);
    await session.open();
    expect(session.resumePending, true);
    platform.emitPosition(Duration.zero);
    platform.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(session.resumePending, true);
    expect(session.confirmedPosition, const Duration(seconds: 180));

    platform.emitPosition(const Duration(seconds: 181));
    platform.emitPosition(const Duration(seconds: 182));
    await pumpEventQueue();
    expect(session.resumePending, false);
    expect(session.confirmedPosition, const Duration(seconds: 182));
    expect(platform.starts.single, const Duration(seconds: 180));
  });

  test('时长未知时要求连续两次落在目标窗口内的位置事件', () async {
    await session.close();
    platform = FakePlatform()..mediaDuration = Duration.zero;
    session = makeSession(platform, startAt: 120);
    await session.open();
    platform.emitPosition(const Duration(seconds: 120));
    await pumpEventQueue();
    expect(session.resumePending, true);
    platform.emitPosition(const Duration(seconds: 121));
    await pumpEventQueue();
    expect(session.resumePending, false);
    expect(session.confirmedPosition, const Duration(seconds: 121));
  });

  test('媒体短于续播点：标记可恢复失败，保留原进度', () async {
    await session.close();
    platform = FakePlatform()..mediaDuration = const Duration(seconds: 120);
    session = makeSession(platform, startAt: 180);
    await session.open();
    await pumpEventQueue();
    expect(session.resumeFailed, true);
    expect(session.ready, false);
    expect(session.error, contains('短于续播点'));
    expect(session.confirmedPosition, const Duration(seconds: 180));

    // 换回足够长的媒体后重试，仍从原续播点开始。
    platform.mediaDuration = const Duration(minutes: 10);
    await session.open();
    expect(platform.starts.last, const Duration(seconds: 180));
    expect(session.resumePending, true);
  });

  test('确认超时：可恢复失败并保留原进度', () async {
    await session.close();
    platform = FakePlatform();
    session = makeSession(
      platform,
      startAt: 180,
      resumeTimeout: const Duration(milliseconds: 40),
    );
    await session.open();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(session.resumeFailed, true);
    expect(session.error, contains('未能确认'));
    expect(session.confirmedPosition, const Duration(seconds: 180));
    expect(session.ready, false);
  });

  test('媒体在续播确认前结束：标记失败，不确认目标', () async {
    await session.close();
    platform = FakePlatform();
    session = makeSession(platform, startAt: 180);
    await session.open();
    platform.emitPosition(Duration.zero);
    platform.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    session.markResumeUnreachable('媒体在续播起点前结束');
    expect(session.resumeFailed, true);
    expect(session.confirmedPosition, const Duration(seconds: 180));
    expect(session.ready, false);
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
    expect(session.resumeFailed, true);
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
    session = makeSession(platform, startAt: 180);
    await session.open();
    platform.emitPosition(const Duration(seconds: 181));
    platform.emitPosition(const Duration(seconds: 182));
    await pumpEventQueue();
    expect(session.resumePending, false);
    // 失败解复用器可能在 error 前把位置重置为 0；不能被当成回退覆盖。
    platform.emitPosition(Duration.zero);
    platform.emitError('connection reset');
    await pumpEventQueue();
    await session.open();
    expect(platform.starts.last, const Duration(seconds: 182));
  });

  test('确认后瞬时 0/5 秒事件不能覆盖已确认进度', () async {
    await session.close();
    platform = FakePlatform();
    session = makeSession(platform, startAt: 180);
    await session.open();
    platform.emitPosition(const Duration(seconds: 181));
    platform.emitPosition(const Duration(seconds: 182));
    await pumpEventQueue();
    platform.emitPosition(const Duration(seconds: 5));
    platform.emitPosition(const Duration(seconds: 3));
    await pumpEventQueue();
    expect(session.confirmedPosition, const Duration(seconds: 182));
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

  test('旧媒体迟到错误不能中止已开始的新请求', () async {
    await session.open();
    await pumpEventQueue();
    expect(session.ready, true);
    platform.gate = Completer<void>();
    final switching = session.switchEpisode(1);
    await pumpEventQueue();
    // 新请求已经进入 open 等待；此时旧媒体错误到达。
    platform.emitError('Failed to open https://example.test/1.m3u8.');
    await pumpEventQueue();
    platform.gate!.complete();
    await switching;
    expect(session.ready, true);
    expect(session.error, isNull);
    expect(session.index, 1);
  });

  test('用户 seek 未生效前保持门禁，抵达后才接受新进度', () async {
    await session.open();
    platform.emitPosition(const Duration(seconds: 60));
    platform.emitPosition(const Duration(seconds: 61));
    await pumpEventQueue();
    expect(session.resumePending, false);
    expect(session.confirmedPosition, const Duration(seconds: 61));

    session.noteUserSeek(const Duration(seconds: 10));
    expect(session.seekPending, true);
    expect(session.confirmedPosition, const Duration(seconds: 61));
    // seek 尚未生效：旧的 5 秒位置不能写入。
    platform.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(session.seekPending, true);
    expect(session.confirmedPosition, const Duration(seconds: 61));

    platform.emitPosition(const Duration(seconds: 10));
    await pumpEventQueue();
    expect(session.seekPending, false);
    expect(session.confirmedPosition, const Duration(seconds: 10));

    platform.emitError('later failure');
    await pumpEventQueue();
    await session.open();
    expect(platform.starts.last, const Duration(seconds: 10));
  });

  test('用户 seek 超时后放弃新进度、保留原确认进度', () async {
    await session.close();
    platform = FakePlatform();
    session = makeSession(
      platform,
      startAt: 60,
      seekTimeout: const Duration(milliseconds: 40),
    );
    await session.open();
    platform.emitPosition(const Duration(seconds: 60));
    platform.emitPosition(const Duration(seconds: 61));
    await pumpEventQueue();
    session.noteUserSeek(const Duration(seconds: 200));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(session.seekPending, false);
    expect(session.confirmedPosition, const Duration(seconds: 61));
  });

  test('从头播放把 0 秒视为明确意图，允许历史写入', () async {
    await session.open();
    platform.emitPosition(Duration.zero);
    platform.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(session.resumePending, true);
    session.startFromBeginning();
    expect(session.resumePending, false);
    expect(session.resumeFailed, false);
    expect(session.confirmedPosition, Duration.zero);
  });

  test('单次瞬时命中后提前结束：不确认目标，保留原进度', () async {
    await session.close();
    platform = FakePlatform();
    session = makeSession(platform, startAt: 180);
    await session.open();
    platform.emitPosition(const Duration(seconds: 181));
    platform.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(session.resumePending, true);
    session.markResumeUnreachable('媒体在续播起点前结束');
    expect(session.resumeFailed, true);
    expect(session.confirmedPosition, const Duration(seconds: 180));
  });

  test('首个请求加载期间当前媒体错误不会被吞掉', () async {
    await session.close();
    platform = FakePlatform()..gate = Completer<void>();
    session = makeSession(platform, startAt: 0);
    final opening = session.open();
    await pumpEventQueue();
    platform.emitError('HTTP 500 current media');
    await pumpEventQueue();
    platform.gate!.complete();
    await opening;
    expect(session.error, contains('HTTP 500 current media'));
    expect(session.ready, false);
    expect(session.resumeFailed, true);
  });
  test('首播失败后的重试仍保留同一个当前媒体错误', () async {
    await session.close();
    platform = FakePlatform()..gate = Completer<void>();
    session = makeSession(platform, startAt: 0);
    final opening = session.open();
    await pumpEventQueue();
    platform.emitError('HTTP 500 current media');
    await pumpEventQueue();
    platform.gate!.complete();
    await opening;
    expect(session.error, contains('HTTP 500 current media'));
    expect(session.ready, false);

    // 重试：相同顺序上报同一个当前媒体错误，仍必须显示失败与重试。
    platform.gate = Completer<void>();
    final retry = session.open();
    await pumpEventQueue();
    platform.emitError('HTTP 500 current media');
    await pumpEventQueue();
    platform.gate!.complete();
    await retry;
    expect(session.error, contains('HTTP 500 current media'));
    expect(session.ready, false);
    expect(session.resumeFailed, true);
  });

  test('seek 未生效时媒体结束：进入可恢复失败并保留原进度', () async {
    await session.close();
    platform = FakePlatform();
    session = makeSession(platform, startAt: 180);
    await session.open();
    platform.emitPosition(const Duration(seconds: 181));
    platform.emitPosition(const Duration(seconds: 182));
    await pumpEventQueue();
    expect(session.resumePending, false);
    session.noteUserSeek(const Duration(seconds: 200));
    expect(session.seekPending, true);
    session.markResumeUnreachable('媒体在 seek 生效前结束');
    expect(session.resumeFailed, true);
    expect(session.seekPending, false);
    expect(session.ready, false);
    expect(session.confirmedPosition, const Duration(seconds: 182));
  });
  test('换集后新集自身的加载错误仍会保留并提示重试', () async {
    await session.open();
    platform.emitPosition(const Duration(seconds: 60));
    platform.emitPosition(const Duration(seconds: 61));
    await pumpEventQueue();
    expect(session.ready, true);

    platform.gate = Completer<void>();
    final switching = session.switchEpisode(1);
    await pumpEventQueue();
    // 新集 open 等待期间上报的是新集自己的错误（含当前 URL）。
    platform.emitError('Failed to open https://example.test/2.m3u8: HTTP 403');
    await pumpEventQueue();
    platform.gate!.complete();
    await switching;
    expect(session.ready, false);
    expect(session.error, contains('HTTP 403'));
    expect(session.resumeFailed, true);
  });

  test('seek 取代未确认续播且超时：进入可恢复失败而不是放行', () async {
    await session.close();
    platform = FakePlatform();
    session = makeSession(
      platform,
      startAt: 180,
      seekTimeout: const Duration(milliseconds: 40),
    );
    await session.open();
    platform.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(session.resumePending, true);
    session.noteUserSeek(const Duration(seconds: 10));
    expect(session.seekPending, true);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(session.seekPending, false);
    expect(session.resumeFailed, true);
    expect(session.error, contains('seek'));
    expect(session.confirmedPosition, const Duration(seconds: 180));
  });
  test('换集时无 URL 的旧媒体错误不终止新集', () async {
    await session.open();
    platform.emitPosition(const Duration(seconds: 60));
    platform.emitPosition(const Duration(seconds: 61));
    await pumpEventQueue();
    expect(session.ready, true);

    platform.gate = Completer<void>();
    final switching = session.switchEpisode(1);
    await pumpEventQueue();
    // libmpv 原生错误可能只有文字，没有媒体 URL。
    platform.emitError('Failed to recognize file format.');
    await pumpEventQueue();
    platform.gate!.complete();
    await switching;
    expect(session.ready, true);
    expect(session.error, isNull);
  });

  test('连续两次 seek 仍保留未确认续播保护，超时进入失败态', () async {
    await session.close();
    platform = FakePlatform();
    session = makeSession(
      platform,
      startAt: 180,
      seekTimeout: const Duration(milliseconds: 40),
    );
    await session.open();
    platform.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(session.resumePending, true);
    session.noteUserSeek(const Duration(seconds: 10));
    session.noteUserSeek(const Duration(seconds: 15));
    expect(session.seekPending, true);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(session.seekPending, false);
    expect(session.resumeFailed, true);
    expect(session.confirmedPosition, const Duration(seconds: 180));
  });
  test('新集无 URL 错误且无成功加载证据：有界转入可重试失败', () async {
    await session.close();
    platform = FakePlatform();
    session = makeSession(
      platform,
      startAt: 0,
      ambiguousErrorGrace: const Duration(milliseconds: 40),
    );
    await session.open();
    expect(session.ready, true);

    // 新集加载期间只收到无 URL 的原生错误，open 正常返回但 duration=0。
    platform.mediaDuration = Duration.zero;
    platform.gate = Completer<void>();
    final switching = session.switchEpisode(1);
    await pumpEventQueue();
    platform.emitError('Failed to recognize file format.');
    await pumpEventQueue();
    platform.gate!.complete();
    await switching;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(session.ready, false);
    expect(session.error, contains('Failed to recognize file format.'));
    expect(session.resumeFailed, true);
  });
  test('无归属加载错误后新集出现位置事件：按旧错误清除待定', () async {
    await session.close();
    platform = FakePlatform();
    session = makeSession(
      platform,
      startAt: 0,
      ambiguousErrorGrace: const Duration(milliseconds: 80),
    );
    await session.open();
    expect(session.ready, true);

    platform.mediaDuration = Duration.zero;
    platform.gate = Completer<void>();
    final switching = session.switchEpisode(1);
    await pumpEventQueue();
    platform.emitError('Failed to recognize file format.');
    await pumpEventQueue();
    platform.gate!.complete();
    await switching;
    expect(session.ambiguousLoadErrorPending, true);

    platform.emitPosition(const Duration(seconds: 1));
    await pumpEventQueue();
    expect(session.ambiguousLoadErrorPending, false);
    expect(session.ready, true);
    expect(session.error, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(session.ready, true);
    expect(session.error, isNull);
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
