import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/scraper_provider.dart';
import '../../services/database_service.dart';
import '../../services/scraper/lziapi_scraper.dart';
import '../../services/scraper/source_config.dart';

/// 数据源管理：内置源启停/切换/测速，支持添加自定义 maccms 源。
class SourceManagementScreen extends ConsumerStatefulWidget {
  const SourceManagementScreen({super.key});

  @override
  ConsumerState<SourceManagementScreen> createState() =>
      _SourceManagementScreenState();
}

class _SourceManagementScreenState
    extends ConsumerState<SourceManagementScreen> {
  Future<void> _selectSource(String id) async {
    await DatabaseService().setActiveSourceId(id);
    if (!mounted) return;
    ref.read(sourceVersionProvider.notifier).state++;
  }

  Future<void> _toggleSource(SourceConfig source, bool enabled) async {
    final db = DatabaseService();
    final sources =
        db
            .getSources()
            .map((s) => s.id == source.id ? s.copyWith(enabled: enabled) : s)
            .toList();
    if (!sources.any((s) => s.enabled)) {
      _snack('至少保留一个启用的数据源');
      return;
    }
    await db.saveSources(sources);
    if (!mounted) return;
    ref.read(sourceVersionProvider.notifier).state++;
  }

  Future<void> _deleteSource(SourceConfig source) async {
    final db = DatabaseService();
    final sources = db.getSources().where((s) => s.id != source.id).toList();
    if (sources.isEmpty) {
      _snack('至少保留一个数据源');
      return;
    }
    await db.saveSources(sources);
    if (db.getActiveSourceId() == source.id) {
      final fallback = sources.firstWhere(
        (s) => s.enabled,
        orElse: () => sources.first,
      );
      await db.setActiveSourceId(fallback.id);
    }
    if (!mounted) return;
    ref.read(sourceVersionProvider.notifier).state++;
    _snack('已删除 ${source.name}');
  }

  Future<void> _testSource(SourceConfig source) async {
    _snack('正在测试 ${source.name} ...');
    final started = DateTime.now();
    try {
      final videos = await LziApiScraper(
        primary: source,
      ).getHome(page: 1).timeout(const Duration(seconds: 15));
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      _snack(
        videos.isEmpty
            ? '${source.name}：可连接，但没有返回数据'
            : '${source.name}：正常，${videos.length} 条 / ${elapsed}ms',
      );
    } catch (e) {
      _snack('${source.name}：失败（$e）');
    }
  }

  Future<void> _showAddDialog() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('添加数据源'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                TextField(
                  controller: urlController,
                  decoration: const InputDecoration(
                    labelText: 'maccms API 地址',
                    hintText: 'https://example.com/api.php/provide/vod/',
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('添加'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    final name = nameController.text.trim();
    var url = urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      _snack('名称和地址不能为空');
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      _snack('地址需以 http(s):// 开头');
      return;
    }
    if (!url.endsWith('/')) url = '$url/';

    final db = DatabaseService();
    final sources = [
      ...db.getSources(),
      SourceConfig(
        id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        baseUrl: url,
      ),
    ];
    await db.saveSources(sources);
    if (!mounted) return;
    ref.read(sourceVersionProvider.notifier).state++;
    _snack('已添加 $name');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(sourceConfigsProvider);
    final active = ref.watch(activeSourceConfigProvider);
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('数据源管理')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Text(
                '当前主源：${active.name}。主源失败时会自动回退到其它启用的源；'
                '源失效时可在这里切换或补充新源。',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(height: 12),
              for (final source in sources) _sourceTile(source, active.id),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: const Text('添加自定义源'),
                subtitle: const Text('填入 maccms 风格 API 地址'),
                onTap: _showAddDialog,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sourceTile(SourceConfig source, String activeId) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          ListTile(
            leading: Radio<String>(
              value: source.id,
              groupValue: activeId,
              onChanged:
                  source.enabled ? (_) => _selectSource(source.id) : null,
            ),
            title: Text(source.name),
            subtitle: Text(
              source.baseUrl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            trailing: Switch(
              value: source.enabled,
              onChanged: (value) => _toggleSource(source, value),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: () => _testSource(source),
                icon: const Icon(Icons.speed, size: 18),
                label: const Text('测试'),
              ),
              TextButton.icon(
                onPressed: () => _deleteSource(source),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除'),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
    );
  }
}
