import 'package:flutter/material.dart';

/// 弹幕类型。dandanplay 的 mode 字段：
/// 1/2/3 → 滚动，4 → 底部，5 → 顶部；6-9 为特殊弹幕，目前忽略。
enum DanmakuType { scroll, top, bottom }

/// 一条弹幕（数据层模型，渲染时再转成 canvas_danmaku 的 Item）。
class DanmakuComment {
  final int cid;
  final Duration time;
  final DanmakuType type;
  final Color color;
  final String text;

  const DanmakuComment({
    required this.cid,
    required this.time,
    required this.type,
    required this.color,
    required this.text,
  });

  /// 解析 dandanplay 弹幕：`p` 为「出现时间(秒),模式,颜色(十进制),用户ID」。
  ///
  /// 返回 null 表示这条弹幕无法解析或是暂不支持的特殊弹幕。
  static DanmakuComment? tryParse({
    required int cid,
    required String p,
    required String text,
  }) {
    final parts = p.split(',');
    if (parts.length < 3 || text.trim().isEmpty) return null;

    final seconds = double.tryParse(parts[0]);
    final mode = int.tryParse(parts[1]);
    final colorValue = int.tryParse(parts[2]);
    if (seconds == null || seconds < 0) return null;

    final type = switch (mode) {
      1 || 2 || 3 => DanmakuType.scroll,
      4 => DanmakuType.bottom,
      5 => DanmakuType.top,
      _ => null,
    };
    if (type == null) return null;

    final rgb = (colorValue ?? 0xFFFFFF) & 0xFFFFFF;
    return DanmakuComment(
      cid: cid,
      time: Duration(milliseconds: (seconds * 1000).round()),
      type: type,
      color: Color(0xFF000000 | rgb),
      text: text.length > 200 ? text.substring(0, 200) : text,
    );
  }
}
