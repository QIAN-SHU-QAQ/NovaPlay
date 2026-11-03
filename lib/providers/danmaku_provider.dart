import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/database_service.dart';

class DanmakuSettingsState {
  final bool enabled;
  final String appId;
  final String appSecret;
  final double opacity;
  final double fontSize;
  final double area;

  const DanmakuSettingsState({
    required this.enabled,
    required this.appId,
    required this.appSecret,
    required this.opacity,
    required this.fontSize,
    required this.area,
  });

  bool get hasCredentials =>
      appId.trim().isNotEmpty && appSecret.trim().isNotEmpty;

  DanmakuSettingsState copyWith({
    bool? enabled,
    String? appId,
    String? appSecret,
    double? opacity,
    double? fontSize,
    double? area,
  }) {
    return DanmakuSettingsState(
      enabled: enabled ?? this.enabled,
      appId: appId ?? this.appId,
      appSecret: appSecret ?? this.appSecret,
      opacity: opacity ?? this.opacity,
      fontSize: fontSize ?? this.fontSize,
      area: area ?? this.area,
    );
  }
}

/// 弹幕开关、dandanplay 凭据与显示样式，全部持久化到本地。
class DanmakuSettingsNotifier extends StateNotifier<DanmakuSettingsState> {
  DanmakuSettingsNotifier()
    : super(
        DanmakuSettingsState(
          enabled: DatabaseService().getDanmakuEnabled(),
          appId: DatabaseService().getDanmakuAppId(),
          appSecret: DatabaseService().getDanmakuAppSecret(),
          opacity: DatabaseService().getDanmakuOpacity(),
          fontSize: DatabaseService().getDanmakuFontSize(),
          area: DatabaseService().getDanmakuArea(),
        ),
      );

  Future<void> setEnabled(bool value) async {
    if (!mounted) return;
    state = state.copyWith(enabled: value);
    await DatabaseService().setDanmakuEnabled(value);
  }

  Future<void> saveCredentials(String appId, String appSecret) async {
    if (!mounted) return;
    final trimmedId = appId.trim();
    final trimmedSecret = appSecret.trim();
    state = state.copyWith(appId: trimmedId, appSecret: trimmedSecret);
    await DatabaseService().setDanmakuAppId(trimmedId);
    await DatabaseService().setDanmakuAppSecret(trimmedSecret);
  }

  Future<void> setOpacity(double value) async {
    if (!mounted) return;
    state = state.copyWith(opacity: value.clamp(0.2, 1.0));
    await DatabaseService().setDanmakuOpacity(value);
  }

  Future<void> setFontSize(double value) async {
    if (!mounted) return;
    state = state.copyWith(fontSize: value.clamp(10.0, 32.0));
    await DatabaseService().setDanmakuFontSize(value);
  }

  Future<void> setArea(double value) async {
    if (!mounted) return;
    state = state.copyWith(area: value.clamp(0.2, 1.0));
    await DatabaseService().setDanmakuArea(value);
  }
}

final danmakuSettingsProvider =
    StateNotifierProvider<DanmakuSettingsNotifier, DanmakuSettingsState>((ref) {
      return DanmakuSettingsNotifier();
    });
