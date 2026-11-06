import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// 跨进程配置桥。
///
/// 播放窗口是独立进程，它写入的观看进度/收藏等如果直接写
/// SharedPreferences，会和主进程各写整份配置互相覆盖（Windows 的
/// legacy 实现没有跨进程一致性）。因此约定：
///
/// - **主窗口进程是唯一持久化写入方**；
/// - 播放器进程把写入通过本机 127.0.0.1 TCP 交给主进程；
/// - 标量设置与历史/收藏/搜索历史统一以「语义操作」`ops` 发送，
///   由主进程在最新状态上按版本规则合并；
/// - 主进程写入后广播变更，界面据此刷新；
/// - 主进程不可用时，播放器把操作写入本地日志（journal），
///   下次主进程启动时回放，绝不直接写整份 SharedPreferences。
///
/// **协议约束**（R6）：所有请求必须携带当前主进程会话的 session token；
/// 缺失/空值/类型错误/旧 token 一律拒绝且不执行写入；请求需要先通过
/// 调用方的 payload 校验（允许的键、操作、结构与大小），否则整批拒绝。
///
/// **主窗口重启**（端点发现）：主窗口每次启动生成新的 session，并把
/// `pid/port/session/startedAt` 原子写入 `<应用支持目录>/bridge_endpoint.json`；
/// 播放器每次请求前重新读取端点文件，连接失败或会话不匹配时重读端点重试，
/// 因此旧播放器能自动发现并接上重启后的主窗口。
class PrefsBridgeServer {
  PrefsBridgeServer._(
    this._serverSocket,
    this._onSet,
    this._onRemove,
    this._onOps,
    this._validatePayload,
    this.session,
    this._endpointFile,
  ) {
    _serverSocket.listen(_handleConnection);
  }

  static PrefsBridgeServer? _instance;

  /// 当前进程是否已在提供服务（主窗口进程）。
  static PrefsBridgeServer? get instance => _instance;

  /// 单行请求上限：超过直接拒绝，避免异常客户端占满内存。
  static const int maxPayloadBytes = 512 * 1024;

  /// 没有完整请求连接的超时时间。
  static const Duration connectionTimeout = Duration(seconds: 5);

  static Future<PrefsBridgeServer?> start({
    required Future<void> Function(String key, Object? value) onSet,
    required Future<void> Function(String key) onRemove,
    required Future<Iterable<String>> Function(List<Map<String, dynamic>> ops)
    onOps,
    required Future<String?> Function(Map<String, dynamic> payload)
    validatePayload,
    File? endpointFile,
  }) async {
    final existing = _instance;
    if (existing != null) return existing;
    try {
      final serverSocket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final bridge = PrefsBridgeServer._(
        serverSocket,
        onSet,
        onRemove,
        onOps,
        validatePayload,
        _newSessionToken(),
        endpointFile,
      );
      _instance = bridge;
      await bridge._writeEndpoint();
      debugPrint('跨进程配置桥已启动: 127.0.0.1:${bridge.port}');
      return bridge;
    } catch (e) {
      debugPrint('启动跨进程配置桥失败: $e');
      return null;
    }
  }

  static String _newSessionToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  final ServerSocket _serverSocket;
  final Future<void> Function(String key, Object? value) _onSet;
  final Future<void> Function(String key) _onRemove;
  final Future<Iterable<String>> Function(List<Map<String, dynamic>> ops)
  _onOps;
  final Future<String?> Function(Map<String, dynamic> payload) _validatePayload;

  /// 本次主进程会话的随机 token：请求必须携带相同的值。
  final String session;
  final File? _endpointFile;
  final StreamController<Set<String>> _changes =
      StreamController<Set<String>>.broadcast();

  int get port => _serverSocket.port;

  /// 主进程应用完远程写入后广播变更的键名。
  Stream<Set<String>> get changes => _changes.stream;

