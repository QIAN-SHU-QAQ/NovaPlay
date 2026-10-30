import 'package:flutter/services.dart';

/// 独立播放窗口与原生 runner 之间的桥。
///
/// runner（windows/runner/flutter_window.cpp）会给每个播放窗口注册
/// `nova_play/player_window` 通道，支持 close / setTitle。
class PlayerWindowBridge {
  static const MethodChannel _channel = MethodChannel(
    'nova_play/player_window',
  );

  /// 当前进程是否是播放子窗口（由 main() 根据启动参数设置）。
  static bool isPlayerWindow = false;

  static Future<void> setTitle(String title) async {
    if (!isPlayerWindow) return;
    try {
      await _channel.invokeMethod<void>('setTitle', title);
    } catch (_) {
      // 非 Windows / 测试环境没有原生通道，忽略即可。
    }
  }

  static Future<void> close() async {
    if (!isPlayerWindow) return;
    try {
      await _channel.invokeMethod<void>('close');
    } catch (_) {
      // 忽略：窗口关闭失败时由用户点窗口关闭按钮兜底。
    }
  }
}
