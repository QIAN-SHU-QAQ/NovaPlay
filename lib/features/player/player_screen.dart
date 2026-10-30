import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';

import '../../core/config/theme.dart';
import '../../models/history_item.dart';
import '../../models/video_model.dart';
import '../../providers/history_provider.dart';
import 'playback_session.dart';
import 'fullscreen_session.dart';

final playerFactoryProvider = Provider<Player Function()>(
  (ref) =>
      () => Player(
        configuration: const PlayerConfiguration(
          bufferSize: 64 * 1024 * 1024,
          protocolWhitelist: ['https', 'http', 'tcp', 'tls'],
        ),
      ),
);

/// An injectable surface keeps media behavior testable without a native texture.
final playerSurfaceProvider = Provider<Widget Function(Player)?>((ref) => null);

/// 播放器：恒深色主题（不受全局 themeMode 影响）。
/// 窗口态 = 顶栏 + 视频 + 底部控制栏 + 右侧面板（弹幕占位/选集）；
/// 全屏态 = 隐藏chrome，控制栏悬浮、3 秒无操作自动隐藏。
/// 键盘：空格 播放暂停 / ←→ ±5s / ↑↓ 音量 / F 全屏 / Esc 退出（桌面按键连发天生支持）。
class PlayerScreen extends ConsumerStatefulWidget {
  final String videoUrl;
  final String title;
  final List<Map<String, String>>? episodes;
  final int currentIndex;

  /// 续播起点（秒），仅对初始打开的剧集生效
  final int startAt;

  /// 观看历史记录所需的元数据，videoId 为空时不记录历史
  final String? videoId;
  final String? videoTitle;
  final String? cover;

  const PlayerScreen({
    super.key,
    required this.videoUrl,
    required this.title,
    this.episodes,
    this.currentIndex = 0,
    this.startAt = 0,
    this.videoId,
    this.videoTitle,
    this.cover,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final ThemeData _playerTheme;
  late final Player _player;
  VideoController? _controller;
  late final PlaybackSession _session;
  late final FullscreenSession _fullscreen;
  Widget Function(Player)? _surfaceBuilder;
  int get _currentIndex => _session.index;
  bool get _isInitialized => _session.ready;
  Timer? _historyTimer;
  List<EpisodeModel>? _episodeSnapshot;

  // 全屏与控制栏显隐
  bool get _isFullscreen => _fullscreen.active;
  bool _controlsVisible = true;
  Timer? _hideControlsTimer;

  // dispose 中不能再用 ref，提前捕获 notifier
  late final HistoryNotifier _historyNotifier;

  @override
  void initState() {
    super.initState();
    _playerTheme = AppTheme.dark;
    _historyNotifier = ref.read(historyProvider.notifier);
    _player = ref.read(playerFactoryProvider)();
    _surfaceBuilder = ref.read(playerSurfaceProvider);
    if (_surfaceBuilder == null) _controller = VideoController(_player);
    _session = PlaybackSession(
      player: _player,
      initialUrl: widget.videoUrl,
      initialTitle: widget.title,
      videoTitle: widget.videoTitle,
      episodes: widget.episodes,
      index: widget.currentIndex,
      startAt: widget.startAt,
    );
    _fullscreen = FullscreenSession();
    _session.addListener(_sessionChanged);
    _fullscreen.addListener(_sessionChanged);
    unawaited(_configureAndOpen());
    _historyTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _recordHistory(),
    );
    FocusManager.instance.addEarlyKeyEventHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKeyEvent);
    _hideControlsTimer?.cancel();
    _historyTimer?.cancel();
    _recordHistory();
    _session.removeListener(_sessionChanged);
    _fullscreen.removeListener(_sessionChanged);
    _session.dispose();
    _fullscreen.dispose();
    super.dispose();
  }

  void _sessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _configureMpvProperties() async {
    try {
      final nativePlayer = _player.platform;
      if (nativePlayer is NativePlayer) {
        // 缓存秒数：预加载 60 秒
        await nativePlayer.setProperty('cache-secs', '60');
        // 最大前向缓冲：64MB
        await nativePlayer.setProperty('demuxer-max-bytes', '67108864');
        // 最大后向缓冲：32MB
        await nativePlayer.setProperty('demuxer-max-back-bytes', '33554432');
        // HTTP 连接优化
        await nativePlayer.setProperty(
          'demuxer-lavf-o',
          'http_timeout=15,http_multiple_connections=1',
        );
      }
    } catch (e) {
      debugPrint('Error configuring mpv: $e');
    }
  }

  Future<void> _configureAndOpen() async {
    await _configureMpvProperties();
    if (mounted) await _session.open();
  }

