import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/theme.dart';
import 'core/config/routes.dart';
import 'providers/favorites_provider.dart';
import 'providers/history_provider.dart';
import 'providers/theme_provider.dart';
import 'services/database_service.dart';
import 'services/prefs_bridge.dart';

class NovaPlayApp extends ConsumerStatefulWidget {
  const NovaPlayApp({super.key});

  @override
  ConsumerState<NovaPlayApp> createState() => _NovaPlayAppState();
}

class _NovaPlayAppState extends ConsumerState<NovaPlayApp>
    with WidgetsBindingObserver {
  StreamSubscription<Set<String>>? _bridgeSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 播放器进程通过配置桥写入历史/收藏后，主界面即时刷新。
    _bridgeSubscription = PrefsBridgeServer.instance?.changes.listen((keys) {
      if (!mounted) return;
      if (keys.contains('history_v1')) ref.invalidate(historyProvider);
      if (keys.contains('favorites_v1')) ref.invalidate(favoritesProvider);
    });
  }

  @override
  void dispose() {
    _bridgeSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 播放窗口是独立进程，它写入的历史/收藏对主进程不可见。
    // 主窗口重新获得焦点时从磁盘重载，避免显示旧数据。
    if (state == AppLifecycleState.resumed) {
      unawaited(_reloadPersistedState());
    }
  }

  Future<void> _reloadPersistedState() async {
    await DatabaseService().reloadFromDisk();
    if (!mounted) return;
    ref.invalidate(historyProvider);
    ref.invalidate(favoritesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'NovaPlay',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: router,
    );
  }
}
