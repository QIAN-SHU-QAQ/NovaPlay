import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// 独立播放进程与窗口之间的桥。
///
/// 播放窗口是一个独立进程（main() 通过 `--player <json>` 启动），
/// 使用 window_manager 控制该进程自己的窗口：改名、关闭。
class PlayerWindowBridge {
  /// 当前进程是否是独立播放进程（由 main() 根据启动参数设置）。
  static bool isPlayerWindow = false;

  static Future<void> setTitle(String title) async {
    if (!isPlayerWindow) return;
    try {
      await windowManager.setTitle(title);
    } catch (e) {
      debugPrint('设置播放窗口标题失败: $e');
    }
  }

  static Future<void> close() async {
    if (!isPlayerWindow) return;
    try {
      await windowManager.close();
    } catch (e) {
      debugPrint('关闭播放窗口失败: $e');
    }
  }
}
