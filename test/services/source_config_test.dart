import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/services/scraper/source_config.dart';

void main() {
  test('内置默认源：两个且默认启用', () {
    final configs = SourceConfig.defaults();
    expect(configs.length, 2);
    expect(configs.every((c) => c.enabled), isTrue);
    expect(configs.first.baseUrl, contains('/api.php/provide/vod'));
  });

  test('JSON 序列化可往返', () {
    const source = SourceConfig(
      id: 'custom_1',
      name: '测试源',
      baseUrl: 'https://example.com/api.php/provide/vod/',
      enabled: false,
    );
    final restored = SourceConfig.fromJson(source.toJson());
    expect(restored.id, 'custom_1');
    expect(restored.name, '测试源');
    expect(restored.baseUrl, 'https://example.com/api.php/provide/vod/');
    expect(restored.enabled, isFalse);
  });

  test('copyWith 只修改指定字段', () {
    final source = SourceConfig.defaults().first;
    final disabled = source.copyWith(enabled: false);
    expect(disabled.enabled, isFalse);
    expect(disabled.id, source.id);
    expect(disabled.name, source.name);
    expect(disabled.baseUrl, source.baseUrl);
  });
}
