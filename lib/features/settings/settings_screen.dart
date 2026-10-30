import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/settings_provider.dart';
import '../../providers/theme_provider.dart';
import 'source_management_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final playerSettings = ref.watch(playerSettingsProvider);
    final colors = Theme.of(context).colorScheme;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
    Widget pending(IconData icon, String title) => ListTile(
      enabled: false,
      leading: Icon(icon),
      title: Text(title),
      subtitle: const Text('尚未开放'),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              heading('主题'),
              for (final option in const [
                (ThemeMode.system, '跟随系统', Icons.brightness_auto_outlined),
                (ThemeMode.light, '浅色', Icons.light_mode_outlined),
                (ThemeMode.dark, '深色', Icons.dark_mode_outlined),
              ])
                ListTile(
                  leading: Icon(option.$3, size: 20),
                  title: Text(option.$2),
                  selected: mode == option.$1,
                  trailing:
                      mode == option.$1
                          ? Icon(Icons.check, size: 20, color: colors.primary)
                          : null,
                  onTap:
                      () => ref
                          .read(themeModeProvider.notifier)
                          .setMode(option.$1),
                ),
              const Divider(),
              heading('播放器'),
              SwitchListTile(
                secondary: const Icon(Icons.play_circle_outline, size: 20),
                title: const Text('自动播放下一集'),
                subtitle: const Text('一集播完后自动切到下一集'),
                value: playerSettings.autoPlayNext,
                onChanged:
                    ref.read(playerSettingsProvider.notifier).setAutoPlayNext,
              ),
              ListTile(
                leading: const Icon(Icons.speed, size: 20),
                title: const Text('默认播放速度'),
                subtitle: const Text('新打开的视频使用该倍速'),
                trailing: Text(
                  '${playerSettings.playbackSpeed}x',
                  style: TextStyle(color: colors.primary),
                ),
                onTap: () => _showSpeedDialog(context, ref),
              ),
              pending(Icons.subtitles_outlined, '弹幕'),
              const Divider(),
              heading('下载与数据源'),
              pending(Icons.folder_outlined, '下载路径'),
              ListTile(
                leading: const Icon(Icons.source_outlined, size: 20),
                title: const Text('源管理'),
                subtitle: const Text('启停 / 切换 / 测速 / 添加自定义源'),
                onTap:
                    () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const SourceManagementScreen(),
                      ),
                    ),
              ),
              const Divider(),
              heading('关于'),
              ListTile(
                leading: const Icon(Icons.info_outline, size: 20),
                title: const Text('NovaPlay'),
                subtitle: const Text('视频聚合播放器'),
                onTap:
                    () => showAboutDialog(
                      context: context,
                      applicationName: 'NovaPlay',
                      children: [const Text('视频聚合播放器')],
                    ),
              ),
              pending(Icons.update, '检查更新'),
            ],
          ),
        ),
      ),
    );
  }

  void _showSpeedDialog(BuildContext context, WidgetRef ref) {
    final current = ref.read(playerSettingsProvider).playbackSpeed;
    showDialog<void>(
      context: context,
      builder:
          (dialogContext) => SimpleDialog(
            title: const Text('默认播放速度'),
            children: [
              for (final speed in playbackSpeeds)
                SimpleDialogOption(
                  onPressed: () {
                    ref
                        .read(playerSettingsProvider.notifier)
                        .setPlaybackSpeed(speed);
                    Navigator.pop(dialogContext);
                  },
                  child: Row(
                    children: [
                      Text('${speed}x'),
                      const Spacer(),
                      if (speed == current)
                        Icon(
                          Icons.check,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                    ],
                  ),
                ),
            ],
          ),
    );
  }
}
