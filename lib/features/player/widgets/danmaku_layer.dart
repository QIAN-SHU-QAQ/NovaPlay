import 'package:flutter/material.dart';
import '../../../models/danmaku_model.dart';

class DanmakuLayer extends StatefulWidget {
  final List<DanmakuItem> danmakus;
  final Duration position;
  final bool isPlaying;
  final double opacity;

  const DanmakuLayer({
    super.key,
    required this.danmakus,
    required this.position,
    required this.isPlaying,
    this.opacity = 1.0,
  });

  @override
  State<DanmakuLayer> createState() => _DanmakuLayerState();
}

class _DanmakuLayerState extends State<DanmakuLayer>
    with TickerProviderStateMixin {
  final List<_DanmakuWidget> _activeDanmakus = [];
  final Map<String, AnimationController> _controllers = {};

  @override
  void didUpdateWidget(DanmakuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isPlaying && !oldWidget.isPlaying) {
      _resumeAll();
    } else if (!widget.isPlaying && oldWidget.isPlaying) {
      _pauseAll();
    }

    _checkNewDanmakus();
  }

  void _checkNewDanmakus() {
    for (final danmaku in widget.danmakus) {
      final isInTime = danmaku.time >= widget.position &&
          danmaku.time < widget.position + const Duration(seconds: 1);

      if (isInTime && !_controllers.containsKey(danmaku.id)) {
        _addDanmaku(danmaku);
      }
    }
  }

  void _addDanmaku(DanmakuItem danmaku) {
    final controller = AnimationController(
      duration: const Duration(seconds: 8),
      vsync: this,
    );

    _controllers[danmaku.id] = controller;

    final y = _getRandomY(danmaku.type);

    setState(() {
      _activeDanmakus.add(_DanmakuWidget(
        danmaku: danmaku,
        controller: controller,
        y: y,
      ));
    });

    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _removeDanmaku(danmaku.id);
      }
    });

    if (widget.isPlaying) {
      controller.forward();
    }
  }

  void _removeDanmaku(String id) {
    _controllers.remove(id);
    setState(() {
      _activeDanmakus.removeWhere((w) => w.danmaku.id == id);
    });
  }

  double _getRandomY(DanmakuType type) {
    switch (type) {
      case DanmakuType.scroll:
        return (DateTime.now().microsecondsSinceEpoch % 200) / 200;
      case DanmakuType.top:
        return 0.1;
      case DanmakuType.bottom:
        return 0.9;
    }
  }

  void _pauseAll() {
    for (final controller in _controllers.values) {
      controller.stop();
    }
  }

  void _resumeAll() {
    for (final controller in _controllers.values) {
      controller.forward();
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Opacity(
        opacity: widget.opacity,
        child: Stack(
          children: _activeDanmakus.map((danmakuWidget) {
            return AnimatedBuilder(
              animation: danmakuWidget.controller,
              builder: (context, child) {
                final screenWidth = MediaQuery.of(context).size.width;
                final textWidth = _estimateTextWidth(danmakuWidget.danmaku);

                double x;
                switch (danmakuWidget.danmaku.type) {
                  case DanmakuType.scroll:
                    x = screenWidth * (1 - danmakuWidget.controller.value) -
                        textWidth;
                    break;
                  case DanmakuType.top:
                  case DanmakuType.bottom:
                    x = (screenWidth - textWidth) / 2;
                    break;
                }

                return Positioned(
                  left: x,
                  top: danmakuWidget.y *
                      MediaQuery.of(context).size.height *
                      0.6,
                  child: Text(
                    danmakuWidget.danmaku.text,
                    style: TextStyle(
                      color: Color(danmakuWidget.danmaku.color)
                          .withValues(alpha: 0.9),
                      fontSize: danmakuWidget.danmaku.fontSize,
                      fontWeight: FontWeight.w500,
                      shadows: [
                        Shadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 2,
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  double _estimateTextWidth(DanmakuItem danmaku) {
    return danmaku.text.length * danmaku.fontSize * 0.6;
  }
}

class _DanmakuWidget {
  final DanmakuItem danmaku;
  final AnimationController controller;
  final double y;

  _DanmakuWidget({
    required this.danmaku,
    required this.controller,
    required this.y,
  });
}

class AnimatedBuilder extends AnimatedWidget {
  final Widget Function(BuildContext, Widget?) builder;

  const AnimatedBuilder({
    super.key,
    required Animation<double> animation,
    required this.builder,
  }) : super(listenable: animation);

  @override
  Widget build(BuildContext context) {
    return builder(context, null);
  }
}