  /// 把 UI 传入的剧集列表转成可持久化的快照（只转换一次）
  List<EpisodeModel>? get _episodeModels {
    final eps = widget.episodes;
    if (eps == null || eps.isEmpty) return null;
    return _episodeSnapshot ??=
        eps
            .asMap()
            .entries
            .map(
              (e) => EpisodeModel(
                id: 'ep_${e.key + 1}',
                title: e.value['title'] ?? '第 ${e.key + 1} 集',
                url: e.value['url'] ?? '',
                index: e.key,
                playUrl: e.value['url'],
              ),
            )
            .toList();
  }

  /// 记录当前观看进度到历史（videoId 缺失、无剧集、进度过短时跳过）
  void _recordHistory() {
    final videoId = widget.videoId;
    if (!_session.ready || _session.loading) return;
    if (videoId == null || videoId.isEmpty) return;
    final snapshots = _episodeModels;
    if (snapshots == null || snapshots.isEmpty) return;
    if (_currentIndex < 0 || _currentIndex >= snapshots.length) return;

    final state = _player.state;
    if (state.position.inSeconds < 5) return;

    unawaited(
      _historyNotifier.record(
        HistoryItem(
          videoId: videoId,
          title: widget.videoTitle ?? widget.title,
          cover: widget.cover,
          episodes: snapshots,
          episodeIndex: _currentIndex,
          position: state.position,
          duration: state.duration,
          watchedAt: DateTime.now(),
        ),
      ),
    );
  }

  void _playEpisode(int index) {
    if (widget.episodes == null ||
        index < 0 ||
        index >= widget.episodes!.length) {
      return;
    }

    // 切集前先落盘当前进度
    _recordHistory();

    unawaited(_session.switchEpisode(index));
  }

  // ---------- 播放控制 ----------

  void _togglePlay() {
    if (!_isInitialized) return;
    _player.playOrPause();
  }

  void _seekBy(int seconds) {
    if (!_isInitialized) return;
    final target = _player.state.position + Duration(seconds: seconds);
    _player.seek(target);
  }

  void _changeVolume(double delta) {
    final target = (_player.state.volume + delta).clamp(0.0, 100.0);
    _player.setVolume(target);
  }

  void _toggleFullscreen() {
    _hideControlsTimer?.cancel();
    _controlsVisible = true;
    unawaited(
      _fullscreen.toggle().then((_) {
        if (mounted && _isFullscreen) _revealControls();
      }),
    );
  }