  Future<void> _writeEndpoint() async {
    final file = _endpointFile;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'pid': pid,
          'port': port,
          'session': session,
          'startedAt': DateTime.now().toIso8601String(),
        }),
      );
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('写入配置桥端点文件失败: $e');
    }
  }

  void _handleConnection(Socket socket) {
    // 连接超时保护：客户端未在时限内发送完整一行请求就关闭。
    final idleTimer = Timer(connectionTimeout, () {
      debugPrint('配置桥连接超时，关闭连接');
      socket.destroy();
    });
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(
          connectionTimeout,
          onTimeout: () {
            socket.destroy();
            throw TimeoutException('配置桥请求超时');
          },
        )
        .then((line) async {
          idleTimer.cancel();
          Map<String, Object?> reply;
          try {
            reply = await _handleLine(line);
          } catch (e) {
            debugPrint('配置桥处理请求失败: $e');
            reply = {'ok': false, 'error': 'internal_error'};
          }
          try {
            socket.write(jsonEncode(reply));
            socket.write('\n');
            await socket.flush();
          } finally {
            socket.destroy();
          }
        })
        .catchError((Object e) {
          idleTimer.cancel();
          debugPrint('配置桥连接失败: $e');
          socket.destroy();
        });
  }

  Future<Map<String, Object?>> _handleLine(String line) async {
    if (line.length > maxPayloadBytes) {
      return {'ok': false, 'error': 'payload_too_large'};
    }
    final decoded = jsonDecode(line);
    if (decoded is! Map) {
      return {'ok': false, 'error': 'bad_payload'};
    }
    final payload = decoded.cast<String, dynamic>();

    // 强制会话校验：缺失、空值、类型错误、旧 token 均拒绝。
    final incomingSession = payload['session'];
    if (incomingSession is! String ||
        incomingSession.isEmpty ||
        incomingSession != session) {
      return {'ok': false, 'error': 'session_required'};
    }

    // 结构/允许键/允许操作/大小校验；失败时整批拒绝，不执行任何写入。
    final validationError = await _validatePayload(payload);
    if (validationError != null) {
      return {'ok': false, 'error': validationError};
    }

    final changed = <String>{};
    final appliedIds = <String>[];
    final setValues = payload['set'];
    if (setValues is Map) {
      for (final entry in setValues.entries) {
        final key = entry.key.toString();
        await _onSet(key, entry.value);
        changed.add(key);
      }
    }
    final removedKeys = payload['remove'];
    if (removedKeys is List) {
      for (final rawKey in removedKeys) {
        final key = rawKey.toString();
        await _onRemove(key);
        changed.add(key);
      }
    }
    final ops = payload['ops'];
    if (ops is List && ops.isNotEmpty) {
      final normalized = ops
          .whereType<Map>()
          .map((op) => op.cast<String, dynamic>())
          .toList(growable: false);
      changed.addAll(await _onOps(normalized));
      for (final op in normalized) {
        final id = op['opId'];
        if (id is String && id.isNotEmpty) appliedIds.add(id);
      }
    }

    if (changed.isNotEmpty && !_changes.isClosed) {
      _changes.add(changed);
    }
    return {
      'ok': true,
      'changed': changed.toList(),
      'appliedIds': appliedIds,
      'session': session,
    };
  }

  Future<void> dispose() async {
    if (identical(_instance, this)) _instance = null;
    await _changes.close();
    await _serverSocket.close();
  }
}

class _BridgeEndpoint {
  const _BridgeEndpoint({required this.port, required this.session});

  final int port;
  final String session;
}

/// 播放器进程用来把配置写入转发给主进程的客户端。
///
/// 每次请求前重新读取端点文件（端口 + session），支持主窗口重启后自动发现
/// 新端口。端点文件存在但缺失/损坏时直接进入离线队列，不使用固定端口兜底，
/// 避免绕过会话校验。
class PrefsBridgeClient {
  PrefsBridgeClient(this.port, {this.endpointFile});

  /// 启动参数里带的主进程端口（仅在未提供 [endpointFile] 的测试场景使用）。
  final int port;

  /// 主窗口写入的端点文件（含端口 + 会话 token）。
  final File? endpointFile;

  /// 发送语义操作；成功返回主进程确认应用的 opId 集合，失败返回 null。
  Future<Set<String>?> applyOps(List<Map<String, dynamic>> ops) async {
    final reply = await _request({'ops': ops});
    if (reply == null || reply['ok'] != true) return null;
    final applied = reply['appliedIds'];
    if (applied is List) {
      return applied.whereType<String>().toSet();
    }
    // 兼容旧服务端：没有 appliedIds 时视为全部应用。
    return ops.map((op) => op['opId']).whereType<String>().toSet();
  }

  /// 发送标量设置（保留给协议兼容/测试；正式写入统一走 [applyOps]）。
  Future<bool> set(Map<String, Object?> values) async {
    final reply = await _request({'set': values});
    return reply != null && reply['ok'] == true;
  }

  Future<bool> remove(List<String> keys) async {
    final reply = await _request({'remove': keys});
    return reply != null && reply['ok'] == true;
  }

  Future<_BridgeEndpoint?> _readEndpoint() async {
    final file = endpointFile;
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final portValue = decoded['port'];
      final sessionValue = decoded['session'];
      if (portValue is! int || sessionValue is! String) return null;
      return _BridgeEndpoint(port: portValue, session: sessionValue);
    } catch (e) {
      debugPrint('读取配置桥端点失败: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _request(Map<String, Object?> payload) async {
    // 两次尝试：第一次读取端点 → 连接失败/会话不匹配时重读端点再试一次。
    for (var attempt = 0; attempt < 2; attempt++) {
      final endpoint = await _readEndpoint();
      if (endpointFile != null && endpoint == null) {
        // 端点缺失/损坏：进入离线队列，不使用固定端口兜底。
        return null;
      }
      final targetPort = endpoint?.port ?? port;
      final body = <String, Object?>{
        ...payload,
        if (endpoint != null) 'session': endpoint.session,
      };
      final reply = await _rawRequest(targetPort, body);
      if (reply == null) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          continue;
        }
        return null;
      }
      final error = reply['error'];
      if (error == 'session_mismatch' || error == 'session_required') {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          continue;
        }
        return null;
      }
      return reply;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _rawRequest(
    int targetPort,
    Map<String, Object?> payload,
  ) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        targetPort,
        timeout: const Duration(milliseconds: 800),
      );
      socket.write(jsonEncode(payload));
      socket.write('\n');
      await socket.flush();
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 3));
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
      return null;
    } catch (e) {
      debugPrint('转发配置到主进程失败: $e');
      return null;
    } finally {
      socket?.destroy();
    }
  }

  /// 每次请求使用独立连接，这里无需释放资源；保留方法便于调用方统一管理生命周期。
  void dispose() {}
}
