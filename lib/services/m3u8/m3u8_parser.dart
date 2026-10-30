/// m3u8 播放列表解析（纯 Dart，不依赖网络，便于单元测试）。
///
/// 支持：
/// - master playlist（#EXT-X-STREAM-INF）与 media playlist（#EXTINF 分片）
/// - 相对/绝对 URI 解析（基于 playlist 自身 URL）
/// - EXT-X-KEY 加密识别（AES-128 等，当前下载器不支持加密流，解析层显式标记）
library;

/// 解析失败异常（格式错误、编码不支持等）。
class M3u8FormatException implements Exception {
  final String message;

  M3u8FormatException(this.message);

  @override
  String toString() => 'M3u8FormatException: $message';
}

/// master playlist 中的一个清晰度变体。
class M3u8Variant {
  final String url;
  final int? bandwidth;
  final String? resolution;
  final String? codecs;

  const M3u8Variant({
    required this.url,
    this.bandwidth,
    this.resolution,
    this.codecs,
  });
}

/// media playlist 中的一个分片。
class M3u8Segment {
  final String url;
  final double duration;
  final int index;

  const M3u8Segment({
    required this.url,
    required this.duration,
    required this.index,
  });
}

/// 解析结果：要么是 master（有 variants），要么是 media（有 segments）。
class M3u8Playlist {
  final String url;
  final List<M3u8Variant> variants;
  final List<M3u8Segment> segments;
  final double totalDuration;
  final String? encryptionMethod;

  const M3u8Playlist({
    required this.url,
    this.variants = const [],
    this.segments = const [],
    this.totalDuration = 0,
    this.encryptionMethod,
  });

  bool get isMaster => variants.isNotEmpty;

  bool get isEncrypted =>
      encryptionMethod != null && encryptionMethod!.toUpperCase() != 'NONE';
}

class M3u8Parser {
  /// 解析 [content]；[baseUrl] 用于把相对 URI 转成绝对地址。
  static M3u8Playlist parse(String content, {required String baseUrl}) {
    final normalized = content.replaceFirst('\uFEFF', '');
    if (!normalized.contains('#EXTM3U')) {
      throw M3u8FormatException('不是有效的 m3u8 播放列表');
    }

    final lines =
        normalized.split(RegExp(r'\r?\n')).map((line) => line.trim()).toList();

    final variants = <M3u8Variant>[];
    final segments = <M3u8Segment>[];
    double totalDuration = 0;
    String? encryption;

    int? pendingBandwidth;
    String? pendingResolution;
    String? pendingCodecs;
    double? pendingDuration;

    for (final line in lines) {
      if (line.isEmpty) continue;

      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        final attrs = _parseAttributes(
          line.substring('#EXT-X-STREAM-INF:'.length),
        );
        pendingBandwidth = int.tryParse(attrs['BANDWIDTH'] ?? '');
        pendingResolution = attrs['RESOLUTION'];
        pendingCodecs = attrs['CODECS'];
        continue;
      }

      if (line.startsWith('#EXTINF:')) {
        final value = line.substring('#EXTINF:'.length);
        final durationText = value.split(',').first.trim();
        pendingDuration = double.tryParse(durationText);
        continue;
      }

      if (line.startsWith('#EXT-X-KEY:')) {
        final attrs = _parseAttributes(line.substring('#EXT-X-KEY:'.length));
        final method = attrs['METHOD'];
        if (method != null && method.toUpperCase() != 'NONE') {
          encryption = method.toUpperCase();
        }
        continue;
      }

      if (line.startsWith('#')) continue;

      // 非注释行 = URI
      final resolved = _resolve(line, baseUrl);
      if (pendingBandwidth != null || pendingResolution != null) {
        variants.add(
          M3u8Variant(
            url: resolved,
            bandwidth: pendingBandwidth,
            resolution: pendingResolution,
            codecs: pendingCodecs,
          ),
        );
        pendingBandwidth = null;
        pendingResolution = null;
        pendingCodecs = null;
        continue;
      }

      final duration = pendingDuration ?? 0;
      pendingDuration = null;
      segments.add(
        M3u8Segment(url: resolved, duration: duration, index: segments.length),
      );
      totalDuration += duration;
    }

    return M3u8Playlist(
      url: baseUrl,
      variants: List.unmodifiable(variants),
      segments: List.unmodifiable(segments),
      totalDuration: totalDuration,
      encryptionMethod: encryption,
    );
  }

  static String _resolve(String uri, String baseUrl) {
    try {
      return Uri.parse(baseUrl).resolve(uri).toString();
    } catch (_) {
      return uri;
    }
  }

  /// 解析 `KEY=VALUE,KEY="VALUE"` 形式的属性串。
  static Map<String, String> _parseAttributes(String input) {
    final result = <String, String>{};
    final regex = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');
    for (final match in regex.allMatches(input)) {
      final key = match.group(1)!;
      var value = match.group(2)!.trim();
      if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
        value = value.substring(1, value.length - 1);
      }
      result[key] = value;
    }
    return result;
  }
}
