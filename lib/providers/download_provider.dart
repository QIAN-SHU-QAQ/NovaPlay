import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/download_service.dart';

/// 下载服务（单例按 Provider 生命周期管理）。
final downloadServiceProvider = Provider<DownloadService>((ref) {
  final service = DownloadService();
  unawaited(service.init());
  ref.onDispose(service.dispose);
  return service;
});

/// 下载任务列表 + 操作入口。
class DownloadTasksNotifier extends StateNotifier<List<DownloadTask>> {
  DownloadTasksNotifier(this._service) : super(_service.tasks) {
    _subscription = _service.taskStream.listen((tasks) => state = tasks);
    unawaited(
      _service.init().then((_) {
        if (mounted) state = _service.tasks;
      }),
    );
  }

  final DownloadService _service;
  StreamSubscription<List<DownloadTask>>? _subscription;

  Future<DownloadTask> addTask({
    required String title,
    required String url,
    String? videoId,
    String? cover,
  }) {
    return _service.addTask(
      title: title,
      url: url,
      videoId: videoId,
      cover: cover,
    );
  }

  void pause(String id) => _service.pauseTask(id);

  void resume(String id) => _service.resumeTask(id);

  Future<void> remove(String id) => _service.removeTask(id);

  Future<void> clearCompleted() => _service.clearCompleted();

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

final downloadTasksProvider =
    StateNotifierProvider<DownloadTasksNotifier, List<DownloadTask>>((ref) {
      return DownloadTasksNotifier(ref.watch(downloadServiceProvider));
    });
