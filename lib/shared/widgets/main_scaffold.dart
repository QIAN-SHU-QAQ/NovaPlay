import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Branch indices follow routes.dart. Search is a full-window route.
class MainScaffold extends StatelessWidget {
  const MainScaffold({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final current = navigationShell.currentIndex;
    void go(int index) =>
        navigationShell.goBranch(index, initialLocation: index == current);
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            SizedBox(
              width: 184,
              child: ColoredBox(
                color: colors.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 29, 8, 31),
                        child: Row(
                          children: [
                            Icon(
                              Icons.play_arrow_rounded,
                              color: colors.primary,
                              size: 26,
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'NovaPlay',
                                  style: TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: -0.7,
                                    color: colors.onSurface,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _NavigationItem(
                        icon: Icons.search_rounded,
                        label: '搜索',
                        onTap: () => context.push('/search'),
                      ),
                      const SizedBox(height: 25),
                      _NavigationItem(
                        icon: Icons.grid_view_outlined,
                        label: '发现',
                        selected: current == 0,
                        onTap: () => go(0),
                      ),
                      const SizedBox(height: 5),
                      _NavigationItem(
                        icon: Icons.favorite_border_rounded,
                        label: '收藏',
                        selected: current == 1,
                        onTap: () => go(1),
                      ),
                      const SizedBox(height: 5),
                      _NavigationItem(
                        icon: Icons.history_rounded,
                        label: '历史',
                        selected: current == 3,
                        onTap: () => go(3),
                      ),
                      const SizedBox(height: 5),
                      _NavigationItem(
                        icon: Icons.download_outlined,
                        label: '下载',
                        selected: current == 2,
                        onTap: () => go(2),
                      ),
                      const Spacer(),
                      Divider(color: colors.outlineVariant),
                      const SizedBox(height: 12),
                      _NavigationItem(
                        icon: Icons.settings_outlined,
                        label: '设置',
                        selected: current == 4,
                        onTap: () => go(4),
                      ),
                      const SizedBox(height: 18),
                    ],
                  ),
                ),
              ),
            ),
            VerticalDivider(width: 1, color: colors.outlineVariant),
            Expanded(child: navigationShell),
          ],
        ),
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? colors.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          mouseCursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color:
                      selected
                          ? colors.onPrimaryContainer
                          : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    color:
                        selected ? colors.onPrimaryContainer : colors.onSurface,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
