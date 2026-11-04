import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

/// 单个分片的清单信息（用于断点续传的完整性校验）。
class _SegmentEntry {
  _SegmentEntry({
    required this.index,
    required this.url,
    required this.duration,
    this.size,
    this.sha256,
  });

  final int index;
  final String url;
  final double duration;
  int? size;
  String? sha256;

  Map<String, dynamic> toJson() => {
    'index': index,
    'url': url,
    'duration': duration,
    'size': size,
    'sha256': sha256,
  };

  static _SegmentEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final index = raw['index'];
    final url = raw['url'];
    if (index is! num || url is! String) return null;
    return _SegmentEntry(
      index: index.toInt(),
      url: url,
      duration: (raw['duration'] as num?)?.toDouble() ?? 0,
      size: (raw['size'] as num?)?.toInt(),
      sha256: raw['sha256'] as String?,
    );
  }
}

/// 下载清单指纹与分片元数据。
///
/// 断点续传时只有「清单指纹一致 + 分片 URI 一致 + 本地文件大小/哈希一致」
/// 才允许复用；清单变化（重排、URI 变化）会清空缓存重新下载；清单过期
/// （超过 [_SegmentManifest] 允许的复用时限）也会重新下载，避免复用陈旧内容。
class _SegmentManifest {
  _SegmentManifest({
    required this.playlistUrl,
    required this.fingerprint,
    required this.generatedAt,
    required this.segments,
  });

  final String playlistUrl;
  final String fingerprint;
  final DateTime generatedAt;
  final List<_SegmentEntry> segments;

  static const int version = 1;

  Map<String, dynamic> toJson() => {
    'version': version,
    'playlistUrl': playlistUrl,
    'fingerprint': fingerprint,
    'generatedAt': generatedAt.toIso8601String(),
    'segments': segments.map((entry) => entry.toJson()).toList(),
  };

  static _SegmentManifest? load(File file) {
    try {
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map || decoded['version'] != version) return null;
      final fingerprint = decoded['fingerprint'];
      final generatedAt = DateTime.tryParse('${decoded['generatedAt']}');
      final rawSegments = decoded['segments'];
      if (fingerprint is! String ||
          generatedAt == null ||
          rawSegments is! List) {
        return null;
      }
      final segments =
          rawSegments
              .map(_SegmentEntry.fromJson)
              .whereType<_SegmentEntry>()
              .toList();
      if (segments.isEmpty) return null;
      return _SegmentManifest(
        playlistUrl: '${decoded['playlistUrl'] ?? ''}',
        fingerprint: fingerprint,
        generatedAt: generatedAt,
        segments: segments,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(File file) async {
    try {
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(toJson()));
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('保存下载清单失败: $e');
    }
  }
}

/// 纯 Dart m3u8 分片下载器。
///
/// - 支持 master playlist（自动选码率最高的变体）与未加密 TS 点播列表；
/// - 分片并发下载，单分片失败自动重试；
/// - 断点续传：分片落在 `<savePath>.segments/` 目录，清单指纹、URI、大小与
///   哈希一致才复用；清单变化或超过复用时限时重新下载，避免混拼旧分片；
/// - 分片先写 `.part` 再原子改名，进程中断不会把半截文件当成已完成；
/// - 完成后按顺序拼接为单个 `.ts` 文件（mpv 可直接播放）；
/// - 加密流、fMP4、BYTERANGE、独立音轨、直播列表等不支持格式在下载主体前
///   显式抛错，不会报告成功。
class M3u8Downloader {
  M3u8Downloader({
    Dio? dio,
    this.concurrency = 4,
    this.maxRetries = 3,
    this.reuseWindow = const Duration(minutes: 30),
  }) : _dio =
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

  /// 清单超过该时长后不再复用旧分片（重新下载），避免复用可能变化的远端内容。
  final Duration reuseWindow;

  /// 同一 savePath 的下载串行化：暂停后立刻继续时，新任务等待旧任务
  /// 完成清单落盘，避免两个任务同时改写分片目录。
  static final Map<String, Future<void>> _locks = {};

