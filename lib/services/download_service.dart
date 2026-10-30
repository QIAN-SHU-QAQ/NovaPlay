import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'm3u8/m3u8_downloader.dart';

/// 下载任务状态。
enum DownloadStatus {
  queued,
  resolving,
  downloading,
  merging,
  paused,
  completed,
  failed,
}

extension DownloadStatusX on DownloadStatus {
  String get label => switch (this) {
    DownloadStatus.queued => '排队中',
    DownloadStatus.resolving => '解析中',
    DownloadStatus.downloading => '下载中',
    DownloadStatus.merging => '合并中',
    DownloadStatus.paused => '已暂停',
    DownloadStatus.completed => '已完成',
    DownloadStatus.failed => '失败',
  };

  bool get isActive =>
      this == DownloadStatus.resolving ||
      this == DownloadStatus.downloading ||
      this == DownloadStatus.merging ||
      this == DownloadStatus.queued;
}

/// 单个下载任务（可持久化到 SharedPreferences，重启后恢复）。
class DownloadTask {
  final String id;
  final String title;
  final String url;
  final String? videoId;
  final String? cover;
  final String savePath;
  final DownloadStatus status;
  final double progress;
  final String? error;
  final DateTime createdAt;

  const DownloadTask({
    required this.id,
    required this.title,
    required this.url,
    required this.savePath,
    this.videoId,
    this.cover,
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.error,
    required this.createdAt,
  });

