import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/theme.dart';
import 'core/config/routes.dart';
import 'providers/favorites_provider.dart';
import 'providers/history_provider.dart';
import 'providers/theme_provider.dart';
import 'services/database_service.dart';

class NovaPlayApp extends ConsumerStatefulWidget {
  const NovaPlayApp({super.key});

  @override
  ConsumerState<NovaPlayApp> createState() => _NovaPlayAppState();
}

class _NovaPlayAppState extends ConsumerState<NovaPlayApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
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
