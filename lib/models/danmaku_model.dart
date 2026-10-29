class DanmakuItem {
  final String id;
  final String text;
  final Duration time;
  final DanmakuType type;
  final int color;
  final double fontSize;

  DanmakuItem({
    required this.id,
    required this.text,
    required this.time,
    this.type = DanmakuType.scroll,
    this.color = 0xFFFFFFFF,
    this.fontSize = 16.0,
  });

  factory DanmakuItem.fromJson(Map<String, dynamic> json) {
    return DanmakuItem(
      id: json['id'] as String,
      text: json['text'] as String,
      time: Duration(milliseconds: json['time'] as int),
      type: DanmakuType.values[json['type'] as int? ?? 0],
      color: json['color'] as int? ?? 0xFFFFFFFF,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 16.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
      'time': time.inMilliseconds,
      'type': type.index,
      'color': color,
      'fontSize': fontSize,
    };
  }
}

enum DanmakuType {
  scroll, // 滚动弹幕
  top, // 顶部弹幕
  bottom, // 底部弹幕
}
