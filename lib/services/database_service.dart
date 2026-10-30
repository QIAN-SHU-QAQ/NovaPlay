import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/history_item.dart';
import '../models/video_model.dart';
import 'scraper/source_config.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;

  DatabaseService._internal();

  static const int _historyLimit = 100;
  static const int _searchHistoryLimit = 20;
  static const String _favoritesKey = 'favorites_v1';
  static const String _historyKey = 'history_v1';
  static const String _searchHistoryKey = 'search_history';
  static const String _sourcesKey = 'sources_v1';
  static const String _activeSourceKey = 'active_source_v1';

  // 可空：未 init 时所有读取返回默认值，避免测试或早于初始化的访问崩溃
  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// 仅测试用：丢弃缓存的 prefs 实例，并清空写队列（避免跨测试挂起的 Future）。
  @visibleForTesting
  void resetForTest() {
    _prefs = null;
    _writeChain = Future<void>.value();
    _writeZone = null;
  }

  SharedPreferences? get _store => _prefs;

  /// 串行化写操作：避免"读-改-写"并发竞争（播放器定时写 + 退出时写会同时发生）。
  Future<void> _writeChain = Future<void>.value();
  Zone? _writeZone;

  Future<void> _enqueueWrite(Future<void> Function() op) {
    // Future 的回调在创建它的 Zone 里调度。widget 测试的每个用例运行在独立的
    // fake-async Zone 中，跨用例链式等待上一个 Zone 的 Future 会永远挂起，
    // 因此只在同一 Zone 内串行化，换 Zone 时重新开始一条链。
    if (!identical(_writeZone, Zone.current)) {
      _writeZone = Zone.current;
      _writeChain = Future<void>.value();
    }
    final next = _writeChain.then((_) => op());
    // 单次写失败不应永久阻塞后续写
    _writeChain = next.catchError((_) {});
    return next;
  }

  // Search History
  List<String> getSearchHistory() {
    return _store?.getStringList(_searchHistoryKey) ?? [];
  }

  Future<void> addSearchHistory(String query) {
    return _enqueueWrite(() async {
      final prefs = _store;
      if (prefs == null) return;
      final history = getSearchHistory();
      history.remove(query);
      history.insert(0, query);
      if (history.length > _searchHistoryLimit) {
        history.removeLast();
      }
      await prefs.setStringList(_searchHistoryKey, history);
    });
  }

  Future<void> clearSearchHistory() {
    return _enqueueWrite(() async {
      await _store?.remove(_searchHistoryKey);
    });
  }

  // Favorites（存 VideoModel 快照，收藏页无需回源即可展示）
  List<VideoModel> getFavorites() {
    return _decodeSnapshots(_store?.getString(_favoritesKey));
  }

  bool isFavorite(String videoId) {
    return getFavorites().any((v) => v.id == videoId);
  }

  Future<void> addFavorite(VideoModel video) {
    return _enqueueWrite(() async {
      final prefs = _store;
      if (prefs == null) return;
      final favorites = getFavorites()..removeWhere((v) => v.id == video.id);
      favorites.insert(0, video);
      await prefs.setString(
        _favoritesKey,
        jsonEncode(favorites.map((v) => v.toJson()).toList()),
      );
    });
  }

  Future<void> removeFavorite(String videoId) {
    return _enqueueWrite(() async {
      final prefs = _store;
      if (prefs == null) return;
      final favorites = getFavorites()..removeWhere((v) => v.id == videoId);
      await prefs.setString(
        _favoritesKey,
        jsonEncode(favorites.map((v) => v.toJson()).toList()),
      );
    });
  }

  // Watch History（按 videoId upsert，最新的排最前，封顶 _historyLimit）
  List<HistoryItem> getHistory() {
    final raw = _store?.getString(_historyKey);
    if (raw == null) return [];
    final items = <HistoryItem>[];
    try {
      final list = jsonDecode(raw) as List;
      items.addAll(
        list.map((e) => HistoryItem.fromJson(e as Map<String, dynamic>)),
      );
    } catch (_) {
      return [];
    }
    items.sort((a, b) => b.watchedAt.compareTo(a.watchedAt));
    return items;
  }

  Future<void> saveHistory(HistoryItem item) {
    return _enqueueWrite(() async {
      final prefs = _store;
      if (prefs == null) return;
      final history =
          getHistory()..removeWhere((h) => h.videoId == item.videoId);
      history.insert(0, item);
      if (history.length > _historyLimit) {
        history.removeLast();
      }
      await prefs.setString(
        _historyKey,
        jsonEncode(history.map((h) => h.toJson()).toList()),
      );
    });
  }

  Future<void> removeHistory(String videoId) {
    return _enqueueWrite(() async {
      final prefs = _store;
      if (prefs == null) return;
      final history = getHistory()..removeWhere((h) => h.videoId == videoId);
      await prefs.setString(
        _historyKey,
        jsonEncode(history.map((h) => h.toJson()).toList()),
      );
    });
  }

  Future<void> clearHistory() {
    return _enqueueWrite(() async {
      await _store?.remove(_historyKey);
    });
  }

  // Settings
  // ThemeMode 三态：0 跟随系统 / 1 浅色 / 2 深色。
  // 兼容旧 dark_mode 布尔键：老数据 true 视为深色，未写过则跟随系统。
  static const String _themeModeKey = 'theme_mode';

  int getThemeMode() {
    final prefs = _store;
    if (prefs == null) return 0;
    final mode = prefs.getInt(_themeModeKey);
    if (mode != null) return mode.clamp(0, 2);
    return prefs.getBool('dark_mode') == true ? 2 : 0;
  }

  Future<void> setThemeMode(int value) =>
      _store?.setInt(_themeModeKey, value.clamp(0, 2)) ?? Future.value();

  bool getAutoPlay() => _store?.getBool('auto_play') ?? true;
  Future<void> setAutoPlay(bool value) =>
      _store?.setBool('auto_play', value) ?? Future.value();

  bool getDanmakuEnabled() => _store?.getBool('danmaku_enabled') ?? true;
  Future<void> setDanmakuEnabled(bool value) =>
      _store?.setBool('danmaku_enabled', value) ?? Future.value();

  String getDefaultQuality() => _store?.getString('default_quality') ?? '1080P';
  Future<void> setDefaultQuality(String value) =>
      _store?.setString('default_quality', value) ?? Future.value();

  double getPlaybackSpeed() => _store?.getDouble('playback_speed') ?? 1.0;
  Future<void> setPlaybackSpeed(double value) =>
      _store?.setDouble('playback_speed', value) ?? Future.value();

  // Data Sources（用户可配置的 maccms 源）
  List<SourceConfig> getSources() {
    final raw = _store?.getString(_sourcesKey);
    if (raw == null || raw.isEmpty) return SourceConfig.defaults();
    try {
      final list =
          (jsonDecode(raw) as List)
              .map((e) => SourceConfig.fromJson(e as Map<String, dynamic>))
              .where((s) => s.baseUrl.isNotEmpty)
              .toList();
      return list.isEmpty ? SourceConfig.defaults() : list;
    } catch (_) {
      return SourceConfig.defaults();
    }
  }

  Future<void> saveSources(List<SourceConfig> sources) {
    return _enqueueWrite(() async {
      await _store?.setString(
        _sourcesKey,
        jsonEncode(sources.map((s) => s.toJson()).toList()),
      );
    });
  }

  String? getActiveSourceId() => _store?.getString(_activeSourceKey);

  Future<void> setActiveSourceId(String id) {
    return _enqueueWrite(() async {
      await _store?.setString(_activeSourceKey, id);
    });
  }

  List<VideoModel> _decodeSnapshots(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => VideoModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
