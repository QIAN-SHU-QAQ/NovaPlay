import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/history_item.dart';
import '../models/video_model.dart';
import 'prefs_bridge.dart';
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
  static const String _danmakuMappingKey = 'danmaku_episode_map_v1';
  static const String _bangumiMappingKey = 'bangumi_subject_map_v1';
  static const String _sourcesKey = 'sources_v1';
  static const String _activeSourceKey = 'active_source_v1';

  // 可空：未 init 时所有读取返回默认值，避免测试或早于初始化的访问崩溃
  SharedPreferences? _prefs;

  /// 播放器进程使用：把写操作转发给主进程，避免两个进程互相覆盖配置。
  PrefsBridgeClient? _bridge;

  /// 主进程不可用时积压的语义操作（按顺序重试，直到成功）。
  final List<Map<String, dynamic>> _pendingOps = [];

  /// 积压操作的离线日志目录（真实进程使用应用支持目录；测试可注入临时目录）。
  Directory? _journalDir;
  Timer? _retryTimer;
  bool _flushing = false;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// 播放器进程启动时接入主进程的配置桥。
  ///
  /// [journalDir] 仅供测试注入；正式运行时使用应用支持目录下的 `pending_ops/`。
  void attachBridge(PrefsBridgeClient client, {Directory? journalDir}) {
    _bridge = client;
    if (journalDir != null) _journalDir = journalDir;
    _retryTimer ??= Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_flushPendingOps());
    });
    unawaited(_flushPendingOps());
  }

  void detachBridge() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _bridge?.dispose();
    _bridge = null;
    _journalDir = null;
  }

  @visibleForTesting
  bool get hasBridge => _bridge != null;

  @visibleForTesting
  List<Map<String, dynamic>> get pendingOps =>
      List<Map<String, dynamic>>.unmodifiable(_pendingOps);

  @visibleForTesting
  void setJournalDirectory(Directory? dir) => _journalDir = dir;

  /// 播放器进程内已确认/已提交的弹幕映射（含删除哨兵 null）。
  ///
  /// 通过配置桥写入后本进程立即读取到一致结果；主进程仍是唯一落盘方。
  final Map<String, Map<String, dynamic>?> _danmakuMappingCache = {};

  /// 主进程应用远程写入（标量设置）。
  Future<void> applyRemoteSet(String key, Object? value) async {
    final prefs = _store;
    if (prefs == null) return;
    if (value == null) {
      await prefs.remove(key);
    } else if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    } else if (value is List) {
      await prefs.setStringList(key, value.map((e) => '$e').toList());
    } else {
      await prefs.setString(key, jsonEncode(value));
    }
  }

  /// 主进程应用来自播放器进程的语义操作。
  ///
  /// 关键点：历史/收藏等操作在主进程的**最新状态**上执行，而不是接受
  /// 客户端用旧缓存拼出的整份列表；这样多个播放器同时写也不会互相覆盖。
  Future<Iterable<String>> applyRemoteOps(
    List<Map<String, dynamic>> ops,
  ) async {
    final changed = <String>{};
    for (final op in ops) {
      final key = await _applyOpLocal(op);
      if (key != null) changed.add(key);
    }
    return changed;
  }

  Future<String?> _applyOpLocal(Map<String, dynamic> op) async {
    final type = op['op'];
    switch (type) {
      case 'history.upsert':
        final raw = op['item'];
        if (raw is! Map) return null;
        final item = HistoryItem.fromJson(raw.cast<String, dynamic>());
        await _enqueueWrite(() => _saveHistoryLocal(item));
        return _historyKey;
      case 'history.remove':
        final videoId = op['videoId'];
        if (videoId is! String) return null;
        await _enqueueWrite(() => _removeHistoryLocal(videoId));
        return _historyKey;
      case 'history.clear':
        await _enqueueWrite(_clearHistoryLocal);
        return _historyKey;
      case 'favorites.add':
        final raw = op['item'];
        if (raw is! Map) return null;
        final video = VideoModel.fromJson(raw.cast<String, dynamic>());
        await _enqueueWrite(() => _addFavoriteLocal(video));
        return _favoritesKey;
      case 'favorites.remove':
        final videoId = op['videoId'];
        if (videoId is! String) return null;
        await _enqueueWrite(() => _removeFavoriteLocal(videoId));
        return _favoritesKey;
      case 'search.upsert':
        final query = op['query'];
        if (query is! String) return null;
        await _enqueueWrite(() => _addSearchHistoryLocal(query));
        return _searchHistoryKey;
      case 'search.clear':
        await _enqueueWrite(_clearSearchHistoryLocal);
        return _searchHistoryKey;
      case 'danmaku.map.set':
        final key = op['key'];
        final value = op['value'];
        if (key is! String || value is! Map) return null;
        await _enqueueWrite(
          () => _setDanmakuMappingLocal(key, value.cast<String, dynamic>()),
        );
        return _danmakuMappingKey;
      case 'danmaku.map.remove':
        final key = op['key'];
        if (key is! String) return null;
        await _enqueueWrite(() => _removeDanmakuMappingLocal(key));
        return _danmakuMappingKey;
      case 'set':
        final key = op['key'];
        if (key is! String) return null;
        await applyRemoteSet(key, op['value']);
        return key;
      case 'remove':
        final key = op['key'];
        if (key is! String) return null;
        await applyRemoteSet(key, null);
        return key;
      default:
        debugPrint('未知的跨进程操作: $type');
        return null;
    }
  }

  /// 把其他进程（播放器）离线积压的操作合并回本地存储（主进程启动时调用）。
  ///
  /// 回放是幂等的：history 按 videoId upsert、favorites 按 id 去重、
  /// 标量设置为覆盖写，因此重复回放同一个日志不会产生重复数据。
  Future<void> flushPendingJournals() async {
    final dir = await _resolveJournalDir();
    if (dir == null) return;
    try {
      final entries = await dir.list().toList();
      for (final entity in entries) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final raw = await entity.readAsString();
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            for (final op in decoded) {
              if (op is Map) {
                await _applyOpLocal(op.cast<String, dynamic>());
              }
            }
          }
          await entity.delete();
        } catch (e) {
          debugPrint('回放离线操作失败 ${entity.path}: $e');
        }
      }
    } catch (e) {
      debugPrint('扫描离线操作日志失败: $e');
    }
  }

  Future<Directory?> _resolveJournalDir() async {
    final existing = _journalDir;
    if (existing != null) return existing;
    if (kIsWeb) return null;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(
        '${support.path}${Platform.pathSeparator}pending_ops',
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      _journalDir = dir;
      return dir;
    } catch (e) {
      debugPrint('初始化离线操作目录失败: $e');
      return null;
    }
  }

  String get _journalFileName => 'pending_ops.$pid.json';

  File? _journalFile() {
    final dir = _journalDir;
    if (dir == null) return null;
    return File('${dir.path}${Platform.pathSeparator}$_journalFileName');
  }

  Future<void> _persistJournal() async {
    final dir = await _resolveJournalDir();
    if (dir == null) return;
    final file = _journalFile();
    if (file == null) return;
    try {
      if (_pendingOps.isEmpty) {
        if (await file.exists()) await file.delete();
        return;
      }
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(_pendingOps));
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('保存离线操作失败: $e');
    }
  }

  /// 发送语义操作；失败时进入积压队列，并写入离线日志等待重试/下次启动回放。
  Future<void> _dispatchOp(Map<String, dynamic> op) async {
    final bridge = _bridge;
    if (bridge == null) return;
    if (await bridge.ops([op])) return;
    _pendingOps.add(op);
    await _persistJournal();
  }

  /// 发送标量设置；失败时同样进入积压队列。
  Future<void> _dispatchWrite(
    Map<String, Object?> setValues,
    List<String>? removeKeys,
  ) async {
    final bridge = _bridge;
    if (bridge == null) return;
    final ok =
        removeKeys != null
            ? await bridge.remove(removeKeys)
            : await bridge.set(setValues);
    if (ok) return;
    if (removeKeys != null) {
      for (final key in removeKeys) {
        _pendingOps.add({'op': 'remove', 'key': key});
      }
    } else {
      setValues.forEach((key, value) {
        _pendingOps.add({'op': 'set', 'key': key, 'value': value});
      });
    }
    await _persistJournal();
  }

  Future<void> _flushPendingOps() async {
    final bridge = _bridge;
    if (bridge == null || _flushing || _pendingOps.isEmpty) return;
    _flushing = true;
    try {
      final batch = List<Map<String, dynamic>>.from(_pendingOps);
      if (await bridge.ops(batch)) {
        _pendingOps.clear();
        await _persistJournal();
      }
    } finally {
      _flushing = false;
    }
  }

  /// 仅测试用：写入/读取积压队列后立即尝试落盘。
  @visibleForTesting
  Future<void> persistPendingOpsForTest() => _persistJournal();

  /// 从磁盘重新加载（兜底）：跨进程一致性由配置桥负责，本方法只做尽力刷新。
  ///
  /// 注意：Windows 的 legacy shared_preferences 实现中 `reload()` 仍会读
  /// 进程内缓存，不能保证拿到子进程写入。
  Future<void> reloadFromDisk() async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      await prefs.reload();
    } catch (e) {
      debugPrint('重新加载本地数据失败: $e');
    }
  }

  /// 仅测试用：丢弃缓存的 prefs 实例，清空写队列与积压操作。
  @visibleForTesting
  void resetForTest() {
    detachBridge();
    _pendingOps.clear();
    _danmakuMappingCache.clear();
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

  // 写入路由：播放器进程走主进程桥（失败进离线日志），主进程/测试直接写本地。
  Future<void> _setBool(String key, bool value) async {
    final bridge = _bridge;
    if (bridge != null) {
      await _dispatchWrite({key: value}, null);
      return;
    }
    await _store?.setBool(key, value);
  }

  Future<void> _setInt(String key, int value) async {
    final bridge = _bridge;
    if (bridge != null) {
      await _dispatchWrite({key: value}, null);
      return;
    }
    await _store?.setInt(key, value);
  }

  Future<void> _setDouble(String key, double value) async {
    final bridge = _bridge;
    if (bridge != null) {
      await _dispatchWrite({key: value}, null);
      return;
    }
    await _store?.setDouble(key, value);
  }

  Future<void> _setString(String key, String value) async {
    final bridge = _bridge;
    if (bridge != null) {
      await _dispatchWrite({key: value}, null);
      return;
    }
    await _store?.setString(key, value);
  }

  // Search History
  List<String> getSearchHistory() {
    return _store?.getStringList(_searchHistoryKey) ?? [];
  }

  Future<void> addSearchHistory(String query) {
    if (_bridge != null) {
      return _enqueueWrite(
        () => _dispatchOp({'op': 'search.upsert', 'query': query}),
      );
    }
    return _enqueueWrite(() => _addSearchHistoryLocal(query));
  }

  Future<void> _addSearchHistoryLocal(String query) async {
    if (_store == null) return;
    final history = getSearchHistory();
    history.remove(query);
    history.insert(0, query);
    if (history.length > _searchHistoryLimit) {
      history.removeLast();
    }
    await _store?.setStringList(_searchHistoryKey, history);
  }

  Future<void> clearSearchHistory() {
    if (_bridge != null) {
      return _enqueueWrite(() => _dispatchOp({'op': 'search.clear'}));
    }
    return _enqueueWrite(_clearSearchHistoryLocal);
  }

  Future<void> _clearSearchHistoryLocal() async {
    await _store?.remove(_searchHistoryKey);
  }

  // Favorites（存 VideoModel 快照，收藏页无需回源即可展示）
  List<VideoModel> getFavorites() {
    return _decodeSnapshots(_store?.getString(_favoritesKey));
  }

  bool isFavorite(String videoId) {
    return getFavorites().any((v) => v.id == videoId);
  }

  Future<void> addFavorite(VideoModel video) {
    if (_bridge != null) {
      return _enqueueWrite(
        () => _dispatchOp({'op': 'favorites.add', 'item': video.toJson()}),
      );
    }
    return _enqueueWrite(() => _addFavoriteLocal(video));
  }

  Future<void> _addFavoriteLocal(VideoModel video) async {
    if (_store == null) return;
    final favorites = getFavorites()..removeWhere((v) => v.id == video.id);
    favorites.insert(0, video);
    await _store?.setString(
      _favoritesKey,
      jsonEncode(favorites.map((v) => v.toJson()).toList()),
    );
  }

  Future<void> removeFavorite(String videoId) {
    if (_bridge != null) {
      return _enqueueWrite(
        () => _dispatchOp({'op': 'favorites.remove', 'videoId': videoId}),
      );
    }
    return _enqueueWrite(() => _removeFavoriteLocal(videoId));
  }

  Future<void> _removeFavoriteLocal(String videoId) async {
    if (_store == null) return;
    final favorites = getFavorites()..removeWhere((v) => v.id == videoId);
    await _store?.setString(
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

  Future<void> saveHistory(HistoryItem item) {
    if (_bridge != null) {
      return _enqueueWrite(
        () => _dispatchOp({'op': 'history.upsert', 'item': item.toJson()}),
      );
    }
    return _enqueueWrite(() => _saveHistoryLocal(item));
  }

  Future<void> _saveHistoryLocal(HistoryItem item) async {
    if (_store == null) return;
    final history = getHistory()..removeWhere((h) => h.videoId == item.videoId);
    history.insert(0, item);
    if (history.length > _historyLimit) {
      history.removeLast();
    }
    await _store?.setString(
      _historyKey,
      jsonEncode(history.map((h) => h.toJson()).toList()),
    );
  }

  Future<void> removeHistory(String videoId) {
    if (_bridge != null) {
      return _enqueueWrite(
        () => _dispatchOp({'op': 'history.remove', 'videoId': videoId}),
      );
    }
    return _enqueueWrite(() => _removeHistoryLocal(videoId));
  }

  Future<void> _removeHistoryLocal(String videoId) async {
    if (_store == null) return;
    final history = getHistory()..removeWhere((h) => h.videoId == videoId);
    await _store?.setString(
      _historyKey,
      jsonEncode(history.map((h) => h.toJson()).toList()),
    );
  }

  Future<void> clearHistory() {
    if (_bridge != null) {
      return _enqueueWrite(() => _dispatchOp({'op': 'history.clear'}));
    }
    return _enqueueWrite(_clearHistoryLocal);
  }

  Future<void> _clearHistoryLocal() async {
    await _store?.remove(_historyKey);
  }

  // 弹幕手动匹配映射：作品 ID + 稳定剧集身份 → 弹弹play 剧集（重启后仍生效）
  static String danmakuMappingEntryKey(String videoId, String episodeId) =>
      '$videoId||$episodeId';

  Map<String, dynamic>? getDanmakuMapping(String entryKey) {
    if (_danmakuMappingCache.containsKey(entryKey)) {
      return _danmakuMappingCache[entryKey];
    }
    final raw = _store?.getString(_danmakuMappingKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final value = decoded[entryKey];
      return value is Map ? value.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> setDanmakuMapping(
    String entryKey,
    Map<String, dynamic> value,
  ) async {
    // 先更新本进程缓存：播放器选择后立刻重新加载弹幕时能读到新关联。
    _danmakuMappingCache[entryKey] = value;
    if (_bridge != null) {
      await _enqueueWrite(
        () => _dispatchOp({
          'op': 'danmaku.map.set',
          'key': entryKey,
          'value': value,
        }),
      );
      return;
    }
    await _enqueueWrite(() => _setDanmakuMappingLocal(entryKey, value));
  }

  Future<void> removeDanmakuMapping(String entryKey) async {
    // null 哨兵：清除后本进程立即读不到旧关联，即使启动时的 prefs 快照里还有。
    _danmakuMappingCache[entryKey] = null;
    if (_bridge != null) {
      await _enqueueWrite(
        () => _dispatchOp({'op': 'danmaku.map.remove', 'key': entryKey}),
      );
      return;
    }
    await _enqueueWrite(() => _removeDanmakuMappingLocal(entryKey));
  }

  Map<String, dynamic> _loadDanmakuMappings() {
    final raw = _store?.getString(_danmakuMappingKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
    return {};
  }

  Future<void> _setDanmakuMappingLocal(
    String entryKey,
    Map<String, dynamic> value,
  ) async {
    final mappings = _loadDanmakuMappings();
    mappings[entryKey] = value;
    await _store?.setString(_danmakuMappingKey, jsonEncode(mappings));
  }

  Future<void> _removeDanmakuMappingLocal(String entryKey) async {
    final mappings = _loadDanmakuMappings();
    if (!mappings.containsKey(entryKey)) return;
    mappings.remove(entryKey);
    await _store?.setString(_danmakuMappingKey, jsonEncode(mappings));
  }

  // Bangumi 手动纠正映射：完整视频 ID → subjectId（详情页使用，本地持久化）
  //
  // 不使用标题作为键：同名旧作/重制版会共用关联。旧版本（未发布）若留下
  // 标题键数据，这里也不会回退读取，避免把一部作品的关联套到另一部。
  Map<String, dynamic>? getBangumiMapping(String videoId) {
    final raw = _store?.getString(_bangumiMappingKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final value = decoded[videoId];
      return value is Map ? value.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> setBangumiMapping(
    String videoId,
    Map<String, dynamic> value,
  ) async {
    await _enqueueWrite(() async {
      final mappings = _loadBangumiMappings();
      mappings[videoId] = value;
      await _store?.setString(_bangumiMappingKey, jsonEncode(mappings));
    });
  }

  Future<void> removeBangumiMapping(String videoId) async {
    await _enqueueWrite(() async {
      final mappings = _loadBangumiMappings();
      if (!mappings.containsKey(videoId)) return;
      mappings.remove(videoId);
      await _store?.setString(_bangumiMappingKey, jsonEncode(mappings));
    });
  }

  Map<String, dynamic> _loadBangumiMappings() {
    final raw = _store?.getString(_bangumiMappingKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
    return {};
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
      _enqueueWrite(() => _setInt(_themeModeKey, value.clamp(0, 2)));

  bool getAutoPlay() => _store?.getBool('auto_play') ?? true;
  Future<void> setAutoPlay(bool value) =>
      _enqueueWrite(() => _setBool('auto_play', value));

  bool getDanmakuEnabled() => _store?.getBool('danmaku_enabled') ?? true;
  Future<void> setDanmakuEnabled(bool value) =>
      _enqueueWrite(() => _setBool('danmaku_enabled', value));

  String getDefaultQuality() => _store?.getString('default_quality') ?? '1080P';
  Future<void> setDefaultQuality(String value) =>
      _enqueueWrite(() => _setString('default_quality', value));

  double getPlaybackSpeed() => _store?.getDouble('playback_speed') ?? 1.0;
  Future<void> setPlaybackSpeed(double value) =>
      _enqueueWrite(() => _setDouble('playback_speed', value));

  // 弹幕：dandanplay 开放 API 凭据 + 显示样式
  String getDanmakuAppId() => _store?.getString('danmaku_app_id') ?? '';
  Future<void> setDanmakuAppId(String value) =>
      _enqueueWrite(() => _setString('danmaku_app_id', value));

  String getDanmakuAppSecret() => _store?.getString('danmaku_app_secret') ?? '';
  Future<void> setDanmakuAppSecret(String value) =>
      _enqueueWrite(() => _setString('danmaku_app_secret', value));

  double getDanmakuOpacity() => _store?.getDouble('danmaku_opacity') ?? 1.0;
  Future<void> setDanmakuOpacity(double value) =>
      _enqueueWrite(() => _setDouble('danmaku_opacity', value.clamp(0.2, 1.0)));

  double getDanmakuFontSize() => _store?.getDouble('danmaku_font_size') ?? 16.0;
  Future<void> setDanmakuFontSize(double value) => _enqueueWrite(
    () => _setDouble('danmaku_font_size', value.clamp(10.0, 32.0)),
  );

  double getDanmakuArea() => _store?.getDouble('danmaku_area') ?? 1.0;
  Future<void> setDanmakuArea(double value) =>
      _enqueueWrite(() => _setDouble('danmaku_area', value.clamp(0.2, 1.0)));

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
    final json = jsonEncode(sources.map((s) => s.toJson()).toList());
    return _enqueueWrite(() => _setString(_sourcesKey, json));
  }

  String? getActiveSourceId() => _store?.getString(_activeSourceKey);

  Future<void> setActiveSourceId(String id) {
    return _enqueueWrite(() => _setString(_activeSourceKey, id));
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
