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
/// - 标量设置走 `set`/`remove`；历史/收藏/搜索历史走**语义操作**
///   （`history.upsert` 等），由主进程在最新状态上合并，避免客户端用
///   启动时的旧缓存拼出整份列表覆盖新数据；
/// - 主进程写入后广播变更，界面据此刷新；
/// - 主进程不可用时，播放器把操作写入本地日志文件（journal），
///   下次主进程启动时回放，绝不直接写整份 SharedPreferences。
///
/// **主窗口重启**：主窗口每次启动都会监听新的随机端口，并把
/// 「端口 + 进程 pid + 会话 token」原子写入端点文件
/// `<应用支持目录>/bridge_endpoint.json`。播放器每次请求前重新读取该文件，
/// 携带会话 token 连接；token 不匹配（连到旧主进程/旧端点）或连接失败时
/// 重新读取端点重试，因此旧播放器能自动发现并接上新主窗口。
///
/// 传输使用「一行 JSON 一个请求/响应」的极简协议（不依赖 HttpClient，
/// 便于在 Flutter 测试环境里直接使用）。
class PrefsBridgeServer {
  PrefsBridgeServer._(
    this._serverSocket,
    this._onSet,
    this._onRemove,
    this._onOps,
    this.session,
    this._endpointFile,
  ) {
    _serverSocket.listen(_handleConnection);
  }

  static PrefsBridgeServer? _instance;

  /// 当前进程是否已在提供服务（主窗口进程）。
  static PrefsBridgeServer? get instance => _instance;

  static Future<PrefsBridgeServer?> start({
    required Future<void> Function(String key, Object? value) onSet,
    required Future<void> Function(String key) onRemove,
    required Future<Iterable<String>> Function(List<Map<String, dynamic>> ops)
    onOps,
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
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .then((line) async {
          Map<String, Object?> reply;
          try {
            reply = await _handleLine(line);
          } catch (e) {
            debugPrint('配置桥处理请求失败: $e');
            reply = {'ok': false, 'error': '$e'};
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
          debugPrint('配置桥连接失败: $e');
          socket.destroy();
        });
  }

  Future<Map<String, Object?>> _handleLine(String line) async {
    final payload = jsonDecode(line);
    if (payload is! Map) {
      return {'ok': false, 'error': 'bad payload'};
    }

    // 会话校验：客户端可能拿着重启前的旧端点，必须让它在主进程换代后
    // 重新读取端点文件，而不是把数据写进错误的主进程。
    final incomingSession = payload['session'];
    if (incomingSession is String && incomingSession != session) {
      return {'ok': false, 'error': 'session_mismatch'};
    }

    final changed = <String>{};
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
    }

    if (changed.isNotEmpty && !_changes.isClosed) {
      _changes.add(changed);
    }
    return {'ok': true, 'changed': changed.toList(), 'session': session};
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
/// 启动时拿到主进程的端口作为兜底；之后每次请求都会重新读取端点文件，
/// 支持主窗口重启后自动发现新端口。
class PrefsBridgeClient {
  PrefsBridgeClient(this.port, {this.endpointFile});

  /// 启动参数里带的主进程端口（端点文件不可用时的兜底）。
  final int port;

  /// 主窗口写入的端点文件（含端口 + 会话 token）。
  final File? endpointFile;

  Future<bool> set(Map<String, Object?> values) async {
    final reply = await _request({'set': values});
    return reply != null && reply['ok'] == true;
  }

  Future<bool> remove(List<String> keys) async {
    final reply = await _request({'remove': keys});
    return reply != null && reply['ok'] == true;
  }

  Future<bool> ops(List<Map<String, dynamic>> ops) async {
    final reply = await _request({'ops': ops});
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
    // 两次尝试：第一次（重新）读取端点 → 连接失败/会话不匹配时，
    // 再读一次端点（主窗口可能刚重启）后重试。
    for (var attempt = 0; attempt < 2; attempt++) {
      final endpoint = await _readEndpoint();
      final targetPort = endpoint?.port ?? port;
      final body = Map<String, Object?>.from(payload);
      if (endpoint != null) body['session'] = endpoint.session;
      final reply = await _rawRequest(targetPort, body);
      if (reply == null) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          continue;
        }
        return null;
      }
      if (reply['error'] == 'session_mismatch') {
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
