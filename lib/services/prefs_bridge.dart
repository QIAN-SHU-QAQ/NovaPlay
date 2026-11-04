import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 跨进程配置桥。
///
/// 播放窗口是独立进程，它写入的观看进度/倍速等如果直接写
/// SharedPreferences，会和主进程各写整份配置互相覆盖（Windows 的
/// legacy 实现没有跨进程一致性）。因此约定：
///
/// - **主窗口进程是唯一持久化写入方**；
/// - 播放器进程把要写的键值通过本机 127.0.0.1 TCP 交给主进程；
/// - 主进程写入后广播变更，界面据此刷新。
///
/// 传输使用「一行 JSON 一个请求/响应」的极简协议（不依赖 HttpClient，
/// 便于在 Flutter 测试环境里直接使用）。
/// 主窗口关闭时播放器会回退到直接写本地（此时没有第二个写者，不会冲突）。
class PrefsBridgeServer {
  PrefsBridgeServer._(this._serverSocket, this._onSet, this._onRemove) {
    _serverSocket.listen(_handleConnection);
  }

  static PrefsBridgeServer? _instance;

  /// 当前进程是否已在提供服务（主窗口进程）。
  static PrefsBridgeServer? get instance => _instance;

  static Future<PrefsBridgeServer?> start({
    required Future<void> Function(String key, Object? value) onSet,
    required Future<void> Function(String key) onRemove,
  }) async {
    final existing = _instance;
    if (existing != null) return existing;
    try {
      final serverSocket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final bridge = PrefsBridgeServer._(serverSocket, onSet, onRemove);
      _instance = bridge;
      debugPrint('跨进程配置桥已启动: 127.0.0.1:${bridge.port}');
      return bridge;
    } catch (e) {
      debugPrint('启动跨进程配置桥失败: $e');
      return null;
    }
  }

  final ServerSocket _serverSocket;
  final Future<void> Function(String key, Object? value) _onSet;
  final Future<void> Function(String key) _onRemove;
  final StreamController<Set<String>> _changes =
      StreamController<Set<String>>.broadcast();

  int get port => _serverSocket.port;

  /// 主进程应用完远程写入后广播变更的键名。
  Stream<Set<String>> get changes => _changes.stream;

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
    if (changed.isNotEmpty && !_changes.isClosed) {
      _changes.add(changed);
    }
    return {'ok': true};
  }

  Future<void> dispose() async {
    if (identical(_instance, this)) _instance = null;
    await _changes.close();
    await _serverSocket.close();
  }
}

/// 播放器进程用来把配置写入转发给主进程的客户端。
class PrefsBridgeClient {
  PrefsBridgeClient(this.port);

  final int port;

  Future<bool> set(Map<String, Object?> values) async {
    final reply = await _request({'set': values});
    return reply != null && reply['ok'] == true;
  }

  Future<bool> remove(List<String> keys) async {
    final reply = await _request({'remove': keys});
    return reply != null && reply['ok'] == true;
  }

  /// 每次请求使用独立连接，这里无需释放资源；保留方法便于调用方统一管理生命周期。
  void dispose() {}

  Future<Map<String, dynamic>?> _request(Map<String, Object?> payload) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
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
}
