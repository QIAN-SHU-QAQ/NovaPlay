import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/window/player_window_bridge.dart';
import 'features/player/player_window.dart';
import 'services/database_service.dart';
import 'services/prefs_bridge.dart';

/// 主窗口与独立播放进程共用同一个入口。
///
/// 打开视频时主进程会启动一个新的本程序进程，并传入
/// `--player <json>`；子进程据此渲染播放器窗口。
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await DatabaseService().init();

  final playerArgIndex = args.indexOf('--player');
  if (playerArgIndex >= 0) {
    PlayerWindowBridge.isPlayerWindow = true;
    var arguments = <String, dynamic>{};
    if (playerArgIndex + 1 < args.length) {
      try {
        final raw = args[playerArgIndex + 1];
        if (raw.isNotEmpty) {
          arguments = jsonDecode(raw) as Map<String, dynamic>;
        }
      } catch (_) {
        // 参数损坏时仍然开窗口，播放页会显示错误而不是静默退出。
      }
    }

    // 配置写入统一交给主进程，避免两个进程互相覆盖整份配置。
    final bridgePort = arguments['bridgePort'];
    if (bridgePort is int && bridgePort > 0) {
      DatabaseService().attachBridge(PrefsBridgeClient(bridgePort));
    }

    await windowManager.ensureInitialized();
    await windowManager.setTitle('NovaPlay 播放器');
    await windowManager.setSize(const Size(1280, 720));
    await windowManager.center();

    runApp(PlayerWindowApp(arguments: arguments));
    return;
  }

  // 主窗口进程是唯一持久化写入方：播放器进程通过本机 HTTP 把写操作交给这里。
  await PrefsBridgeServer.start(
    onSet: (key, value) => DatabaseService().applyRemoteSet(key, value),
    onRemove: (key) => DatabaseService().applyRemoteSet(key, null),
  );

  runApp(const ProviderScope(child: NovaPlayApp()));
}
