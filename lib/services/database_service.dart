import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/history_item.dart';
import '../models/video_model.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;

  DatabaseService._internal();

  static const int _historyLimit = 100;
  static const int _searchHistoryLimit = 20;
  static const String _favoritesKey = 'favorites_v1';
  static const String _historyKey = 'history_v1';
  static const String _searchHistoryKey = 'search_history';

  // 可空：未 init 时所有读取返回默认值，避免测试或早于初始化的访问崩溃
  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// 仅测试用：丢弃缓存的 prefs 实例，配合 setMockInitialValues 重新初始化
  @visibleForTesting
  void resetForTest() {
    _prefs = null;
  }

  SharedPreferences? get _store => _prefs;

  // Search History
  List<String> getSearchHistory() {
    return _store?.getStringList(_searchHistoryKey) ?? [];
  }

  Future<void> addSearchHistory(String query) async {
    final prefs = _store;
    if (prefs == null) return;
    final history = getSearchHistory();
    history.remove(query);
    history.insert(0, query);
    if (history.length > _searchHistoryLimit) {
      history.removeLast();
    }
    await prefs.setStringList(_searchHistoryKey, history);
  }

  Future<void> clearSearchHistory() async {
    await _store?.remove(_searchHistoryKey);
  }

  // Favorites（存 VideoModel 快照，收藏页无需回源即可展示）
  List<VideoModel> getFavorites() {
    return _decodeSnapshots(_store?.getString(_favoritesKey));
  }

  bool isFavorite(String videoId) {
    return getFavorites().any((v) => v.id == videoId);
  }

  Future<void> addFavorite(VideoModel video) async {
    final prefs = _store;
    if (prefs == null) return;
    final favorites = getFavorites()
      ..removeWhere((v) => v.id == video.id);
    favorites.insert(0, video);
    await _writeFavorites(prefs, favorites);
  }

  Future<void> removeFavorite(String videoId) async {
    final prefs = _store;
    if (prefs == null) return;
    final favorites = getFavorites()
      ..removeWhere((v) => v.id == videoId);
    await _writeFavorites(prefs, favorites);
  }

  Future<void> _writeFavorites(
    SharedPreferences prefs,
    List<VideoModel> favorites,
  ) async {
    await prefs.setString(
      _favoritesKey,
      jsonEncode(favorites.map((v) => v.toJson()).toList()),
    );
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

  Future<void> saveHistory(HistoryItem item) async {
    final prefs = _store;
    if (prefs == null) return;
    final history = getHistory()
      ..removeWhere((h) => h.videoId == item.videoId);
    history.insert(0, item);
    if (history.length > _historyLimit) {
      history.removeLast();
    }
    await prefs.setString(
      _historyKey,
      jsonEncode(history.map((h) => h.toJson()).toList()),
    );
  }

  Future<void> removeHistory(String videoId) async {
    final prefs = _store;
    if (prefs == null) return;
    final history = getHistory()
      ..removeWhere((h) => h.videoId == videoId);
    await prefs.setString(
      _historyKey,
      jsonEncode(history.map((h) => h.toJson()).toList()),
    );
  }

  Future<void> clearHistory() async {
    await _store?.remove(_historyKey);
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
