import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// 单次播放会话：负责打开媒体、维护续播起点与「已确认进度」。
///
/// 续播修复要点（P0）：
/// - 续播起点通过 [Media.start] 交给 libmpv，在媒体加载阶段生效，
///   不再使用「open() 返回后立刻 seek()」的不可靠路径；
/// - open() 返回不代表目标位置已经生效。在收到时长/连续位置事件确认
///   抵达目标之前，会话保持 [resumePending]，调用方（历史写入）必须暂停；
/// - 确认失败、取消或快速切集时保留最后一次已确认进度，绝不把 0/5 秒的
///   初始位置写回历史；
/// - 用户主动拖动/从头播放属于明确意图，直接以新位置作为已确认进度。
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
    _resumeTarget = Duration(seconds: startAt);
    _confirmedPosition = _resumeTarget;
    _errorSubscription = player.stream.error.listen((message) {
      if (_closed || _activeRequest != _request || message.isEmpty) return;
      debugPrint('PlaybackSession 媒体错误: $message');
      error = message;
      ready = false;
      loading = false;
      // 失败时保留原始续播目标；位置归零/推进都不算确认。
      _resumePending = false;
      _resumeWindowHits = 0;
      notifyListeners();
    });
    _bufferSubscription = player.stream.buffering.listen((value) {
      if (_closed || _activeRequest != _request) return;
      buffering = value;
      notifyListeners();
    });
    _positionSubscription = player.stream.position.listen((value) {
      if (_closed || _activeRequest != _request || loading || !ready) return;
      if (_resumePending) {
        _handlePendingPosition(value);
        return;
      }
      // A failing demuxer may emit zero before stream.error; retain the last
      // useful position rather than losing the user's progress on retry.
      if (value > Duration.zero) {
        _confirmedPosition = value;
        _resumeTarget = value;
      }
    });
  }
  final Player player;
  final String initialUrl;
  final String initialTitle;
  final String? videoTitle;
  final List<Map<String, String>>? episodes;
  final int startAt;

  /// 续播目标允许的前置误差：HLS 首帧通常落在目标前 1-2 秒。
  static const Duration resumeToleranceBefore = Duration(seconds: 2);

  /// 续播目标允许的后置误差：关键帧可能落在目标之后几秒。
  static const Duration resumeToleranceAfter = Duration(seconds: 5);

  int index;
  bool loading = false;
  bool ready = false;
  bool buffering = false;
  String? error;
  int _request = 0;
  int _activeRequest = 0;
  bool _closed = false;

  /// 当前请求/重试应使用的起点。确认前保持原始续播目标，确认后跟随进度。
  late Duration _resumeTarget;

  /// 最后一次被确认的播放进度（未被确认的 0/5 秒不会覆盖它）。
  late Duration _confirmedPosition;

  /// 续播目标是否仍在等待媒体层确认。
  bool _resumePending = false;
  int _resumeWindowHits = 0;
  bool _hasSwitched = false;
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  late final StreamSubscription<String> _errorSubscription;
  late final StreamSubscription<bool> _bufferSubscription;
  late final StreamSubscription<Duration> _positionSubscription;

  /// 续播目标（秒）。
  Duration get resumeTarget => _resumeTarget;

  /// 最后一次已确认进度；历史写入应以此为准。
  Duration get confirmedPosition => _confirmedPosition;

  /// 续播是否仍在等待确认；为 true 时不得写入历史。
  bool get resumePending => _resumePending;

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
    final target = _resumeTarget;
    loading = true;
    ready = false;
    buffering = false;
    error = null;
    _resumeWindowHits = 0;
    _resumePending = target > Duration.zero;
    notifyListeners();
    _tail = _tail.then((_) async {
      if (_closed || request != _request) return;
      _activeRequest = request;
      final volume = player.state.volume;
      final rate = player.state.rate;
      try {
        if (url.isEmpty) throw StateError('播放地址为空');
        // 起点在加载时交给 libmpv；不要 open() 返回后立刻 seek。
        await player.open(
          Media(url, start: target > Duration.zero ? target : null),
        );
        if (_closed || request != _request) return;
        await player.setVolume(volume);
        await player.setRate(rate);
        if (_closed || request != _request || error != null) return;
        ready = true;
        if (_resumePending) {
          // 某些后端会在 open() 返回前已把位置放到目标附近。
          _handlePendingPosition(player.state.position);
        } else {
          final position = player.state.position;
          if (position > Duration.zero) {
            _confirmedPosition = position;
            _resumeTarget = position;
          }
        }
      } catch (e) {
        debugPrint('PlaybackSession 打开失败: $e');
        if (!_closed && request == _request) {
          error = e.toString();
          ready = false;
          _resumePending = false;
        }
      } finally {
        if (!_closed && request == _request) {
          loading = false;
          notifyListeners();
        }
      }
    });
    return _tail;
  }

  void _handlePendingPosition(Duration value) {
    if (!_isWithinResumeWindow(value)) {
      _resumeWindowHits = 0;
      return;
    }
    _resumeWindowHits++;
    // 时长已知且足够长时，一次落在窗口内的位置即可确认；
    // 时长未知时要求连续两次位置事件，避免把偶发位置当成加载完成。
    final duration = player.state.duration;
    final durationConfirms =
        duration > Duration.zero && duration >= _resumeTarget;
    if (!durationConfirms && _resumeWindowHits < 2) return;
    _resumePending = false;
    _resumeWindowHits = 0;
    _confirmedPosition = value;
    _resumeTarget = value;
    notifyListeners();
  }

  bool _isWithinResumeWindow(Duration value) {
    if (value < _resumeTarget - resumeToleranceBefore) return false;
    if (value > _resumeTarget + resumeToleranceAfter) return false;
    return true;
  }

  Future<void> switchEpisode(int value) {
    final list = episodes;
    if (_closed || list == null || value < 0 || value >= list.length) {
      return Future.value();
    }
    index = value;
    _hasSwitched = true;
    _resumeTarget = Duration.zero;
    _confirmedPosition = Duration.zero;
    _resumePending = false;
    _resumeWindowHits = 0;
    return open();
  }

  /// 用户主动跳转（拖动进度条、±5 秒、从头播放等）。
  ///
  /// 这是明确意图：立即结束待确认状态，并把新位置视为已确认进度，
  /// 之后历史可以继续写入（包括用户主动拖回更早位置）。
  void noteUserSeek(Duration position) {
    if (_closed) return;
    final clamped = position < Duration.zero ? Duration.zero : position;
    _resumePending = false;
    _resumeWindowHits = 0;
    _confirmedPosition = clamped;
    _resumeTarget = clamped;
    notifyListeners();
  }

  /// 明确选择从头播放：允许历史随后保存新位置。
  void startFromBeginning() => noteUserSeek(Duration.zero);

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