  /// 全屏态：显示控制栏并 3 秒无操作后自动隐藏
  void _revealControls() {
    if (!_isFullscreen) return;
    _hideControlsTimer?.cancel();
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _isFullscreen) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  // ---------- 键盘快捷键（早拦截并消费；方向键长按连发由桌面 KeyRepeatEvent 天生支持） ----------

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    final isRepeat = event is KeyRepeatEvent;
    if (event is! KeyDownEvent && !isRepeat) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space && !isRepeat) {
      _togglePlay();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBy(-5);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(5);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _changeVolume(5);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _changeVolume(-5);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyF && !isRepeat) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.escape && !isRepeat) {
      if (_isFullscreen) {
        _toggleFullscreen();
      } else {
        _exitScreen();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _exitScreen() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      context.go('/');
    }
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    // 恒深色：包裹独立的 dark 主题，与全局明暗模式解耦
    return Theme(
      data: _playerTheme,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: _isFullscreen ? _buildFullscreenBody() : _buildWindowedBody(),
        ),
      ),
    );
  }

  /// 窗口态：左列（顶栏/视频/控制栏） + 右侧面板
  Widget _buildWindowedBody() {
    return Row(
      children: [
        Expanded(
          child: Column(
            children: [
              _buildTopBar(),
              Expanded(child: _buildVideoArea()),
              _buildControlBar(),
            ],
          ),
        ),
        _buildRightPanel(),
      ],
    );
  }

  /// 全屏态：视频铺满，控制栏悬浮，鼠标移动唤起
  Widget _buildFullscreenBody() {
    return MouseRegion(
      onHover: (_) => _revealControls(),
      child: Stack(
        children: [
          Positioned.fill(child: _buildVideoArea()),
          Positioned.fill(
            child: AnimatedOpacity(
              opacity: _controlsVisible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: Column(
                  children: [
                    _buildTopBar(overlay: true),
                    const Spacer(),
                    _buildControlBar(overlay: true),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar({bool overlay = false}) {
    return Container(
      color: overlay ? Colors.black.withValues(alpha: 0.55) : Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            onPressed: _exitScreen,
          ),
          Expanded(
            child: Text(
              _session.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_isFullscreen)
            IconButton(
              tooltip: '退出全屏 (Esc)',
              icon: const Icon(Icons.fullscreen_exit, color: Colors.white),
              onPressed: _toggleFullscreen,
            ),
        ],
      ),
    );
  }

  Widget _buildVideoArea() {
    final colorScheme = _playerTheme.colorScheme;
    return Container(
      color: Colors.black,
      child:
          _isInitialized
              ? GestureDetector(
                // 点击视频区域：窗口态切换播放/暂停，全屏态唤起/隐藏控制栏
                onTap:
                    _isFullscreen
                        ? () {
                          if (_controlsVisible) {
                            _hideControlsTimer?.cancel();
                            setState(() => _controlsVisible = false);
                          } else {
                            _revealControls();
                          }
                        }
                        : _togglePlay,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _surfaceBuilder?.call(_player) ??
                          Video(
                            controller: _controller!,
                            controls: NoVideoControls,
                          ),
                      if (_session.buffering)
                        const Center(child: CircularProgressIndicator()),
                    ],
                  ),
                ),
              )
              : Center(
                child:
                    _session.error == null
                        ? CircularProgressIndicator(color: colorScheme.primary)
                        : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: Colors.white70,
                              size: 40,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              '播放失败',
                              style: TextStyle(color: Colors.white),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                _session.error!,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ),
                            FilledButton.icon(
                              onPressed: () => _session.open(),
                              icon: const Icon(Icons.refresh),
                              label: const Text('重试'),
                            ),
                          ],
                        ),
              ),
    );
  }

  /// 底部控制栏：进度+缓冲 / 播放 / 上下集 / 弹幕占位 / 倍速 / 音量 / 全屏
  Widget _buildControlBar({bool overlay = false}) {
    final colorScheme = _playerTheme.colorScheme;
    final hasEpisodes = widget.episodes != null && widget.episodes!.isNotEmpty;

    return Container(
      color:
          overlay
              ? Colors.black.withValues(alpha: 0.75)
              : colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 进度条（含缓冲指示）
          _buildProgressBar(),
          const SizedBox(height: 2),
          Row(
            children: [
              // 播放/暂停
              StreamBuilder<bool>(
                stream: _player.stream.playing,
                initialData: _player.state.playing,
                builder: (context, snap) {
                  final playing = snap.data ?? false;
                  return IconButton(
                    tooltip: playing ? '暂停 (空格)' : '播放 (空格)',
                    icon: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                    ),
                    onPressed: _togglePlay,
                  );
                },
              ),

              // 上一集 / 下一集
              if (hasEpisodes) ...[
                IconButton(
                  tooltip: '上一集',
                  icon: const Icon(
                    Icons.skip_previous_rounded,
                    color: Colors.white,
                  ),
                  onPressed:
                      _currentIndex > 0
                          ? () => _playEpisode(_currentIndex - 1)
                          : null,
                ),
                IconButton(
                  tooltip: '下一集',
                  icon: const Icon(
                    Icons.skip_next_rounded,
                    color: Colors.white,
                  ),
                  onPressed:
                      _currentIndex < widget.episodes!.length - 1
                          ? () => _playEpisode(_currentIndex + 1)
                          : null,
                ),
              ],

              // 发弹幕占位（Phase 4 接入）
              IconButton(
                tooltip: '发弹幕（即将上线）',
                icon: Icon(
                  Icons.subtitles_outlined,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('弹幕功能即将上线（Phase 4）'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),

              const Spacer(),

              // 倍速
              _buildSpeedMenu(),

              // 音量
              _buildVolumeMenu(),

              // 全屏切换
              IconButton(
                tooltip: _isFullscreen ? '退出全屏 (F)' : '全屏 (F)',
                icon: Icon(
                  _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  color: Colors.white,
                ),
                onPressed: _toggleFullscreen,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    final colorScheme = _playerTheme.colorScheme;

    return SizedBox(
      height: 26,
      child: StreamBuilder<Duration>(
        stream: _player.stream.duration,
        initialData: _player.state.duration,
        builder: (context, durationSnap) {
          return StreamBuilder<Duration>(
            stream: _player.stream.buffer,
            initialData: _player.state.buffer,
            builder: (context, bufferSnap) {
              return StreamBuilder<Duration>(
                stream: _player.stream.position,
                initialData: _player.state.position,
                builder: (context, positionSnap) {
                  final total = durationSnap.data ?? Duration.zero;
                  return ProgressBar(
                    progress: positionSnap.data ?? Duration.zero,
                    buffered: bufferSnap.data ?? Duration.zero,
                    total: total,
                    onSeek: (position) => _player.seek(position),
                    barHeight: 4,
                    thumbRadius: 6,
                    baseBarColor: Colors.white24,
                    bufferedBarColor: Colors.white38,
                    progressBarColor: colorScheme.primary,
                    thumbColor: colorScheme.primary,
                    timeLabelLocation: TimeLabelLocation.sides,
                    timeLabelTextStyle: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSpeedMenu() {
    return StreamBuilder<double>(
      stream: _player.stream.rate,
      initialData: _player.state.rate,
      builder: (context, snapshot) => _speedMenu(snapshot.data ?? 1.0),
    );
  }

  Widget _speedMenu(double current) {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

    return PopupMenuButton<double>(
      tooltip: '倍速',
      initialValue: current,
      color: const Color(0xFF2B2830),
      onSelected: (rate) => _player.setRate(rate),
      itemBuilder:
          (context) => [
            for (final rate in rates)
              PopupMenuItem<double>(
                value: rate,
                child: Row(
                  children: [
                    SizedBox(
                      width: 28,
                      child:
                          rate == current
                              ? const Icon(
                                Icons.check,
                                size: 16,
                                color: Colors.white,
                              )
                              : null,
                    ),
                    Text(
                      '${rate}x',
                      style: TextStyle(
                        color: rate == current ? Colors.white : Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
          ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(
          '${current}x',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildVolumeMenu() {
    return StreamBuilder<double>(
      stream: _player.stream.volume,
      initialData: _player.state.volume,
      builder: (context, snap) {
        final volume = snap.data ?? 100.0;
        return PopupMenuButton<void>(
          tooltip: '音量',
          color: const Color(0xFF2B2830),
          icon: Icon(
            volume <= 0
                ? Icons.volume_off_rounded
                : volume < 50
                ? Icons.volume_down_rounded
                : Icons.volume_up_rounded,
            color: Colors.white,
          ),
          itemBuilder:
              (context) => [
                PopupMenuItem<void>(
                  enabled: false,
                  child: StreamBuilder<double>(
                    stream: _player.stream.volume,
                    initialData: _player.state.volume,
                    builder: (context, volumeSnapshot) {
                      final volume =
                          volumeSnapshot.data ?? _player.state.volume;
                      return SizedBox(
                        width: 180,
                        child: Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                volume <= 0
                                    ? Icons.volume_off_rounded
                                    : Icons.volume_up_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                              onPressed: () {
                                _player.setVolume(volume <= 0 ? 100 : 0);
                              },
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(
                                  context,
                                ).copyWith(trackHeight: 3),
                                child: Slider(
                                  value: volume.clamp(0.0, 100.0),
                                  max: 100,
                                  onChanged: (value) {
                                    _player.setVolume(value);
                                  },
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 34,
                              child: Text(
                                '${volume.round()}',
                                textAlign: TextAlign.end,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
        );
      },
    );
  }

  /// 右侧面板：弹幕来源卡占位 + 选集网格
  Widget _buildRightPanel() {
    final colorScheme = _playerTheme.colorScheme;
    final episodes = widget.episodes ?? const [];

    return Container(
      width: 320,
      color: colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 弹幕来源卡占位
          Padding(
            padding: const EdgeInsets.all(12),
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.subtitles_outlined,
                      size: 20,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '弹幕来源',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '弹弹play 未接入 · Phase 4',
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      height: 24,
                      child: Switch(
                        value: false,
                        onChanged: null, // 占位：弹幕服务未接入
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 选集标题
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              episodes.isEmpty ? '选集' : '选集 (${episodes.length})',
              style: _playerTheme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
          ),

          // 选集网格
          Expanded(
            child:
                episodes.isEmpty
                    ? Center(
                      child: Text(
                        '单集播放',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                    : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 140,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 1.55,
                          ),
                      itemCount: episodes.length,
                      itemBuilder: (context, index) {
                        final isCurrent = index == _currentIndex;
                        return GestureDetector(
                          onTap: () => _playEpisode(index),
                          child: Container(
                            decoration: BoxDecoration(
                              color:
                                  isCurrent
                                      ? colorScheme.primaryContainer
                                      : colorScheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color:
                                    isCurrent
                                        ? colorScheme.primary
                                        : Colors.transparent,
                                width: 1.5,
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            alignment: Alignment.centerLeft,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '第 ${index + 1} 集',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color:
                                        isCurrent
                                            ? colorScheme.onPrimaryContainer
                                            : colorScheme.onSurface,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  episodes[index]['title'] ?? '',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color:
                                        isCurrent
                                            ? colorScheme.onPrimaryContainer
                                                .withValues(alpha: 0.8)
                                            : colorScheme.onSurfaceVariant,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }
}