  DownloadTask copyWith({
    String? savePath,
    DownloadStatus? status,
    double? progress,
    String? error,
    bool clearError = false,
  }) {
    return DownloadTask(
      id: id,
      title: title,
      url: url,
      videoId: videoId,
      cover: cover,
      savePath: savePath ?? this.savePath,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      error: clearError ? null : (error ?? this.error),
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'url': url,
    'videoId': videoId,
    'cover': cover,
    'savePath': savePath,
    'status': status.name,
    'progress': progress,
    'error': error,
    'createdAt': createdAt.toIso8601String(),
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      id: json['id'] as String,
      title: json['title'] as String? ?? '未命名',
      url: json['url'] as String? ?? '',
      videoId: json['videoId'] as String?,
      cover: json['cover'] as String?,
      savePath: json['savePath'] as String? ?? '',
      status: DownloadStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => DownloadStatus.paused,
      ),
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      error: json['error'] as String?,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// 下载服务：m3u8 → 本地 .ts 文件。
///
/// - 队列并发上限 [maxConcurrent] 个任务；
/// - 暂停后再次开始会复用 `.segments/` 已完成分片（断点续传）；
/// - 任务列表持久化，应用重启后恢复（进行中的任务标记为暂停）。
class DownloadService {
  DownloadService({
    M3u8Downloader? downloader,
    Future<Directory> Function()? baseDirectory,
  }) : _downloader = downloader ?? M3u8Downloader(),
       _baseDirectory = baseDirectory ?? getApplicationDocumentsDirectory;

  static const String _storageKey = 'downloads_v1';
  static const int maxConcurrent = 2;

  final M3u8Downloader _downloader;
  final Future<Directory> Function() _baseDirectory;

  final List<DownloadTask> _tasks = [];
  final List<String> _queue = [];
  final Map<String, CancelToken> _cancelTokens = {};
  final StreamController<List<DownloadTask>> _controller =
      StreamController<List<DownloadTask>>.broadcast();
  int _active = 0;
  bool _initialized = false;

  Stream<List<DownloadTask>> get taskStream => _controller.stream;
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          if (item is! Map<String, dynamic>) continue;
          var task = DownloadTask.fromJson(item);
          // 上次退出时仍在进行中的任务：重启后标记为暂停，等待用户继续。
          if (task.status.isActive) {
            task = task.copyWith(status: DownloadStatus.paused);
          }
          _tasks.add(task);
        }
        _tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        _emit();
      }
    } catch (e) {
      debugPrint('DownloadService init failed: $e');
    }
  }

  /// 加入下载队列，立即返回任务对象（后台继续下载）。
  Future<DownloadTask> addTask({
    required String title,
    required String url,
    String? videoId,
    String? cover,
  }) async {
    await init();
    final dir = await _downloadsDirectory();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final savePath = '${dir.path}/${_safeFileName(title)}-$id.ts';
    final task = DownloadTask(
      id: id,
      title: title,
      url: url,
      videoId: videoId,
      cover: cover,
      savePath: savePath,
      createdAt: DateTime.now(),
    );
    _tasks.insert(0, task);
    _queue.add(id);
    _emit();
    unawaited(_persist());
    _pump();
    return task;
  }

  void pauseTask(String id) {
    final task = _find(id);
    if (task == null || !task.status.isActive) return;
    _queue.remove(id);
    _cancelTokens.remove(id)?.cancel();
    _replace(task.copyWith(status: DownloadStatus.paused));
    _emit();
    unawaited(_persist());
  }

  void resumeTask(String id) {
    final task = _find(id);
    if (task == null) return;
    if (task.status != DownloadStatus.paused &&
        task.status != DownloadStatus.failed) {
      return;
    }
    _replace(task.copyWith(status: DownloadStatus.queued, clearError: true));
    if (!_queue.contains(id)) _queue.add(id);
    _emit();
    unawaited(_persist());
    _pump();
  }

  Future<void> removeTask(String id) async {
    final task = _find(id);
    if (task == null) return;
    _queue.remove(id);
    _cancelTokens.remove(id)?.cancel();
    _tasks.removeWhere((t) => t.id == id);
    _emit();
    await _persist();
    await _deletePartials(task);
  }

  Future<void> clearCompleted() async {
    final completed =
        _tasks.where((t) => t.status == DownloadStatus.completed).toList();
    _tasks.removeWhere((t) => t.status == DownloadStatus.completed);
    _emit();
    await _persist();
    for (final task in completed) {
      await _deletePartials(task);
    }
  }

  void _pump() {
    while (_active < maxConcurrent && _queue.isNotEmpty) {
      final id = _queue.removeAt(0);
      final task = _find(id);
      if (task == null) continue;
      _active++;
      unawaited(
        _run(task).whenComplete(() {
          _active--;
          _pump();
        }),
      );
    }
  }

  Future<void> _run(DownloadTask task) async {
    final token = CancelToken();
    _cancelTokens[task.id] = token;
    _replace(task.copyWith(status: DownloadStatus.resolving, progress: 0));
    _emit();

    try {
      final result = await _downloader.download(
        url: task.url,
        savePath: task.savePath,
        cancelToken: token,
        onProgress: (progress) {
          if (token.isCancelled) return;
          _replace(
            task.copyWith(
              status: switch (progress.phase) {
                M3u8DownloadPhase.resolving => DownloadStatus.resolving,
                M3u8DownloadPhase.downloading => DownloadStatus.downloading,
                M3u8DownloadPhase.merging => DownloadStatus.merging,
                M3u8DownloadPhase.done => DownloadStatus.downloading,
              },
              progress: progress.fraction,
            ),
          );
          _emit();
        },
      );
      _replace(
        task.copyWith(
          status: DownloadStatus.completed,
          progress: 1,
          savePath: result.filePath,
        ),
      );
    } catch (e) {
      final cancelled =
          token.isCancelled || (e is DioException && CancelToken.isCancel(e));
      _replace(
        task.copyWith(
          status: cancelled ? DownloadStatus.paused : DownloadStatus.failed,
          error: cancelled ? null : e.toString(),
          clearError: cancelled,
        ),
      );
    } finally {
      _cancelTokens.remove(task.id);
      _emit();
      await _persist();
    }
  }

  Future<Directory> _downloadsDirectory() async {
    final base = await _baseDirectory();
    final dir = Directory('${base.path}/NovaPlay/Downloads');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _deletePartials(DownloadTask task) async {
    try {
      final file = File(task.savePath);
      if (await file.exists()) await file.delete();
      final segments = Directory('${task.savePath}.segments');
      if (await segments.exists()) await segments.delete(recursive: true);
    } catch (e) {
      debugPrint('删除下载文件失败: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _storageKey,
        jsonEncode(_tasks.map((t) => t.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('保存下载任务失败: $e');
    }
  }

  void _replace(DownloadTask task) {
    final index = _tasks.indexWhere((t) => t.id == task.id);
    if (index >= 0) {
      _tasks[index] = task;
    }
  }

  DownloadTask? _find(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(List.unmodifiable(_tasks));
    }
  }

  void dispose() {
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
    _cancelTokens.clear();
    _controller.close();
  }

  static String _safeFileName(String title) {
    final cleaned =
        title
            .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    if (cleaned.isEmpty) return 'video';
    return cleaned.length > 80 ? cleaned.substring(0, 80) : cleaned;
  }
}
