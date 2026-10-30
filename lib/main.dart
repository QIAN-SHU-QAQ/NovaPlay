import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/window/player_window_bridge.dart';
import 'features/player/player_window.dart';
import 'services/database_service.dart';

/// 主窗口与独立播放窗口共用同一个入口。
///
/// desktop_multi_window 创建子窗口时会把入口参数设置为
/// `["multi_window", windowId, windowArgument]`，据此区分并渲染播放器。
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await DatabaseService().init();

  final isPlayerWindow = args.length >= 3 && args.first == 'multi_window';
  if (isPlayerWindow) {
    PlayerWindowBridge.isPlayerWindow = true;
    var arguments = <String, dynamic>{};
    try {
      final raw = args[2];
      if (raw.isNotEmpty) {
        arguments = jsonDecode(raw) as Map<String, dynamic>;
      }
    } catch (_) {
      // 参数损坏时仍然开窗口，播放页显示错误而不是静默退出。
    }
    runApp(PlayerWindowApp(arguments: arguments));
    return;
  }

  runApp(const ProviderScope(child: NovaPlayApp()));
}
