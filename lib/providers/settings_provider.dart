import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/database_service.dart';

/// 播放器可选的倍速列表（设置页与播放器菜单共用）。
const List<double> playbackSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

double normalizePlaybackSpeed(double speed) =>
    playbackSpeeds.contains(speed) ? speed : 1.0;

class PlayerSettingsState {
  final bool autoPlayNext;
  final double playbackSpeed;

  const PlayerSettingsState({
    required this.autoPlayNext,
    required this.playbackSpeed,
  });

  PlayerSettingsState copyWith({bool? autoPlayNext, double? playbackSpeed}) {
    return PlayerSettingsState(
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
    );
  }
}

/// 播放器设置：自动连播、默认倍速，持久化到本地。
class PlayerSettingsNotifier extends StateNotifier<PlayerSettingsState> {
  PlayerSettingsNotifier()
    : super(
        PlayerSettingsState(
          autoPlayNext: DatabaseService().getAutoPlay(),
          playbackSpeed: normalizePlaybackSpeed(
            DatabaseService().getPlaybackSpeed(),
          ),
        ),
      );

  Future<void> setAutoPlayNext(bool value) async {
    if (!mounted) return;
    state = state.copyWith(autoPlayNext: value);
    await DatabaseService().setAutoPlay(value);
  }

  Future<void> setPlaybackSpeed(double value) async {
    if (!mounted) return;
    final speed = normalizePlaybackSpeed(value);
    state = state.copyWith(playbackSpeed: speed);
    await DatabaseService().setPlaybackSpeed(speed);
  }
}

final playerSettingsProvider =
    StateNotifierProvider<PlayerSettingsNotifier, PlayerSettingsState>((ref) {
      return PlayerSettingsNotifier();
    });
