import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/features/player/widgets/danmaku_overlay.dart';
import 'package:nova_play/models/danmaku_model.dart';

void main() {
  testWidgets('DanmakuOverlay 按进度投递弹幕且不抛异常', (tester) async {
    final positions = StreamController<Duration>.broadcast();
    final playing = StreamController<bool>.broadcast();
    addTearDown(positions.close);
    addTearDown(playing.close);

    final comments = [
      DanmakuComment(
        cid: 1,
        time: const Duration(seconds: 1),
        type: DanmakuType.scroll,
        color: Colors.white,
        text: '测试弹幕',
      ),
      DanmakuComment(
        cid: 2,
        time: const Duration(seconds: 3),
        type: DanmakuType.top,
        color: Colors.red,
        text: '顶部弹幕',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: DanmakuOverlay(
              comments: comments,
              option: const DanmakuOption(),
              positionStream: positions.stream,
              playingStream: playing.stream,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 正常推进：命中第一条
    positions.add(const Duration(milliseconds: 500));
    await tester.pump();
    playing.add(true);
    await tester.pump();
    positions.add(const Duration(milliseconds: 1100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);

    // 快进跳转：清屏后重新定位
    positions.add(const Duration(seconds: 30));
    await tester.pump();
    positions.add(const Duration(seconds: 31));
    await tester.pump();
    expect(tester.takeException(), isNull);

    // 暂停
    playing.add(false);
    await tester.pump();

    // 卸载时取消订阅
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
