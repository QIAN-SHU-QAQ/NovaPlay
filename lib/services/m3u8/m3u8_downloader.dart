import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'm3u8_parser.dart';

/// 下载阶段
enum M3u8DownloadPhase { resolving, downloading, merging, done }

/// 下载进度（由下载器主动上报，UI 可直接绑定）
class M3u8DownloadProgress {
  final M3u8DownloadPhase phase;
  final int completedSegments;
  final int totalSegments;

  const M3u8DownloadProgress({
    required this.phase,
    this.completedSegments = 0,
    this.totalSegments = 0,
  });

  double get fraction {
    if (totalSegments <= 0) return 0;
    return (completedSegments / totalSegments).clamp(0.0, 1.0);
  }
}

/// 下载结果
class M3u8DownloadResult {
  final String filePath;
  final int segmentCount;
  final Duration elapsed;

  const M3u8DownloadResult({
    required this.filePath,
    required this.segmentCount,
    required this.elapsed,
  });
}

/// 纯 Dart m3u8 分片下载器。
///
/// - 支持 master playlist（自动选码率最高的变体）与 media playlist；
/// - 分片并发下载，单分片失败自动重试；
/// - 断点续传：分片落在 `<savePath>.segments/` 目录，重跑时跳过已完成的；
/// - 完成后按顺序拼接为单个 `.ts` 文件（mpv 可直接播放）；
/// - AES-128 等加密流暂不支持，会显式抛错。
class M3u8Downloader {
  M3u8Downloader({Dio? dio, this.concurrency = 4, this.maxRetries = 3})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
              headers: const {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
              },
            ),
          );

  final Dio _dio;
  final int concurrency;
  final int maxRetries;

  /// 下载并合并；[onProgress] 会被多次调用。
  Future<M3u8DownloadResult> download({
    required String url,
    required String savePath,
    void Function(M3u8DownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final stopwatch = Stopwatch()..start();
    onProgress?.call(
      const M3u8DownloadProgress(phase: M3u8DownloadPhase.resolving),
    );

    final media = await _resolveMediaPlaylist(url, cancelToken: cancelToken);
    if (media.isEncrypted) {
      throw M3u8FormatException('暂不支持加密 m3u8（${media.encryptionMethod}）');
    }
    if (media.segments.isEmpty) {
      throw M3u8FormatException('播放列表中没有分片');
    }

    final segmentsDir = Directory('$savePath.segments');
    if (!await segmentsDir.exists()) {
      await segmentsDir.create(recursive: true);
    }

    var completed = 0;
    final total = media.segments.length;
    void report(M3u8DownloadPhase phase) {
      onProgress?.call(
        M3u8DownloadProgress(
          phase: phase,
          completedSegments: completed,
          totalSegments: total,
        ),
      );
    }

    report(M3u8DownloadPhase.downloading);

    // 简单的工作池：每个 worker 从递增索引里取任务
    var nextIndex = 0;
    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= total) return;
        if (cancelToken?.isCancelled ?? false) return;

        final segment = media.segments[index];
        final file = File('${segmentsDir.path}/${_segmentName(index)}');
        if (!await file.exists() || await file.length() == 0) {
          await _downloadSegment(segment.url, file, cancelToken);
        }
        completed++;
        report(M3u8DownloadPhase.downloading);
      }
    }

    final workerCount = concurrency < total ? concurrency : total;
    await Future.wait(List.generate(workerCount, (_) => worker()));

    if (cancelToken?.isCancelled ?? false) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: url),
        reason: '已取消',
      );
    }

    report(M3u8DownloadPhase.merging);
    final output = File(savePath);
    final parent = output.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final sink = output.openWrite();
    try {
      for (var i = 0; i < total; i++) {
        final part = File('${segmentsDir.path}/${_segmentName(i)}');
        if (!await part.exists()) {
          throw M3u8FormatException('分片缺失：${part.path}');
        }
        await sink.addStream(part.openRead());
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    // 成功后清理临时分片
    try {
      await segmentsDir.delete(recursive: true);
    } catch (e) {
      debugPrint('清理分片目录失败：$e');
    }

    report(M3u8DownloadPhase.done);
    stopwatch.stop();
    return M3u8DownloadResult(
      filePath: savePath,
      segmentCount: total,
      elapsed: stopwatch.elapsed,
    );
  }

  Future<M3u8Playlist> _resolveMediaPlaylist(
    String url, {
    CancelToken? cancelToken,
  }) async {
    var playlist = M3u8Parser.parse(
      await _fetchText(url, cancelToken),
      baseUrl: url,
    );

    if (playlist.isMaster) {
      final variant = _pickVariant(playlist.variants);
      playlist = M3u8Parser.parse(
        await _fetchText(variant.url, cancelToken),
        baseUrl: variant.url,
      );
    }
    return playlist;
  }

  M3u8Variant _pickVariant(List<M3u8Variant> variants) {
    final sorted = [...variants]
      ..sort((a, b) => (b.bandwidth ?? 0).compareTo(a.bandwidth ?? 0));
    return sorted.first;
  }

  Future<String> _fetchText(String url, CancelToken? cancelToken) async {
    try {
      final response = await _dio.get<String>(
        url,
        cancelToken: cancelToken,
        options: Options(responseType: ResponseType.plain),
      );
      return response.data ?? '';
    } on DioException catch (e) {
      throw M3u8FormatException('获取播放列表失败：${e.message ?? e.type.name}');
    }
  }

  Future<void> _downloadSegment(
    String url,
    File file,
    CancelToken? cancelToken,
  ) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final response = await _dio.get<List<int>>(
          url,
          cancelToken: cancelToken,
          options: Options(responseType: ResponseType.bytes),
        );
        final bytes = response.data;
        if (bytes == null || bytes.isEmpty) {
          throw M3u8FormatException('分片为空：$url');
        }
        await file.writeAsBytes(bytes, flush: true);
        return;
      } catch (e) {
        lastError = e;
        if (cancelToken?.isCancelled ?? false) return;
        if (attempt < maxRetries) {
          await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
        }
      }
    }
    throw M3u8FormatException('分片下载失败（重试 $maxRetries 次）：$url ($lastError)');
  }

  static String _segmentName(int index) =>
      'seg_${index.toString().padLeft(6, '0')}.ts';
}
