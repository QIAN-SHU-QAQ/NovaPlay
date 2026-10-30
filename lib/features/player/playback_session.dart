import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

class PlaybackSession extends ChangeNotifier {
  PlaybackSession({
    required this.player,
    required this.initialUrl,
    required this.initialTitle,
    this.videoTitle,
    this.episodes,
    this.index = 0,
    this.startAt = 0,
  }) {
    _resumePosition = Duration(seconds: startAt);
    _errorSubscription = player.stream.error.listen((message) {
      if (_closed || _activeRequest != _request || message.isEmpty) return;
      error = message;
      ready = false;
      loading = false;
      notifyListeners();
    });
    _bufferSubscription = player.stream.buffering.listen((value) {
      if (_closed || _activeRequest != _request) return;
      buffering = value;
      notifyListeners();
    });
    _positionSubscription = player.stream.position.listen((value) {
      if (_closed || _activeRequest != _request || loading || !ready) return;
      // A failing demuxer may emit zero before stream.error; retain the last
      // useful position rather than losing the user's progress on retry.
      if (value > Duration.zero) _resumePosition = value;
    });
  }
  final Player player;
  final String initialUrl;
  final String initialTitle;
  final String? videoTitle;
  final List<Map<String, String>>? episodes;
  final int startAt;
  int index;
  bool loading = false;
  bool ready = false;
  bool buffering = false;
  String? error;
  int _request = 0;
  int _activeRequest = 0;
  bool _closed = false;
  late Duration _resumePosition;
  bool _hasSwitched = false;
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  late final StreamSubscription<String> _errorSubscription;
  late final StreamSubscription<bool> _bufferSubscription;
  late final StreamSubscription<Duration> _positionSubscription;

  String get title {
    final list = episodes;
    if (videoTitle == null ||
        list == null ||
        index < 0 ||
        index >= list.length) {
      return initialTitle;
    }
    return '$videoTitle - ${list[index]['title'] ?? '第 ${index + 1} 集'}';
  }

  String get currentUrl {
    final list = episodes;
    // Launch URL may have been resolved separately from the snapshot.
    if (!_hasSwitched || list == null || index < 0 || index >= list.length) {
      return initialUrl;
    }
    return list[index]['url'] ?? '';
  }

  Future<void> open() {
    if (_closed) return Future.value();
    final request = ++_request;
    final url = currentUrl;
    loading = true;
    ready = false;
    buffering = false;
    error = null;
    notifyListeners();
    _tail = _tail.then((_) async {
      if (_closed || request != _request) return;
      _activeRequest = request;
      final volume = player.state.volume;
      final rate = player.state.rate;
      try {
        if (url.isEmpty) throw StateError('播放地址为空');
        await player.open(Media(url));
        if (_closed || request != _request) return;
        await player.setVolume(volume);
        await player.setRate(rate);
        if (_closed || request != _request || error != null) return;
        if (_resumePosition > Duration.zero) {
          await player.seek(_resumePosition);
          if (_closed || request != _request || error != null) return;
        }
        ready = true;
      } catch (e) {
        if (!_closed && request == _request) error = e.toString();
      } finally {
        if (!_closed && request == _request) {
          loading = false;
          notifyListeners();
        }
      }
    });
    return _tail;
  }

  Future<void> switchEpisode(int value) {
    final list = episodes;
    if (_closed || list == null || value < 0 || value >= list.length) {
      return Future.value();
    }
    index = value;
    _hasSwitched = true;
    _resumePosition = Duration.zero;
    return open();
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    ++_request;
    _closing = Future.wait([
      _errorSubscription.cancel(),
      _bufferSubscription.cancel(),
      _positionSubscription.cancel(),
      _tail,
    ]).then((_) => player.dispose());
    return _closing!;
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