  /// 下载并合并；[onProgress] 会被多次调用。
  Future<M3u8DownloadResult> download({
    required String url,
    required String savePath,
    void Function(M3u8DownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final previous = _locks[savePath];
    final completer = Completer<void>();
    _locks[savePath] = completer.future;
    if (previous != null) {
      try {
        await previous;
      } catch (_) {}
    }
    try {
      return await _downloadImpl(
        url: url,
        savePath: savePath,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    } finally {
      if (identical(_locks[savePath], completer.future)) {
        _locks.remove(savePath);
      }
      completer.complete();
    }
  }

  Future<M3u8DownloadResult> _downloadImpl({
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
    onProgress?.call(
      M3u8DownloadProgress(
        phase: M3u8DownloadPhase.downloading,
        totalSegments: media.segments.length,
      ),
    );

    final segmentsDir = Directory('$savePath.segments');
    final manifestFile = File(
      '${segmentsDir.path}${Platform.pathSeparator}manifest.json',
    );
    final fingerprint = _fingerprint(media);
    var reusable = await _loadReusableManifest(
      manifestFile,
      fingerprint,
      media,
    );
    if (reusable == null) {
      // 清单变化或已过期：清空旧分片，避免混拼。
      await _clearSegments(segmentsDir);
      reusable = _SegmentManifest(
        playlistUrl: media.url,
        fingerprint: fingerprint,
        generatedAt: DateTime.now(),
        segments:
            media.segments
                .map(
                  (segment) => _SegmentEntry(
                    index: segment.index,
                    url: segment.url,
                    duration: segment.duration,
                  ),
                )
                .toList(),
      );
    }
    final manifest = reusable;
    await manifest.save(manifestFile);

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

    try {
      var nextIndex = 0;
      Future<void> worker() async {
        while (true) {
          final index = nextIndex++;
          if (index >= total) return;
          if (cancelToken?.isCancelled ?? false) return;

          final entry = manifest.segments[index];
          final file = File(
            '${segmentsDir.path}${Platform.pathSeparator}${_segmentName(index)}',
          );
          if (!await _canReuseSegment(entry, file)) {
            if (await file.exists()) await file.delete();
            final part = File('${file.path}.part');
            if (await part.exists()) await part.delete();
            await _downloadSegment(entry.url, part, cancelToken);
            if (cancelToken?.isCancelled ?? false) return;
            await part.rename(file.path);
            entry.size = await file.length();
            entry.sha256 = await _hashFile(file);
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
    } finally {
      // 把已完成分片的大小/哈希写回清单，供下次续传校验。
      await manifest.save(manifestFile);
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
        final part = File(
          '${segmentsDir.path}${Platform.pathSeparator}${_segmentName(i)}',
        );
        if (!await part.exists()) {
          throw M3u8FormatException('分片缺失：${part.path}');
        }
        await sink.addStream(part.openRead());
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    // 成功后清理临时分片与清单
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

  Future<_SegmentManifest?> _loadReusableManifest(
    File manifestFile,
    String fingerprint,
    M3u8Playlist media,
  ) async {
    final existing = _SegmentManifest.load(manifestFile);
    if (existing == null) return null;
    if (existing.fingerprint != fingerprint) {
      debugPrint('下载清单已变化，重新下载分片');
      return null;
    }
    if (DateTime.now().difference(existing.generatedAt) > reuseWindow) {
      debugPrint('下载清单超过复用时限，重新下载分片');
      return null;
    }
    if (existing.segments.length != media.segments.length) return null;
    for (var i = 0; i < media.segments.length; i++) {
      final entry = existing.segments[i];
      final segment = media.segments[i];
      if (entry.index != segment.index ||
          entry.url != segment.url ||
          entry.duration != segment.duration) {
        return null;
      }
    }
    return existing;
  }

  Future<bool> _canReuseSegment(_SegmentEntry entry, File file) async {
    if (entry.size == null || entry.sha256 == null) return false;
    if (!await file.exists()) return false;
    if (await file.length() != entry.size) return false;
    return await _hashFile(file) == entry.sha256;
  }

  Future<String> _hashFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<void> _clearSegments(Directory segmentsDir) async {
    try {
      if (await segmentsDir.exists()) {
        await segmentsDir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('清理旧分片失败: $e');
    }
  }

  String _fingerprint(M3u8Playlist playlist) {
    final canonical =
        StringBuffer()
          ..writeln('nova-m3u8-v1')
          ..writeln(playlist.url);
    for (final segment in playlist.segments) {
      canonical.writeln('${segment.index}|${segment.url}|${segment.duration}');
    }
    return sha256.convert(utf8.encode(canonical.toString())).toString();
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
      _ensureSupported(playlist);
      final variant = _pickVariant(playlist.variants);
      playlist = M3u8Parser.parse(
        await _fetchText(variant.url, cancelToken),
        baseUrl: variant.url,
      );
    }
    _ensureSupported(playlist, requireSegments: true);
    return playlist;
  }

  /// R3：下载主体开始前拒绝不支持的格式，避免输出不完整文件却报告成功。
  void _ensureSupported(M3u8Playlist playlist, {bool requireSegments = false}) {
    if (playlist.isEncrypted) {
      throw M3u8FormatException('暂不支持加密 m3u8（${playlist.encryptionMethod}）');
    }
    if (playlist.hasFmp4Init) {
      throw M3u8FormatException('暂不支持 fMP4（EXT-X-MAP 初始化段）');
    }
    if (playlist.hasByteRange) {
      throw M3u8FormatException('暂不支持 EXT-X-BYTERANGE 分片');
    }
    if (playlist.hasAlternateAudio) {
      throw M3u8FormatException('暂不支持独立音轨（EXT-X-MEDIA:TYPE=AUDIO）');
    }
    if (!requireSegments) return;
    if (playlist.isLive) {
      throw M3u8FormatException('暂不支持直播或滚动列表（缺少 EXT-X-ENDLIST）');
    }
    if (playlist.segments.isEmpty) {
      throw M3u8FormatException('播放列表中没有分片');
    }
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
