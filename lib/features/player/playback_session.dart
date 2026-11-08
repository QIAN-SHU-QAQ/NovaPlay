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
/// - 目标不可达（媒体时长不足 / 确认超时 / 未确认就结束）视为可恢复失败：
///   保留最后一次已确认进度、阻塞历史写入与自动切集，并允许重试/从头播放；
/// - 用户主动 seek 先进入 [seekPending]，只有媒体实际位置抵达新目标后才
///   接受新进度，避免「seek 请求已发出、实际还在 5 秒」时写错历史；
/// - 迟到的旧媒体错误在请求切换期间不得终止新请求。
class PlaybackSession extends ChangeNotifier {
  PlaybackSession({
    required this.player,
    required this.initialUrl,
    required this.initialTitle,
    this.videoTitle,
    this.episodes,
    this.index = 0,
    this.startAt = 0,
    this.resumeTimeout = const Duration(seconds: 20),
    this.seekTimeout = const Duration(seconds: 8),
    this.ambiguousErrorGrace = const Duration(milliseconds: 1500),
  }) {
    _resumeTarget = Duration(seconds: startAt);
    _confirmedPosition = _resumeTarget;
    _errorSubscription = player.stream.error.listen((message) {
      if (_closed || _activeRequest != _request || message.isEmpty) return;
      // 加载期间的错误按媒体身份归属：
      // - 明确包含上一媒体 URL → 旧媒体迟到错误，忽略；
      // - 明确包含当前媒体 URL → 当前请求失败，保留重试；
      // - 首个请求/失败重试没有旧媒体可排除 → 当前失败；
      // - 换集加载期、无法归属（如 libmpv 只给
      //   "Failed to recognize file format." 或仅分片路径）→ 可能是旧媒体
      //   迟到错误，新集 open 成功时不能据此终止；当前请求真实失败由
      //   open 异常或加载结束后的错误事件兜底。
      if (loading) {
        final current = currentUrl;
        final previous = _previousOpenedUrl;
        final hasPrevious =
            previous != null && previous.isNotEmpty && previous != current;
        if (hasPrevious &&
            message.contains(previous) &&
            !message.contains(current)) {
          debugPrint('PlaybackSession 忽略旧媒体迟到错误: $message');
          return;
        }
        if (message.contains(current) || !hasPrevious) {
          _pendingLoadError = message;
          return;
        }
        // 换集加载期、无法归属媒体身份的错误（如 libmpv 的
        // "Failed to recognize file format." 或只含分片路径）可能来自旧
        // 媒体：先记录为待定错误，等新集是否出现成功加载证据再决定。
        debugPrint('PlaybackSession 记录待归属的加载期错误: $message');
        _ambiguousLoadError = message;
        return;
      }
      debugPrint('PlaybackSession 媒体错误: $message');
      _failResume(message);
    });
    _bufferSubscription = player.stream.buffering.listen((value) {
      if (_closed || _activeRequest != _request) return;
      buffering = value;
      notifyListeners();
    });
    _positionSubscription = player.stream.position.listen((value) {
      if (_closed || _activeRequest != _request || loading || !ready) return;
      // 新集已经开始出位置：说明此前的无归属错误来自旧媒体，清除待定。
      if (_ambiguousLoadError != null) {
        _ambiguousErrorTimer?.cancel();
        _ambiguousLoadError = null;
        notifyListeners();
      }
      if (_resumePending) {
        _handlePendingPosition(value);
        return;
      }
      _handleActivePosition(value);
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

  /// 用户 seek 实际生效的判定窗口。
  static const Duration seekTolerance = Duration(seconds: 3);

  /// 续播确认超时：超时后按可恢复失败处理，保留原进度。
  final Duration resumeTimeout;

  /// 用户 seek 生效超时：超时后放弃本次 seek 的进度确认，保留原进度。
  final Duration seekTimeout;

  /// 无法归属的加载期错误等待「新集成功加载证据」的有界窗口；
  /// 超时仍无证据时转入可重试失败，避免误报就绪。
  final Duration ambiguousErrorGrace;

  int index;
  bool loading = false;
  bool ready = false;
  bool buffering = false;
  String? error;
  int _request = 0;
  int _activeRequest = 0;
  bool _closed = false;

  /// 当前请求/重试应使用的起点。确认前保持目标，确认后跟随进度。
  late Duration _resumeTarget;

  /// 最后一次被确认的播放进度（未被确认的 0/5 秒不会覆盖它）。
  late Duration _confirmedPosition;

  /// 续播目标是否仍在等待媒体层确认。
  bool _resumePending = false;
  bool _resumeFailed = false;
  int _resumeWindowHits = 0;

  /// 上一次成功打开过的媒体 URL，用于归属加载期间的迟到错误。
  String? _previousOpenedUrl;
  String? _pendingLoadError;

  /// 无法归属媒体身份、可能是旧媒体的加载期错误；等待新集加载证据。
  String? _ambiguousLoadError;

  /// 用户 seek 是否取代了尚未确认的续播；超时后要恢复保护而不是放行。
  bool _seekReplacedResume = false;

  /// 用户主动 seek 的目标；非空表示等待媒体实际抵达。
  Duration? _pendingSeekTarget;

  Timer? _resumeTimer;
  Timer? _seekTimer;
  Timer? _ambiguousErrorTimer;
  bool _hasSwitched = false;
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  late final StreamSubscription<String> _errorSubscription;
  late final StreamSubscription<bool> _bufferSubscription;
  late final StreamSubscription<Duration> _positionSubscription;

  /// 当前请求/重试应使用的起点。
  Duration get resumeTarget => _resumeTarget;

  /// 最后一次已确认进度；历史写入应以此为准。
  Duration get confirmedPosition => _confirmedPosition;

  /// 续播是否仍在等待确认；为 true 时不得写入历史。
  bool get resumePending => _resumePending;

  /// 续播是否已确认失败（可重试或从头播放）；为 true 时不得写入历史/自动切集。
  bool get resumeFailed => _resumeFailed;

  /// 用户 seek 是否尚未被媒体实际位置确认；为 true 时不得写入历史。
  bool get seekPending => _pendingSeekTarget != null;

  /// 是否有无法归属、仍在等待新集加载证据的加载期错误。
  bool get ambiguousLoadErrorPending => _ambiguousLoadError != null;

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
    _pendingLoadError = null;
    _ambiguousLoadError = null;
    _ambiguousErrorTimer?.cancel();
    _resumeWindowHits = 0;
    _resumeFailed = false;
    _pendingSeekTarget = null;
    _seekReplacedResume = false;
    _cancelTimers();
    _resumePending = target > Duration.zero;
    if (_resumePending) {
      _resumeTimer = Timer(resumeTimeout, () {
        if (_closed || request != _request || !_resumePending) return;
        _failResume('续播起点在 ${resumeTimeout.inSeconds} 秒内未能确认，请重试或从头播放');
      });
    }
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
        // 首个请求加载期间若当前媒体已报错，即使 open() 正常返回也要
        // 保留失败提示和重试入口，不能静默 ready。
        final loadError = _pendingLoadError;
        _pendingLoadError = null;
        if (loadError != null) {
          _failResume(loadError);
          return;
        }
        _previousOpenedUrl = url;
        ready = true;
        final ambiguous = _ambiguousLoadError;
        if (ambiguous != null) {
          if (player.state.duration > Duration.zero) {
            _ambiguousLoadError = null;
          } else {
            _ambiguousErrorTimer?.cancel();
            _ambiguousErrorTimer = Timer(ambiguousErrorGrace, () {
              if (_closed || request != _request) return;
              final pending = _ambiguousLoadError;
              _ambiguousLoadError = null;
              if (pending != null) _failResume(pending);
            });
          }
        }
        final duration = player.state.duration;
        if (_resumePending &&
            duration > Duration.zero &&
            duration < target - resumeToleranceBefore) {
          _failResume(
            '媒体时长 ${duration.inSeconds} 秒，短于续播点 ${target.inSeconds} 秒',
          );
          return;
        }
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
          _failResume(e.toString());
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
    final duration = player.state.duration;
    if (duration > Duration.zero &&
        duration < _resumeTarget - resumeToleranceBefore) {
      _failResume(
        '媒体时长 ${duration.inSeconds} 秒，短于续播点 ${_resumeTarget.inSeconds} 秒',
      );
      return;
    }
    if (!_isWithinResumeWindow(value)) {
      _resumeWindowHits = 0;
      return;
    }
    _resumeWindowHits++;
    // 必须连续两次落在目标窗口内的位置事件才确认，避免单次瞬时 181 秒
    // 命中后媒体立刻结束/回落时把目标当成已确认。
    if (_resumeWindowHits < 2) return;
    _resumeTimer?.cancel();
    _resumePending = false;
    _resumeWindowHits = 0;
    _confirmedPosition = value;
    _resumeTarget = value;
    notifyListeners();
  }

  void _handleActivePosition(Duration value) {
    final pendingSeek = _pendingSeekTarget;
    if (pendingSeek != null) {
      if ((value - pendingSeek).abs() <= seekTolerance) {
        _seekTimer?.cancel();
        _pendingSeekTarget = null;
        _seekReplacedResume = false;
        _confirmedPosition = value;
        _resumeTarget = value;
        notifyListeners();
      }
      // seek 生效前忽略其它位置事件，尤其不能把旧位置写进历史。
      return;
    }
    // 正常播放只接受向前推进；偶发的 0/5 秒回退不覆盖已确认进度。
    if (value >= _confirmedPosition && value > Duration.zero) {
      _confirmedPosition = value;
      _resumeTarget = value;
    }
  }

  bool _isWithinResumeWindow(Duration value) {
    if (value < _resumeTarget - resumeToleranceBefore) return false;
    if (value > _resumeTarget + resumeToleranceAfter) return false;
    return true;
  }

  /// 媒体结束/确认超时/时长不足等不可恢复条件：保留原进度并允许重试。
  void _failResume(String message) {
    _cancelTimers();
    _ambiguousErrorTimer?.cancel();
    _ambiguousLoadError = null;
    _resumePending = false;
    _resumeFailed = true;
    _pendingSeekTarget = null;
    _seekReplacedResume = false;
    ready = false;
    loading = false;
    error = message;
    notifyListeners();
  }

  /// 播放器结束时调用：续播尚未确认或 seek 尚未生效说明目标不可达，
  /// 阻止自动切集并进入可恢复失败（保留最后一次确认进度）。
  void markResumeUnreachable(String reason) {
    if (_closed) return;
    if (!_resumePending &&
        !_resumeFailed &&
        !seekPending &&
        _ambiguousLoadError == null) {
      return;
    }
    _failResume(reason);
  }

  void _cancelTimers() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _seekTimer?.cancel();
    _seekTimer = null;
    _ambiguousErrorTimer?.cancel();
    _ambiguousErrorTimer = null;
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
    _resumeFailed = false;
    _resumeWindowHits = 0;
    _pendingSeekTarget = null;
    _seekReplacedResume = false;
    _cancelTimers();
    return open();
  }

  /// 用户主动跳转（拖动进度条、±5 秒等）。
  ///
  /// 不立即放开门禁：先记录目标，等媒体位置真正抵达后再更新已确认进度；
  /// 超时则放弃本次确认，保留原进度，避免把 seek 前的旧位置写进历史。
  void noteUserSeek(Duration position) {
    if (_closed) return;
    final clamped = position < Duration.zero ? Duration.zero : position;
    // 如果 seek 取代的是尚未确认的续播，超时后必须恢复保护（进入可恢复
    // 失败），不能简单放行后让 completed 自动切集覆盖历史。
    // 连续多次 seek 时保留保护：只要其中一次取代了未确认续播，后续
    // seek 不能把标记覆盖回 false。
    _seekReplacedResume = _seekReplacedResume || _resumePending;
    _resumePending = false;
    _resumeFailed = false;
    _resumeWindowHits = 0;
    error = null;
    _pendingSeekTarget = clamped;
    _seekTimer?.cancel();
    _seekTimer = Timer(seekTimeout, () {
      if (_closed || _pendingSeekTarget == null) return;
      if (_seekReplacedResume) {
        _seekReplacedResume = false;
        _failResume('用户 seek 未在 ${seekTimeout.inSeconds} 秒内生效，续播尚未确认，请重试或从头播放');
        return;
      }
      _pendingSeekTarget = null;
      notifyListeners();
    });
    notifyListeners();
  }

  /// 明确选择从头播放：以 0 秒作为新起点重新打开媒体。
  void startFromBeginning() {
    if (_closed) return;
    _resumePending = false;
    _resumeFailed = false;
    _resumeWindowHits = 0;
    _pendingSeekTarget = null;
    _seekReplacedResume = false;
    _cancelTimers();
    _resumeTarget = Duration.zero;
    _confirmedPosition = Duration.zero;
    error = null;
    notifyListeners();
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    ++_request;
    _cancelTimers();
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
