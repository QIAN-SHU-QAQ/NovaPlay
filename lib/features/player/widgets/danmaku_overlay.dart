import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';

import '../../../models/danmaku_model.dart';

/// 弹幕渲染层：把 [DanmakuComment] 按播放进度投递到 canvas_danmaku。
///
/// 时间轴由播放器的 position 流驱动：
/// - 正常播放时按时间顺序投递；
/// - 发生跳转（快进/快退/切集）时清屏并按新位置重新定位；
/// - 暂停/继续时同步暂停/恢复画布动画。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.comments,
    required this.option,
    required this.positionStream,
    required this.playingStream,
  });

  final List<DanmakuComment> comments;
  final DanmakuOption option;
  final Stream<Duration> positionStream;
  final Stream<bool> playingStream;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay> {
  DanmakuController<DanmakuComment>? _controller;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;

  int _cursor = 0;
  Duration _lastPosition = Duration.zero;

  @override
  void initState() {
    super.initState();
    _positionSub = widget.positionStream.listen(_onPosition);
    _playingSub = widget.playingStream.listen(_onPlaying);
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.comments, widget.comments)) {
      _reset();
    }
    if (!identical(oldWidget.option, widget.option)) {
      _controller?.updateOption(widget.option);
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _playingSub?.cancel();
    super.dispose();
  }

  void _reset() {
    _controller?.clear();
    _cursor = 0;
    _lastPosition = Duration.zero;
  }

  void _onPlaying(bool playing) {
    final controller = _controller;
    if (controller == null) return;
    if (playing) {
      controller.resume();
    } else {
      controller.pause();
    }
  }

  void _onPosition(Duration position) {
    final last = _lastPosition;
    _lastPosition = position;
    // 跳转（含切集）后重新定位，避免把跳过的弹幕一次性倒出来。
    if (position < last || position - last > const Duration(seconds: 2)) {
      _seekTo(position);
      return;
    }
    _dispatch(position);
  }

  void _seekTo(Duration position) {
    _controller?.clear();
    _cursor = _lowerBound(position);
    _lastPosition = position;
  }

  int _lowerBound(Duration position) {
    final comments = widget.comments;
    var low = 0;
    var high = comments.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (comments[mid].time < position) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  void _dispatch(Duration position) {
    final controller = _controller;
    if (controller == null) return;
    final comments = widget.comments;
    while (_cursor < comments.length && comments[_cursor].time <= position) {
      final comment = comments[_cursor++];
      // 刚跳转时跳过已过期的少量弹幕，避免同一时刻扎堆。
      if (position - comment.time > const Duration(seconds: 1)) continue;
      controller.addDanmaku(_toContent(comment));
    }
  }

  DanmakuContentItem<DanmakuComment> _toContent(DanmakuComment comment) {
    return DanmakuContentItem<DanmakuComment>(
      comment.text,
      color: comment.color,
      type: switch (comment.type) {
        DanmakuType.scroll => DanmakuItemType.scroll,
        DanmakuType.top => DanmakuItemType.top,
        DanmakuType.bottom => DanmakuItemType.bottom,
      },
      extra: comment,
    );
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DanmakuScreen<DanmakuComment>(
        createdController: (controller) {
          _controller = controller;
          _cursor = 0;
          _lastPosition = Duration.zero;
        },
        option: widget.option,
      ),
    );
  }
}
