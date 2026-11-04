import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
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
    // 端点文件让旧播放器在主窗口重启后自动发现新端口。
    final bridgePort = arguments['bridgePort'];
    if (bridgePort is int && bridgePort > 0) {
      final endpointFile = await _bridgeEndpointFile();
      DatabaseService().attachBridge(
        PrefsBridgeClient(bridgePort, endpointFile: endpointFile),
      );
    }

    await windowManager.ensureInitialized();
    await windowManager.setTitle('NovaPlay 播放器');
    await windowManager.setSize(const Size(1280, 720));
    await windowManager.center();

    runApp(PlayerWindowApp(arguments: arguments));
    return;
  }

  // 主窗口进程是唯一持久化写入方：
  // 1) 先回放播放器进程离线积压的操作（主窗口关闭期间产生）；
  // 2) 再启动配置桥，接收运行中的播放器进程发来的标量设置/语义操作；
  // 3) 配置桥启动后会把新端点写入端点文件，旧播放器重试时据此重连。
  final endpointFile = await _bridgeEndpointFile();
  await DatabaseService().flushPendingJournals();
  await PrefsBridgeServer.start(
    onSet: (key, value) => DatabaseService().applyRemoteSet(key, value),
    onRemove: (key) => DatabaseService().applyRemoteSet(key, null),
    onOps: (ops) => DatabaseService().applyRemoteOps(ops),
    endpointFile: endpointFile,
  );

  runApp(const ProviderScope(child: NovaPlayApp()));
}

/// 主窗口与播放器进程共用的配置桥端点文件路径。
Future<File?> _bridgeEndpointFile() async {
  try {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}${Platform.pathSeparator}bridge_endpoint.json');
  } catch (e) {
    debugPrint('获取应用数据目录失败，配置桥将只使用固定端口: $e');
    return null;
  }
}
