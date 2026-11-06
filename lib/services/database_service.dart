import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/history_item.dart';
import '../models/video_model.dart';
import 'prefs_bridge.dart';
import 'scraper/source_config.dart';

/// 本地持久化 + 跨进程写入协调。
///
/// 跨进程写入模型（R1/R6）：
/// - 主窗口进程是唯一持久化写入方；
/// - 播放器进程产生的所有写入先进入**有序队列**（同一客户端按 seq 顺序），
///   再批量发送；主进程确认应用了哪些 opId 后才从队列删除（响应丢失可重试）；
/// - 队列持久化到离线日志，主进程不可用时继续积压，下次启动回放；
/// - 历史合并有明确的版本规则：同一作品以 `watchedAt` 较新者为准，
///   删除会记录 tombstone，早于删除时间的旧记录不能复活；
/// - 配置桥请求通过 [validateRemotePayload] 做允许键/操作/结构/大小校验。
class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;

  DatabaseService._internal();

  static const int _historyLimit = 100;
  static const int _searchHistoryLimit = 20;
  static const String _favoritesKey = 'favorites_v1';
  static const String _favoritesTombstonesKey = 'favorites_tombstones_v1';
  static const String _favoritesVersionsKey = 'favorites_versions_v1';
  static const String _historyKey = 'history_v1';
  static const String _historyTombstonesKey = 'history_tombstones_v1';
  static const String _historyClearAtKey = 'history_clear_at_v1';
  static const String _danmakuMappingKey = 'danmaku_episode_map_v1';
  static const String _bangumiMappingKey = 'bangumi_subject_map_v1';
  static const String _searchHistoryKey = 'search_history';
  static const String _sourcesKey = 'sources_v1';
  static const String _activeSourceKey = 'active_source_v1';

  /// 配置桥允许写入的标量键（其余键只允许主进程本地写）。
  static const Set<String> allowedScalarKeys = {
    'theme_mode',
    'auto_play',
    'danmaku_enabled',
    'default_quality',
    'playback_speed',
    'danmaku_app_id',
    'danmaku_app_secret',
    'danmaku_opacity',
    'danmaku_font_size',
    'danmaku_area',
    'sources_v1',
    'active_source_v1',
    'search_history',
  };

  /// 配置桥允许的语义操作。
  static const Set<String> allowedOpTypes = {
    'history.upsert',
    'history.remove',
    'history.clear',
    'favorites.add',
    'favorites.remove',
    'search.upsert',
    'search.clear',
    'danmaku.map.set',
    'danmaku.map.remove',
    'set',
    'remove',
  };

  static const int maxOpsPerRequest = 200;
  static const int maxScalarKeysPerRequest = 100;

  /// 客户端单批上限：低于服务端 200 条 / 512KB 的限制，留出协议包装余量。
  static const int maxOpsPerBatch = 100;
  static const int maxBatchBytes = 400 * 1024;

  /// 单条操作序列化后超过该大小时无法送达（服务端 512KB 上限），
  /// 转入待恢复队列，避免永久阻塞后续写入。
  static const int maxSingleOpBytes = 460 * 1024;

  // 可空：未 init 时所有读取返回默认值，避免测试或早于初始化的访问崩溃
  SharedPreferences? _prefs;

  /// 播放器进程使用：把写操作转发给主进程，避免两个进程互相覆盖配置。
  PrefsBridgeClient? _bridge;

  /// 有序待提交操作（带 opId/clientId/seq/at）。
  final List<Map<String, dynamic>> _pendingOps = [];

  /// 当前进程客户端标识（用于日志/诊断与跨客户端冲突说明）。
  final String _clientId = _newId();
  int _seq = 0;

  /// 积压操作的离线日志目录（真实进程使用应用支持目录；测试可注入临时目录）。
  Directory? _journalDir;
  Timer? _retryTimer;
  bool _flushing = false;

  /// 串行化 journal 快照写入，避免并发保存互相覆盖/删除。
  Future<void> _journalChain = Future<void>.value();

  /// 已应用过的 opId（主进程内去重，用于响应丢失后的安全重试）。
  final Set<String> _appliedOpIds = <String>{};
  final List<String> _appliedOpOrder = <String>[];
  static const int _appliedOpIdLimit = 1000;

  /// 单条超过协议上限、无法经配置桥发送的操作。
  /// 不静默丢弃：写入独立的 `.oversized.json` 日志，主进程启动回放时本地应用。
  final List<Map<String, dynamic>> _oversizedOps = [];
  String? _lastSyncError;

  /// 播放器进程内已确认/已提交的弹幕映射（含删除哨兵 null）。
  /// 通过配置桥写入后本进程立即读取到一致结果；主进程仍是唯一落盘方。
  final Map<String, Map<String, dynamic>?> _danmakuMappingCache = {};

  @visibleForTesting
  List<Map<String, dynamic>> get oversizedOps =>
      List<Map<String, dynamic>>.unmodifiable(_oversizedOps);

  @visibleForTesting
  String? get lastSyncError => _lastSyncError;

  static String _newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

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

  @visibleForTesting
  Future<void> flushPendingOpsForTest() => _flushPendingOps();

  // ---------------------------------------------------------------------------
  // 配置桥协议校验（R6）
  // ---------------------------------------------------------------------------

  /// 校验来自播放器的请求；返回 null 表示通过，否则返回错误码。
  /// 校验失败时服务端会整批拒绝，不执行任何写入。
  String? validateRemotePayload(Map<String, dynamic> payload) {
    final setValues = payload['set'];
    if (setValues != null) {
      if (setValues is! Map || setValues.length > maxScalarKeysPerRequest) {
        return 'bad_set';
      }
      for (final entry in setValues.entries) {
        final key = entry.key;
        if (key is! String || !allowedScalarKeys.contains(key)) {
          return 'unsupported_key';
        }
        if (!_isValidScalarForKey(key, entry.value)) return 'bad_value';
      }
    }
    final removedKeys = payload['remove'];
    if (removedKeys != null) {
      if (removedKeys is! List ||
          removedKeys.length > maxScalarKeysPerRequest) {
        return 'bad_remove';
      }
      for (final key in removedKeys) {
        if (key is! String || !allowedScalarKeys.contains(key)) {
          return 'unsupported_key';
        }
      }
    }
    final ops = payload['ops'];
    if (ops != null) {
      if (ops is! List || ops.length > maxOpsPerRequest) return 'bad_ops';
      for (final op in ops) {
        final error = _validateOp(op);
        if (error != null) return error;
      }
    }
    return null;
  }

  String? _validateOp(Object? raw) {
    if (raw is! Map) return 'bad_op';
    final type = raw['op'];
    if (type is! String || !allowedOpTypes.contains(type)) {
      return 'unsupported_op';
    }
    switch (type) {
      case 'history.upsert':
        return _isValidHistoryItem(raw['item']) ? null : 'bad_item';
      case 'history.remove':
        return raw['videoId'] is String ? null : 'bad_item';
      case 'history.clear':
        return null;
      case 'favorites.add':
        return _isValidFavoriteItem(raw['item']) ? null : 'bad_item';
      case 'favorites.remove':
        return raw['videoId'] is String ? null : 'bad_item';
      case 'search.upsert':
        return raw['query'] is String ? null : 'bad_item';
      case 'search.clear':
        return null;
      case 'danmaku.map.set':
        final key = raw['key'];
        final value = raw['value'];
        if (key is! String || key.trim().isEmpty) return 'bad_item';
        if (!_isValidDanmakuMappingValue(value)) return 'bad_item';
        return null;
      case 'danmaku.map.remove':
        return raw['key'] is String ? null : 'bad_item';
      case 'set':
        final key = raw['key'];
        if (key is! String || !allowedScalarKeys.contains(key)) {
          return 'unsupported_key';
        }
        return _isValidScalarForKey(key, raw['value']) ? null : 'bad_value';
      case 'remove':
        final key = raw['key'];
        if (key is! String || !allowedScalarKeys.contains(key)) {
          return 'unsupported_key';
        }
        return null;
      default:
        return 'unsupported_op';
    }
  }

  /// 完整校验历史条目：字段类型必须与 [HistoryItem.fromJson] 的强制转换一致。
  bool _isValidHistoryItem(Object? raw) {
    if (raw is! Map) return false;
    if (raw['videoId'] is! String || raw['title'] is! String) return false;
    final watchedAt = raw['watchedAt'];
    if (watchedAt is! String || DateTime.tryParse(watchedAt) == null) {
      return false;
    }
    if (raw['cover'] != null && raw['cover'] is! String) return false;
    // sourceId 会被 HistoryItem.fromJson 强转为 String?，必须先校验类型。
    if (raw['sourceId'] != null && raw['sourceId'] is! String) return false;
    final episodeIndex = raw['episodeIndex'];
    if (episodeIndex != null && episodeIndex is! int) return false;
    final positionMs = raw['positionMs'];
    if (positionMs != null && positionMs is! int) return false;
    final durationMs = raw['durationMs'];
    if (durationMs != null && durationMs is! int) return false;
    final episodes = raw['episodes'];
    if (episodes != null) {
      if (episodes is! List) return false;
      for (final episode in episodes) {
        if (!_isValidEpisode(episode)) return false;
      }
    }
    return true;
  }

  bool _isValidEpisode(Object? raw) {
    if (raw is! Map) return false;
    if (raw['id'] is! String ||
        raw['title'] is! String ||
        raw['url'] is! String) {
      return false;
    }
    final index = raw['index'];
    if (index != null && index is! int) return false;
    final playUrl = raw['playUrl'];
    if (playUrl != null && playUrl is! String) return false;
    final urlIsMediaPlayback = raw['urlIsMediaPlayback'];
    if (urlIsMediaPlayback != null && urlIsMediaPlayback is! bool) {
      return false;
    }
    return true;
  }

  /// 收藏是 VideoModel 快照，必须能通过 [VideoModel.fromJson]。
  bool _isValidFavoriteItem(Object? raw) {
    if (raw is! Map) return false;
    if (raw['id'] is! String || raw['title'] is! String) return false;
    final rating = raw['rating'];
    if (rating != null && rating is! num) return false;
    for (final key in [
      'cover',
      'description',
      'year',
      'genre',
      'source',
      'sourceUrl',
    ]) {
      if (raw[key] != null && raw[key] is! String) return false;
    }
    final updatedAt = raw['updatedAt'];
    if (updatedAt != null &&
        (updatedAt is! String || DateTime.tryParse(updatedAt) == null)) {
      return false;
    }
    final episodes = raw['episodes'];
    if (episodes != null) {
      if (episodes is! List) return false;
      for (final episode in episodes) {
        if (!_isValidEpisode(episode)) return false;
      }
    }
    return true;
  }

  /// 弹幕手动关联值必须能被播放器安全读取：
  /// `episodeId` 必须是整数（播放器只认整数），标题字段必须是字符串。
  bool _isValidDanmakuMappingValue(Object? raw) {
    if (raw is! Map) return false;
    if (raw['episodeId'] is! int) return false;
    for (final key in ['animeTitle', 'episodeTitle']) {
      if (raw[key] != null && raw[key] is! String) return false;
    }
    final updatedAt = raw['updatedAt'];
    if (updatedAt != null &&
        (updatedAt is! String || DateTime.tryParse(updatedAt) == null)) {
      return false;
    }
    return true;
  }

  /// 每个标量键都有明确类型；类型不符时整批拒绝，不能等到读取时抛异常。
  bool _isValidScalarForKey(String key, Object? value) {
    switch (key) {
      case 'theme_mode':
        return value is int;
      case 'auto_play':
      case 'danmaku_enabled':
        return value is bool;
      case 'default_quality':
      case 'danmaku_app_id':
      case 'danmaku_app_secret':
      case 'sources_v1':
      case 'active_source_v1':
        return value is String;
      case 'playback_speed':
      case 'danmaku_opacity':
      case 'danmaku_font_size':
      case 'danmaku_area':
        return value is num;
      case 'search_history':
        return value is List && value.every((item) => item is String);
      default:
        return false;
    }
  }

  // ---------------------------------------------------------------------------
  // 主进程应用远程操作
  // ---------------------------------------------------------------------------

  /// 主进程应用远程标量设置。
  Future<void> applyRemoteSet(String key, Object? value) async {
    final prefs = _store;
    if (prefs == null) return;
    // double 键接受 num（JSON 整数会解析成 int），统一按 double 写入，
    // 保证 getPlaybackSpeed/getDanmakuOpacity 等 getter 不会类型错误。
    if (value is num &&
        (key == 'playback_speed' ||
            key == 'danmaku_opacity' ||
            key == 'danmaku_font_size' ||
            key == 'danmaku_area')) {
      await prefs.setDouble(key, value.toDouble());
      return;
    }
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

  /// 主进程应用来自播放器进程的语义操作（按顺序，返回变更的键）。
  Future<Iterable<String>> applyRemoteOps(
    List<Map<String, dynamic>> ops,
  ) async {
    final changed = <String>{};
    // 先整体预检：任何一条非法都不写入（服务器入口也会调用，这里防直接
    // 调用/回放漏网，并避免“前半批已落盘、后半批抛异常”）。
    for (final op in ops) {
      final error = _validateOp(op);
      if (error != null) {
        debugPrint('拒绝非法远程操作批次 $error: $op');
        return changed;
      }
    }
    await _enqueueWrite(() async {
      for (final op in ops) {
        final opId = op['opId'];
        final hasOpId = opId is String && opId.isNotEmpty;
        if (hasOpId && _appliedOpIds.contains(opId)) {
          // 重传与原请求共用写入队列。只有成功的操作才能跳过重复执行。
          final key = _keyForOp(op);
          if (key != null) changed.add(key);
          continue;
        }
        final key = await _applyOpLocal(op);
        if (hasOpId) _rememberOpId(opId);
        if (key != null) changed.add(key);
      }
    });
    return changed;
  }

  String? _keyForOp(Map<String, dynamic> op) {
    final type = op['op'];
    switch (type) {
      case 'history.upsert':
      case 'history.remove':
      case 'history.clear':
        return _historyKey;
      case 'favorites.add':
      case 'favorites.remove':
        return _favoritesKey;
      case 'search.upsert':
      case 'search.clear':
        return _searchHistoryKey;
      case 'set':
      case 'remove':
        final key = op['key'];
        return key is String ? key : null;
      default:
        return null;
    }
  }

  void _rememberOpId(String opId) {
    if (!_appliedOpIds.add(opId)) return;
    _appliedOpOrder.add(opId);
    while (_appliedOpOrder.length > _appliedOpIdLimit) {
      _appliedOpIds.remove(_appliedOpOrder.removeAt(0));
    }
  }

  Future<String?> _applyOpLocal(Map<String, dynamic> op) async {
    final type = op['op'];
    final at = DateTime.tryParse('${op['at'] ?? ''}');
    switch (type) {
      case 'history.upsert':
        final raw = op['item'];
        if (raw is! Map) return null;
        final item = HistoryItem.fromJson(raw.cast<String, dynamic>());
        await _saveHistoryLocal(item);
        return _historyKey;
      case 'history.remove':
        final videoId = op['videoId'];
        if (videoId is! String) return null;
        await _removeHistoryLocal(videoId, at: at);
        return _historyKey;
      case 'history.clear':
        await _clearHistoryLocal(at: at);
        return _historyKey;
      case 'favorites.add':
        final raw = op['item'];
        if (raw is! Map) return null;
        final video = VideoModel.fromJson(raw.cast<String, dynamic>());
        await _addFavoriteLocal(video, at: at);
        return _favoritesKey;
      case 'favorites.remove':
        final videoId = op['videoId'];
        if (videoId is! String) return null;
        await _removeFavoriteLocal(videoId, at: at);
        return _favoritesKey;
      case 'search.upsert':
        final query = op['query'];
        if (query is! String) return null;
        await _addSearchHistoryLocal(query);
        return _searchHistoryKey;
      case 'search.clear':
        await _clearSearchHistoryLocal();
        return _searchHistoryKey;
      case 'danmaku.map.set':
        final key = op['key'];
        final value = op['value'];
        if (key is! String || value is! Map) return null;
        await _setDanmakuMappingLocal(key, value.cast<String, dynamic>());
        return _danmakuMappingKey;
      case 'danmaku.map.remove':
        final key = op['key'];
        if (key is! String) return null;
        await _removeDanmakuMappingLocal(key);
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
        return null;
    }
  }

  /// 把其他进程（播放器）离线积压的操作合并回本地存储（主进程启动时调用）。
  ///
  /// 回放是幂等的：历史按版本规则合并、收藏按 id 去重、标量设置为覆盖写。
  /// 先抢占文件所有权（重命名为 `.processing`）再读取，避免与仍在运行的
  /// 播放器写入新快照时互相删除。
  Future<void> flushPendingJournals() async {
    final dir = await _resolveJournalDir();
    if (dir == null) return;
    try {
      final entries = await dir.list().toList();
      for (final entity in entries) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        final isProcessing = name.endsWith('.processing');
        if (!name.endsWith('.json') && !isProcessing) continue;

        File source = entity;
        if (!isProcessing) {
          // 客户端可能正在写入同一文件：重命名失败就留给下一轮启动处理。
          final claimed = File('${entity.path}.processing');
          try {
            source = await entity.rename(claimed.path);
          } catch (e) {
            debugPrint('跳过正在写入的离线日志 ${entity.path}: $e');
            continue;
          }
        }

        try {
          final raw = await source.readAsString();
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            for (final op in decoded) {
              if (op is! Map) continue;
              final typed = op.cast<String, dynamic>();
              final error = _validateOp(typed);
              if (error != null) {
                debugPrint('跳过非法离线操作 $error: $typed');
                continue;
              }
              await _enqueueWrite(() async {
                await _applyOpLocal(typed);
              });
            }
          }
          await source.delete();
        } catch (e) {
          // 保留 .processing 文件，下次启动继续重试，避免丢数据。
          debugPrint('回放离线操作失败（保留待重试） ${source.path}: $e');
        }
      }
    } catch (e) {
      debugPrint('扫描离线操作日志失败: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // 队列 / 离线日志
  // ---------------------------------------------------------------------------

  /// 把操作加入有序队列并尝试提交。
  ///
  /// 新操作只有在队列为空时才会被单独发送；有积压时统一按 seq 顺序补交，
  /// 避免「新记录先到、旧记录后到」把新进度覆盖回去。
  Future<void> _enqueueOp(Map<String, dynamic> op) async {
    final enriched = <String, dynamic>{
      ...op,
      'opId': _newId(),
      'clientId': _clientId,
      'seq': ++_seq,
      'at': DateTime.now().toIso8601String(),
    };
    _pendingOps.add(enriched);
    await _persistJournal();
    await _flushPendingOps();
  }

  /// 按条数与序列化字节数切批，避免超过服务端 200 条 / 512KB 的单请求上限。
  List<Map<String, dynamic>> _takeNextBatch() {
    final batch = <Map<String, dynamic>>[];
    var bytes = 0;
    for (final op in _pendingOps) {
      final size = utf8.encode(jsonEncode(op)).length + 16;
      if (batch.isNotEmpty &&
          (batch.length >= maxOpsPerBatch || bytes + size > maxBatchBytes)) {
        break;
      }
      batch.add(op);
      bytes += size;
    }
    return batch;
  }

  Future<void> _flushPendingOps() async {
    final bridge = _bridge;
    if (bridge == null || _flushing || _pendingOps.isEmpty) return;
    _flushing = true;
    try {
      if (!await _quarantineOversizedOps()) return;
      while (_pendingOps.isNotEmpty) {
        final batch = _takeNextBatch();
        if (batch.isEmpty) break;
        final applied = await bridge.applyOps(batch);
        if (applied == null) break;
        final before = _pendingOps.length;
        // 只删除服务端已确认的批次，请求期间新加入的操作保留。
        _pendingOps.removeWhere((op) => applied.contains(op['opId']));
        await _persistJournal();
        if (_pendingOps.isEmpty || _pendingOps.length == before) break;
      }
    } finally {
      _flushing = false;
    }
  }

  int _serializedOpBytes(Map<String, dynamic> op) =>
      utf8.encode(jsonEncode(op)).length + 32;

  /// 把超过单条协议上限的操作移出正常队列并持久化，避免队首操作永久阻塞。
  Future<bool> _quarantineOversizedOps() async {
    final oversized =
        _pendingOps
            .where((op) => _serializedOpBytes(op) > maxSingleOpBytes)
            .toSet();
    if (oversized.isEmpty) return true;
    try {
      // 普通日志保留这些操作，直到超限日志的替代副本成功落盘。
      await _writeOversizedSnapshot([..._oversizedOps, ...oversized]);
    } on FileSystemException catch (error) {
      _lastSyncError = '保存超大操作日志失败，将重试: $error';
      debugPrint(_lastSyncError);
      return false;
    }
    _oversizedOps.addAll(oversized);
    _pendingOps.removeWhere(oversized.contains);
    _lastSyncError =
        '有 ${oversized.length} 条操作超过单条协议上限'
        '（${(maxSingleOpBytes / 1024).round()}KB），已转入待恢复队列；'
        '主进程启动时会本地回放，不影响其余写入';
    debugPrint(_lastSyncError);
    await _persistJournal();
    return true;
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

  /// 串行化 journal 快照写入：并发调用不会共用临时文件或互相删除。
  Future<void> _persistJournal() {
    final next = _journalChain.then((_) => _writeJournalSnapshot());
    _journalChain = next.catchError((Object e) {
      debugPrint('保存离线操作失败: $e');
    });
    return _journalChain;
  }

  Future<void> _writeOversizedSnapshot(
    List<Map<String, dynamic>> snapshot,
  ) async {
    final dir = await _resolveJournalDir();
    if (dir == null) {
      throw FileSystemException('无法获取离线日志目录');
    }
    final file = File(
      '${dir.path}${Platform.pathSeparator}pending_ops.$pid.oversized.json',
    );
    await _replaceJournal(file, snapshot);
  }

  Future<void> _replaceJournal(
    File file,
    List<Map<String, dynamic>> snapshot,
  ) async {
    final temporary = File('${file.path}.${_newId()}.tmp');
    try {
      await temporary.writeAsString(jsonEncode(snapshot), flush: true);
      await temporary.rename(file.path);
    } on FileSystemException {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> _writeJournalSnapshot() async {
    final dir = await _resolveJournalDir();
    if (dir == null) return;
    final file = _journalFile();
    if (file == null) return;
    final snapshot = List<Map<String, dynamic>>.from(_pendingOps);
    try {
      if (snapshot.isEmpty) {
        if (await file.exists()) await file.delete();
        return;
      }
      await _replaceJournal(file, snapshot);
    } catch (e) {
      debugPrint('保存离线操作失败: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // 历史版本规则（tombstone）
  // ---------------------------------------------------------------------------

  Map<String, DateTime> _loadTombstones() {
    final raw = _store?.getString(_historyTombstonesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, DateTime>{};
      decoded.forEach((key, value) {
        final parsed = DateTime.tryParse('$value');
        if (parsed != null) result['$key'] = parsed;
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveTombstones(Map<String, DateTime> tombstones) async {
    final prefs = _store;
    if (prefs == null) return;
    // 只保留最近 500 条，避免无限增长。
    final entries =
        tombstones.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final pruned = Map<String, DateTime>.fromEntries(
      entries.take(500).map((e) => MapEntry(e.key, e.value)),
    );
    await prefs.setString(
      _historyTombstonesKey,
      jsonEncode(
        pruned.map((key, value) => MapEntry(key, value.toIso8601String())),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 写入路由：播放器进程走有序队列，主进程/测试直接写本地
  // ---------------------------------------------------------------------------

  Future<void> _setBool(String key, bool value) => _writeScalar(key, value);
  Future<void> _setInt(String key, int value) => _writeScalar(key, value);
  Future<void> _setDouble(String key, double value) => _writeScalar(key, value);
  Future<void> _setString(String key, String value) => _writeScalar(key, value);

  Future<void> _writeScalar(String key, Object value) async {
    final bridge = _bridge;
    if (bridge != null) {
      await _enqueueOp({'op': 'set', 'key': key, 'value': value});
      return;
    }
    final prefs = _store;
    if (prefs == null) return;
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    }
  }

  Future<void> _enqueueWrite(Future<void> Function() op) {
    // 主进程本地写入串行化，避免读-改-写并发。
    if (!identical(_writeZone, Zone.current)) {
      _writeZone = Zone.current;
      _writeChain = Future<void>.value();
    }
    final next = _writeChain.then((_) => op());
    _writeChain = next.catchError((_) {});
    return next;
  }

  Future<void> _writeChain = Future<void>.value();
  Zone? _writeZone;

  // ---------------------------------------------------------------------------
  // 搜索历史
  // ---------------------------------------------------------------------------

  List<String> getSearchHistory() {
    return _store?.getStringList(_searchHistoryKey) ?? [];
  }

  Future<void> addSearchHistory(String query) async {
    if (_bridge != null) {
      await _enqueueOp({'op': 'search.upsert', 'query': query});
      return;
    }
    await _enqueueWrite(() => _addSearchHistoryLocal(query));
  }

  Future<void> _addSearchHistoryLocal(String query) async {
    final prefs = _store;
    if (prefs == null) return;
    final history = getSearchHistory();
    history.remove(query);
    history.insert(0, query);
    if (history.length > _searchHistoryLimit) history.removeLast();
    await prefs.setStringList(_searchHistoryKey, history);
  }

  Future<void> clearSearchHistory() async {
    if (_bridge != null) {
      await _enqueueOp({'op': 'search.clear'});
      return;
    }
    await _enqueueWrite(_clearSearchHistoryLocal);
  }

  Future<void> _clearSearchHistoryLocal() async {
    await _store?.remove(_searchHistoryKey);
  }

  // ---------------------------------------------------------------------------
  // 收藏
  // ---------------------------------------------------------------------------

  List<VideoModel> getFavorites() {
    return _decodeSnapshots(_store?.getString(_favoritesKey));
  }

  bool isFavorite(String videoId) {
    return getFavorites().any((v) => v.id == videoId);
  }

  Future<void> addFavorite(VideoModel video) async {
    if (_bridge != null) {
      await _enqueueOp({'op': 'favorites.add', 'item': video.toJson()});
      return;
    }
    await _enqueueWrite(() => _addFavoriteLocal(video));
  }

  Future<void> _addFavoriteLocal(VideoModel video, {DateTime? at}) async {
    final prefs = _store;
    if (prefs == null) return;
    final opAt = at ?? DateTime.now();

    // 统一版本规则（add/remove 双向）：
    // - 该收藏最近一次已应用操作时间晚于本次操作时，本次是旧操作，忽略；
    // - remove tombstone 晚于/等于本次 add 时，旧 add 不能复活收藏。
    final versions = _loadFavoriteVersions();
    final lastVersion = versions[video.id];
    if (lastVersion != null && opAt.isBefore(lastVersion)) {
      return;
    }
    final tombstones = _loadFavoriteTombstones();
    final deletedAt = tombstones[video.id];
    if (deletedAt != null && !opAt.isAfter(deletedAt)) {
      return;
    }

    final favorites = getFavorites()..removeWhere((v) => v.id == video.id);
    favorites.insert(0, video);
    await prefs.setString(
      _favoritesKey,
      jsonEncode(favorites.map((v) => v.toJson()).toList()),
    );
    versions[video.id] = opAt;
    await _saveFavoriteVersions(versions);
    if (deletedAt != null) {
      tombstones.remove(video.id);
      await _saveFavoriteTombstones(tombstones);
    }
  }

  Future<void> removeFavorite(String videoId) async {
    if (_bridge != null) {
      await _enqueueOp({'op': 'favorites.remove', 'videoId': videoId});
      return;
    }
    await _enqueueWrite(() => _removeFavoriteLocal(videoId));
  }

  Future<void> _removeFavoriteLocal(String videoId, {DateTime? at}) async {
    final prefs = _store;
    if (prefs == null) return;
    final opAt = at ?? DateTime.now();

    // 旧 remove（晚到/重试/重启回放）不能删除之后重新收藏的记录。
    final versions = _loadFavoriteVersions();
    final lastVersion = versions[videoId];
    if (lastVersion != null && opAt.isBefore(lastVersion)) {
      return;
    }

    final favorites = getFavorites()..removeWhere((v) => v.id == videoId);
    await prefs.setString(
      _favoritesKey,
      jsonEncode(favorites.map((v) => v.toJson()).toList()),
    );
    versions[videoId] = opAt;
    await _saveFavoriteVersions(versions);

    final tombstones = _loadFavoriteTombstones();
    final previous = tombstones[videoId];
    if (previous == null || opAt.isAfter(previous)) {
      tombstones[videoId] = opAt;
      await _saveFavoriteTombstones(tombstones);
    }
  }

  Map<String, DateTime> _loadFavoriteVersions() {
    return _loadTimestampMap(_favoritesVersionsKey);
  }

  Future<void> _saveFavoriteVersions(Map<String, DateTime> versions) async {
    // 活跃收藏的最后版本必须保留：否则版本被 500 条上限淘汰后，重启回放
    // 旧 remove 会因查不到版本而误删较新的重新收藏。
    final activeIds = getFavorites().map((video) => video.id).toSet();
    await _saveTimestampMap(
      _favoritesVersionsKey,
      versions,
      keepIds: activeIds,
    );
  }

  Map<String, DateTime> _loadFavoriteTombstones() {
    return _loadTimestampMap(_favoritesTombstonesKey);
  }

  Future<void> _saveFavoriteTombstones(Map<String, DateTime> tombstones) async {
    // 只保存每个已取消作品的最后版本。旧客户端可能在任意时间回放，
    // 因此删除版本要保留到同一作品被更新的操作重新收藏为止。
    await _store?.setString(
      _favoritesTombstonesKey,
      jsonEncode(
        tombstones.map((id, at) => MapEntry(id, at.toIso8601String())),
      ),
    );
  }

  Map<String, DateTime> _loadTimestampMap(String key) {
    final raw = _store?.getString(key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, DateTime>{};
      decoded.forEach((entryKey, value) {
        final parsed = DateTime.tryParse('$value');
        if (parsed != null) result['$entryKey'] = parsed;
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveTimestampMap(
    String key,
    Map<String, DateTime> values, {
    Set<String> keepIds = const <String>{},
  }) async {
    final prefs = _store;
    if (prefs == null) return;
    final entries =
        values.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    // 先无条件保留调用方指定的 id（如当前活跃收藏），再按最近时间补足上限。
    final selected = <String, DateTime>{};
    for (final id in keepIds) {
      final value = values[id];
      if (value != null) selected[id] = value;
    }
    for (final entry in entries) {
      if (selected.length >= 500) break;
      selected.putIfAbsent(entry.key, () => entry.value);
    }
    await prefs.setString(
      key,
      jsonEncode(
        selected.map(
          (entryKey, value) => MapEntry(entryKey, value.toIso8601String()),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 观看历史（版本规则：watchedAt 较新者胜出；删除用 tombstone 防复活）
  // ---------------------------------------------------------------------------

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

  HistoryItem? _findHistory(String videoId) {
    for (final item in getHistory()) {
      if (item.videoId == videoId) return item;
    }
    return null;
  }

  Future<void> saveHistory(HistoryItem item) async {
    if (_bridge != null) {
      await _enqueueOp({'op': 'history.upsert', 'item': item.toJson()});
      return;
    }
    await _enqueueWrite(() => _saveHistoryLocal(item));
  }

  Future<void> _saveHistoryLocal(HistoryItem item) async {
    final prefs = _store;
    if (prefs == null) return;
    // 集合级清空水位：早于清空时间的旧离线记录不能重新出现。
    final clearedAt = _loadHistoryClearAt();
    if (clearedAt != null && !item.watchedAt.isAfter(clearedAt)) {
      return;
    }
    final existing = _findHistory(item.videoId);
    // 版本规则：已有记录比本次操作新时忽略（防止旧日志/晚到操作回退进度）。
    if (existing != null && existing.watchedAt.isAfter(item.watchedAt)) {
      return;
    }
    final tombstones = _loadTombstones();
    final deletedAt = tombstones[item.videoId];
    // 删除后又有更新的观看才允许恢复；早于删除时间的旧记录不复活。
    if (deletedAt != null && !item.watchedAt.isAfter(deletedAt)) {
      return;
    }
    final history = getHistory()..removeWhere((h) => h.videoId == item.videoId);
    history.insert(0, item);
    if (history.length > _historyLimit) history.removeLast();
    await prefs.setString(
      _historyKey,
      jsonEncode(history.map((h) => h.toJson()).toList()),
    );
    if (deletedAt != null) {
      tombstones.remove(item.videoId);
      await _saveTombstones(tombstones);
    }
  }

  Future<void> removeHistory(String videoId) async {
    if (_bridge != null) {
      await _enqueueOp({'op': 'history.remove', 'videoId': videoId});
      return;
    }
    await _enqueueWrite(() => _removeHistoryLocal(videoId));
  }

  Future<void> _removeHistoryLocal(String videoId, {DateTime? at}) async {
    final prefs = _store;
    if (prefs == null) return;
    final deletedAt = at ?? DateTime.now();
    final existing = _findHistory(videoId);
    // 已应用过的旧删除重试：不能撤销比删除时间更新的观看记录。
    if (existing != null && existing.watchedAt.isAfter(deletedAt)) {
      return;
    }
    final history = getHistory()..removeWhere((h) => h.videoId == videoId);
    await prefs.setString(
      _historyKey,
      jsonEncode(history.map((h) => h.toJson()).toList()),
    );
    final tombstones = _loadTombstones();
    final previous = tombstones[videoId];
    if (previous == null || deletedAt.isAfter(previous)) {
      tombstones[videoId] = deletedAt;
      await _saveTombstones(tombstones);
    }
  }

  Future<void> clearHistory() async {
    if (_bridge != null) {
      await _enqueueOp({'op': 'history.clear'});
      return;
    }
    await _enqueueWrite(_clearHistoryLocal);
  }

  Future<void> _clearHistoryLocal({DateTime? at}) async {
    final prefs = _store;
    if (prefs == null) return;
    // 记录集合级清空时间：尚未送达的旧离线记录（不在 existing 里）也不能复活。
    final clearedAt = at ?? DateTime.now();
    final previousClear = _loadHistoryClearAt();
    final effectiveClear =
        previousClear == null || clearedAt.isAfter(previousClear)
            ? clearedAt
            : previousClear;
    if (previousClear == null || clearedAt.isAfter(previousClear)) {
      await _saveHistoryClearAt(clearedAt);
    }

    // 旧 clear 重放/回放时只能删除早于它（或同一时刻）的记录；
    // 清空之后产生的较新观看必须保留，否则重启回放会撤销新观看。
    final existing = getHistory();
    final kept = <HistoryItem>[];
    final tombstones = _loadTombstones();
    for (final item in existing) {
      if (item.watchedAt.isAfter(clearedAt)) {
        kept.add(item);
        continue;
      }
      final previous = tombstones[item.videoId];
      if (previous == null || clearedAt.isAfter(previous)) {
        tombstones[item.videoId] = clearedAt;
      }
    }
    if (kept.isEmpty) {
      await prefs.remove(_historyKey);
    } else {
      await prefs.setString(
        _historyKey,
        jsonEncode(kept.map((h) => h.toJson()).toList()),
      );
    }
    await _saveTombstones(tombstones);
    // 让水位保持单调：旧 clear 不能把已有清空水位下调。
    assert(!effectiveClear.isBefore(clearedAt));
  }

  DateTime? _loadHistoryClearAt() {
    final raw = _store?.getString(_historyClearAtKey);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> _saveHistoryClearAt(DateTime value) async {
    await _store?.setString(_historyClearAtKey, value.toIso8601String());
  }

  // 弹幕手动匹配映射：由播放器经配置桥以语义操作写入；主进程唯一落盘。
  // 键 = 作品 ID + 稳定剧集身份，剧集重排/媒体地址轮换后仍能命中同一集。
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
      await _enqueueOp({
        'op': 'danmaku.map.set',
        'key': entryKey,
        'value': value,
      });
      return;
    }
    await _enqueueWrite(() => _setDanmakuMappingLocal(entryKey, value));
  }

  Future<void> removeDanmakuMapping(String entryKey) async {
    // null 哨兵：清除后立即读不到旧关联，即使启动时的 prefs 快照里还有。
    _danmakuMappingCache[entryKey] = null;
    if (_bridge != null) {
      await _enqueueOp({'op': 'danmaku.map.remove', 'key': entryKey});
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

  // Bangumi 手动纠正映射：完整视频 ID → subjectId（详情页使用，本地持久化）。
  // 不使用标题作为键：同名旧作/重制版会共用关联。
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
  // ---------------------------------------------------------------------------
  // 设置
  // ---------------------------------------------------------------------------

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
      _setInt(_themeModeKey, value.clamp(0, 2));

  bool getAutoPlay() => _store?.getBool('auto_play') ?? true;
  Future<void> setAutoPlay(bool value) => _setBool('auto_play', value);

  bool getDanmakuEnabled() => _store?.getBool('danmaku_enabled') ?? true;
  Future<void> setDanmakuEnabled(bool value) =>
      _setBool('danmaku_enabled', value);

  String getDefaultQuality() => _store?.getString('default_quality') ?? '1080P';
  Future<void> setDefaultQuality(String value) =>
      _setString('default_quality', value);

  double getPlaybackSpeed() => _store?.getDouble('playback_speed') ?? 1.0;
  Future<void> setPlaybackSpeed(double value) =>
      _setDouble('playback_speed', value);

  // 弹幕：dandanplay 开放 API 凭据 + 显示样式
  String getDanmakuAppId() => _store?.getString('danmaku_app_id') ?? '';
  Future<void> setDanmakuAppId(String value) =>
      _setString('danmaku_app_id', value);

  String getDanmakuAppSecret() => _store?.getString('danmaku_app_secret') ?? '';
  Future<void> setDanmakuAppSecret(String value) =>
      _setString('danmaku_app_secret', value);

  double getDanmakuOpacity() => _store?.getDouble('danmaku_opacity') ?? 1.0;
  Future<void> setDanmakuOpacity(double value) =>
      _setDouble('danmaku_opacity', value.clamp(0.2, 1.0));

  double getDanmakuFontSize() => _store?.getDouble('danmaku_font_size') ?? 16.0;
  Future<void> setDanmakuFontSize(double value) =>
      _setDouble('danmaku_font_size', value.clamp(10.0, 32.0));

  double getDanmakuArea() => _store?.getDouble('danmaku_area') ?? 1.0;
  Future<void> setDanmakuArea(double value) =>
      _setDouble('danmaku_area', value.clamp(0.2, 1.0));

  // ---------------------------------------------------------------------------
  // 数据源
  // ---------------------------------------------------------------------------

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
    return _setString(_sourcesKey, json);
  }

  String? getActiveSourceId() => _store?.getString(_activeSourceKey);

  Future<void> setActiveSourceId(String id) => _setString(_activeSourceKey, id);

  // ---------------------------------------------------------------------------
  // 测试辅助 / 通用
  // ---------------------------------------------------------------------------

  /// 从磁盘重新加载（兜底）：跨进程一致性由配置桥负责。
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
    _oversizedOps.clear();
    _lastSyncError = null;
    _prefs = null;
    _writeChain = Future<void>.value();
    _writeZone = null;
    _journalChain = Future<void>.value();
    _appliedOpIds.clear();
    _appliedOpOrder.clear();
  }

  SharedPreferences? get _store => _prefs;

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
