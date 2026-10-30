import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/providers/danmaku_provider.dart';
import 'package:nova_play/services/database_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('弹幕设置：默认值、凭据与样式持久化', () async {
    SharedPreferences.setMockInitialValues({});
    await (DatabaseService()..resetForTest()).init();

    final notifier = DanmakuSettingsNotifier();
    addTearDown(notifier.dispose);

    expect(notifier.state.enabled, isTrue);
    expect(notifier.state.hasCredentials, isFalse);
    expect(notifier.state.opacity, 1.0);
    expect(notifier.state.fontSize, 16.0);
    expect(notifier.state.area, 1.0);

    await notifier.saveCredentials(' app-id ', ' secret ');
    expect(notifier.state.appId, 'app-id');
    expect(notifier.state.appSecret, 'secret');
    expect(notifier.state.hasCredentials, isTrue);

    await notifier.setEnabled(false);
    await notifier.setOpacity(0.5);
    await notifier.setFontSize(24);
    await notifier.setArea(0.6);
    await notifier.setOpacity(5); // 越界被 clamp
    expect(notifier.state.opacity, 1.0);
    expect(notifier.state.area, 0.6);

    // 重启后从磁盘恢复
    final restored = DanmakuSettingsNotifier();
    addTearDown(restored.dispose);
    expect(restored.state.enabled, isFalse);
    expect(restored.state.appId, 'app-id');
    expect(restored.state.fontSize, 24);
    expect(restored.state.area, 0.6);
  });
}
