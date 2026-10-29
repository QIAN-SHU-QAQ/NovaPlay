import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/theme_provider.dart';

/// 设置页：左栏分组导航 + 右栏内容面板；主题三选卡接 themeModeProvider。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int _selectedSection = 0;

  // 占位状态：播放器/下载相关设置仍为本地演示（持久化属 Phase 3 顺手项）
  bool _autoPlay = true;
  bool _danmakuEnabled = true;
  String _defaultQuality = '1080P';
  final String _downloadPath = 'D:\\Downloads\\NovaPlay';

  static const _sections = [
    (icon: Icons.palette_outlined, label: '外观'),
    (icon: Icons.play_circle_outline, label: '播放器'),
    (icon: Icons.download_outlined, label: '下载'),
    (icon: Icons.source_outlined, label: '数据源'),
    (icon: Icons.info_outline, label: '关于'),
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左栏：分组导航
          SizedBox(
            width: 190,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 24),
              children: [
                for (var i = 0; i < _sections.length; i++)
                  _buildNavItem(i, colorScheme),
              ],
            ),
          ),
          const VerticalDivider(width: 1),

          // 右栏：所选分组内容
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                switch (_selectedSection) {
                  0 => _buildAppearanceSection(),
                  1 => _buildPlayerSection(),
                  2 => _buildDownloadSection(),
                  3 => _buildSourceSection(),
                  _ => _buildAboutSection(),
                },
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 左栏导航 ----------

  Widget _buildNavItem(int index, ColorScheme colorScheme) {
    final selected = index == _selectedSection;
    final section = _sections[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? colorScheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _selectedSection = index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  section.icon,
                  size: 20,
                  color: selected
                      ? colorScheme.onSecondaryContainer
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Text(
                  section.label,
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    color: selected
                        ? colorScheme.onSecondaryContainer
                        : colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 外观 ----------

  Widget _buildAppearanceSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('主题'),
        const SizedBox(height: 8),
        _buildThemeCard(),
        const SizedBox(height: 16),
        _sectionTitle('语言'),
        const SizedBox(height: 8),
        _buildListTile(
          icon: Icons.language,
          title: '简体中文',
          subtitle: '跟随系统语言',
          onTap: () {},
        ),
      ],
    );
  }

  Widget _buildThemeCard() {
    final currentMode = ref.watch(themeModeProvider);
    final colorScheme = Theme.of(context).colorScheme;

    final options = [
      (mode: ThemeMode.system, icon: Icons.brightness_auto_outlined, label: '跟随系统'),
      (mode: ThemeMode.light, icon: Icons.light_mode_outlined, label: '浅色'),
      (mode: ThemeMode.dark, icon: Icons.dark_mode_outlined, label: '深色'),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            for (final option in options) ...[
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () =>
                      ref.read(themeModeProvider.notifier).setMode(option.mode),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: currentMode == option.mode
                            ? colorScheme.primary
                            : colorScheme.outlineVariant,
                        width: currentMode == option.mode ? 2 : 1,
                      ),
                      color: currentMode == option.mode
                          ? colorScheme.primary.withValues(alpha: 0.06)
                          : null,
                    ),
                    child: Column(
                      children: [
                        Icon(
                          option.icon,
                          color: currentMode == option.mode
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          option.label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: currentMode == option.mode
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: currentMode == option.mode
                                ? colorScheme.primary
                                : colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Icon(
                          currentMode == option.mode
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          size: 16,
                          color: currentMode == option.mode
                              ? colorScheme.primary
                              : colorScheme.outline,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (option != options.last) const SizedBox(width: 12),
            ],
          ],
        ),
      ),
    );
  }

  // ---------- 播放器 ----------

  Widget _buildPlayerSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('播放'),
        const SizedBox(height: 8),
        _buildSwitchTile(
          icon: Icons.play_circle_outline,
          title: '自动播放',
          subtitle: '自动播放下一集',
          value: _autoPlay,
          onChanged: (value) => setState(() => _autoPlay = value),
        ),
        _buildSwitchTile(
          icon: Icons.subtitles,
          title: '弹幕',
          subtitle: '显示弹幕（Phase 4 接入）',
          value: _danmakuEnabled,
          onChanged: (value) => setState(() => _danmakuEnabled = value),
        ),
        _buildListTile(
          icon: Icons.high_quality,
          title: '默认画质',
          subtitle: _defaultQuality,
          onTap: _showQualityDialog,
        ),
        _buildListTile(
          icon: Icons.speed,
          title: '默认播放速度',
          subtitle: '1.0x',
          onTap: () {},
        ),
      ],
    );
  }

  // ---------- 下载 ----------

  Widget _buildDownloadSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('下载'),
        const SizedBox(height: 8),
        _buildListTile(
          icon: Icons.folder_outlined,
          title: '下载路径',
          subtitle: _downloadPath,
          onTap: () {},
        ),
        _buildListTile(
          icon: Icons.download,
          title: '同时下载数',
          subtitle: '3',
          onTap: () {},
        ),
      ],
    );
  }

  // ---------- 数据源 ----------

  Widget _buildSourceSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('数据源'),
        const SizedBox(height: 8),
        _buildListTile(
          icon: Icons.source,
          title: '源管理',
          subtitle: '管理视频数据源',
          onTap: () {},
        ),
        _buildListTile(
          icon: Icons.add_circle_outline,
          title: '添加自定义源',
          subtitle: '导入第三方数据源',
          onTap: () {},
        ),
      ],
    );
  }

  // ---------- 关于 ----------

  Widget _buildAboutSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('关于'),
        const SizedBox(height: 8),
        _buildListTile(
          icon: Icons.info_outline,
          title: '关于 NovaPlay',
          subtitle: '版本 1.0.0',
          onTap: _showAboutDialog,
        ),
        _buildListTile(
          icon: Icons.update,
          title: '检查更新',
          subtitle: '当前已是最新版本',
          onTap: () {},
        ),
        _buildListTile(
          icon: Icons.description_outlined,
          title: '用户协议',
          onTap: () {},
        ),
        _buildListTile(
          icon: Icons.privacy_tip_outlined,
          title: '隐私政策',
          onTap: () {},
        ),
      ],
    );
  }

  // ---------- 通用小部件 ----------

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
    );
  }

  Widget _buildListTile({
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: colorScheme.onSurfaceVariant),
        title: Text(title),
        subtitle: subtitle != null
            ? Text(
                subtitle,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  fontSize: 12,
                ),
              )
            : null,
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: onTap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: SwitchListTile(
        secondary: Icon(icon, color: colorScheme.onSurfaceVariant),
        title: Text(title),
        subtitle: subtitle != null
            ? Text(
                subtitle,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  fontSize: 12,
                ),
              )
            : null,
        value: value,
        onChanged: onChanged,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }

  // ---------- 对话框 ----------

  void _showQualityDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('默认画质'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: ['4K', '1080P', '720P', '480P', '自动'].map((quality) {
              return RadioListTile<String>(
                title: Text(quality),
                value: quality,
                groupValue: _defaultQuality,
                onChanged: (value) {
                  setState(() => _defaultQuality = value!);
                  Navigator.pop(context);
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  void _showAboutDialog() {
    final colorScheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('关于 NovaPlay'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [colorScheme.primary, colorScheme.tertiary],
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 48,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'NovaPlay',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '版本 1.0.0',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '一款现代化的视频聚合播放器',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }
}
