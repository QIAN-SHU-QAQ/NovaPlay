import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

enum DownloadStatus {
  pending,
  downloading,
  paused,
  completed,
  failed,
}

class DownloadTask {
  final String id;
  final String title;
  final String url;
  final String? cover;
  String? savePath;
  DownloadStatus status;
  double progress;
  int totalBytes;
  int downloadedBytes;
  String? error;
  CancelToken? cancelToken;

  DownloadTask({
    required this.id,
    required this.title,
    required this.url,
    this.cover,
    this.savePath,
    this.status = DownloadStatus.pending,
    this.progress = 0.0,
    this.totalBytes = 0,
    this.downloadedBytes = 0,
    this.error,
    this.cancelToken,
  });
}

class DownloadService {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;

  final Dio _dio = Dio();
  final List<DownloadTask> _tasks = [];
  final _taskController = StreamController<List<DownloadTask>>.broadcast();

  DownloadService._internal() {
    _dio.options.connectTimeout = const Duration(seconds: 30);
    _dio.options.receiveTimeout = const Duration(seconds: 30);
  }

  Stream<List<DownloadTask>> get taskStream => _taskController.stream;
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  Future<void> addTask(String title, String url, {String? cover}) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final task = DownloadTask(
      id: id,
      title: title,
      url: url,
      cover: cover,
    );

    _tasks.add(task);
    _notifyListeners();

    await _downloadFile(task);
  }

  Future<void> _downloadFile(DownloadTask task) async {
    try {
      task.status = DownloadStatus.downloading;
      task.cancelToken = CancelToken();
      _notifyListeners();

      // Get download directory
      final dir = await getApplicationDocumentsDirectory();
      final saveDir = Directory('${dir.path}/NovaPlay/Downloads');
      if (!await saveDir.exists()) {
        await saveDir.create(recursive: true);
      }

      final fileName = '${task.id}.mp4';
      task.savePath = '${saveDir.path}/$fileName';

      await _dio.download(
        task.url,
        task.savePath,
        cancelToken: task.cancelToken,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            task.downloadedBytes = received;
            task.totalBytes = total;
            task.progress = received / total;
            _notifyListeners();
          }
        },
      );

      task.status = DownloadStatus.completed;
      task.progress = 1.0;
      _notifyListeners();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        task.status = DownloadStatus.paused;
      } else {
        task.status = DownloadStatus.failed;
        task.error = e.message;
      }
      _notifyListeners();
    } catch (e) {
      task.status = DownloadStatus.failed;
      task.error = e.toString();
      _notifyListeners();
    }
  }

  void pauseTask(String id) {
    final task = _tasks.firstWhere((t) => t.id == id);
    task.cancelToken?.cancel();
    task.status = DownloadStatus.paused;
    _notifyListeners();
  }

  void resumeTask(String id) {
    final task = _tasks.firstWhere((t) => t.id == id);
    if (task.status == DownloadStatus.paused) {
      _downloadFile(task);
    }
  }

  void cancelTask(String id) {
    final task = _tasks.firstWhere((t) => t.id == id);
    task.cancelToken?.cancel();
    _tasks.removeWhere((t) => t.id == id);
    _notifyListeners();

    // Delete file if exists
    if (task.savePath != null) {
      final file = File(task.savePath!);
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
  }

  void _notifyListeners() {
    _taskController.add(List.unmodifiable(_tasks));
  }

  void dispose() {
    _taskController.close();
  }
}
