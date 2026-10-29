import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 桌面端骨架：左侧 NavigationRail + 内容区圆角面板浮在底色上。
/// 分支顺序与 routes.dart 的 shell branches 一一对应（设置固定为最后一个分支）。
class MainScaffold extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const MainScaffold({super.key, required this.navigationShell});

  static const _settingsIndex = 4;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final currentIndex = navigationShell.currentIndex;

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainer,
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              // 设置是自定义置底项（不在 destinations 里）：
              // 停在设置分支时传 null，避免 selectedIndex 越界（release 下会灰屏）
              selectedIndex:
                  currentIndex < _settingsIndex ? currentIndex : null,
              onDestinationSelected: (index) => navigationShell.goBranch(
                index,
                initialLocation: index == navigationShell.currentIndex,
              ),
              labelType: NavigationRailLabelType.all,
              groupAlignment: -1.0,
              leading: Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 16),
                child: _RailLogo(colorScheme: colorScheme),
              ),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.explore_outlined),
                  selectedIcon: Icon(Icons.explore),
                  label: Text('首页'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.favorite_border_rounded),
                  selectedIcon: Icon(Icons.favorite_rounded),
                  label: Text('收藏'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.download_outlined),
                  selectedIcon: Icon(Icons.download_rounded),
                  label: Text('下载'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.history_rounded),
                  selectedIcon: Icon(Icons.history),
                  label: Text('历史'),
                ),
              ],
              // 设置置底：trailing 占满剩余空间，把入口推到导航栏最下
              trailing: Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _RailSettingsItem(
                      selected: currentIndex == _settingsIndex,
                      colorScheme: colorScheme,
                      onTap: () => navigationShell.goBranch(
                        _settingsIndex,
                        initialLocation: currentIndex == _settingsIndex,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: colorScheme.shadow.withValues(alpha: 0.08),
                        blurRadius: 16,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: navigationShell,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailLogo extends StatelessWidget {
  final ColorScheme colorScheme;

  const _RailLogo({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [colorScheme.primary, colorScheme.tertiary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(
        Icons.play_arrow_rounded,
        color: Colors.white,
        size: 26,
      ),
    );
  }
}

/// 设置入口：仿 rail destination 样式（指示胶囊 + 图标 + 文字），固定在栏底
class _RailSettingsItem extends StatelessWidget {
  final bool selected;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _RailSettingsItem({
    required this.selected,
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = selected
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;
    final labelColor =
        selected ? colorScheme.onSurface : colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? colorScheme.primaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              selected ? Icons.settings_rounded : Icons.settings_outlined,
              color: iconColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '设置',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: labelColor,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
          ),
        ],
      ),
    );
  }
}
