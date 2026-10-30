import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:nova_play/features/player/playback_session.dart';

class FakePlatform extends PlatformPlayer {
  FakePlatform() : super(configuration: const PlayerConfiguration());
  final opened = <String>[];
  final seeks = <Duration>[];
  Completer<void>? gate;
  bool fail = false;
  bool disposed = false;
  final disposal = Completer<void>();
  void emitBuffering(bool value) => bufferingController.add(value);
  void emitError(String message) => errorController.add(message);
  void emitPosition(Duration value) {
    state = state.copyWith(position: value);
    positionController.add(value);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add((playable as Media).uri);
    await gate?.future;
    if (fail) throw StateError('offline');
    state = state.copyWith(position: Duration.zero);
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

  test('switch preserves volume and rate and updates title', () async {
    await session.open();
    await session.player.setVolume(35);
    await session.player.setRate(1.5);
    await session.switchEpisode(1);
    expect(platform.state.volume, 35);
    expect(platform.state.rate, 1.5);
    expect(session.title, 'Show - Two');
    expect(platform.seeks, [const Duration(seconds: 60)]);
  });
  test(
    'failed initial open can retry and still seek resume position',
    () async {
      platform.fail = true;
      await session.open();
      expect(session.error, isNotNull);
      expect(session.loading, false);
      platform.fail = false;
      await session.open();
      expect(session.error, isNull);
      expect(session.ready, true);
      expect(platform.seeks, [const Duration(seconds: 60)]);
    },
  );
  test('native error and buffering events update observable state', () async {
    await session.open();
    platform.emitBuffering(true);
    await Future<void>.delayed(Duration.zero);
    expect(session.buffering, true);
    platform.emitError('HTTP 403');
    await Future<void>.delayed(Duration.zero);
    expect(session.error, contains('HTTP 403'));
    expect(session.ready, false);
  });
  test('late native startup error preserves initial resume on retry', () async {
    await session.open();
    // mpv open/seek Futures can complete before HTTP failure arrives.
    platform.emitError('HTTP 403');
    await Future<void>.delayed(Duration.zero);
    expect(platform.state.position, Duration.zero);
    await session.open();
    expect(platform.seeks, [
      const Duration(seconds: 60),
      const Duration(seconds: 60),
    ]);
  });
  test(
    'late native error retries at latest same-episode position only',
    () async {
      await session.open();
      platform.emitPosition(const Duration(seconds: 180));
      await Future<void>.delayed(Duration.zero);
      // A failing demuxer can reset its position before emitting error.
      platform.emitPosition(Duration.zero);
      platform.emitError('connection reset');
      await Future<void>.delayed(Duration.zero);
      await session.open();
      expect(platform.seeks.last, const Duration(seconds: 180));
      final seekCount = platform.seeks.length;
      await session.switchEpisode(1);
      platform.emitError('next episode offline');
      await Future<void>.delayed(Duration.zero);
      await session.open();
      expect(platform.seeks.length, seekCount);
    },
  );
  test(
    'rapid switching serializes opens and skips obsolete queued requests',
    () async {
      platform.gate = Completer<void>();
      final first = session.open();
      await Future<void>.delayed(Duration.zero);
      final old = session.switchEpisode(0);
      final latest = session.switchEpisode(1);
      platform.gate!.complete();
      await Future.wait([first, old, latest]);
      expect(platform.opened.length, 2);
      expect(platform.opened.last, endsWith('/2.m3u8'));
      expect(session.index, 1);
      expect(platform.seeks, isEmpty);
    },
  );
  test(
    'close while opening suppresses callbacks and disposes after open',
    () async {
      platform.gate = Completer<void>();
      final opening = session.open();
      await Future<void>.delayed(Duration.zero);
      final closing = session.close();
      platform.gate!.complete();
      await Future.wait([opening, closing]);
      expect(platform.disposed, true);
      expect(platform.seeks, isEmpty);
    },
  );
}
