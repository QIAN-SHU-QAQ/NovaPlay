# NovaPlay

Windows 上的动漫聚合播放器，用 Flutter 和 media_kit 编写。可以浏览在线片库、搜索作品、选集播放，也能把作品加入收藏，从观看历史接着看。

目前还在开发，没有发布可下载的安装包。想试用需要从源码运行；下载和弹幕尚未接通。

![NovaPlay 深色主题，发现页](screenshots/home_dark.png)

<details>
<summary>查看浅色主题</summary>

![NovaPlay 浅色主题，发现页](screenshots/home_light.png)

</details>

[运行方法](#从源码运行) · [开发报告与待办](开发报告.md) · [反馈问题](https://github.com/QIAN-SHU-QAQ/NovaPlay/issues)

## 现在能做什么

- 浏览片库和分类，按标题搜索，查看简介与剧集列表。
- 播放在线视频，切换剧集、倍速、音量和窗口全屏；播放失败时可重试。**视频在独立的播放窗口中打开**，关掉视频窗口不会退出主界面，可以边看边浏览。
- 保存收藏、搜索历史和观看进度，从首页或历史页继续播放。
- 切换浅色、深色或跟随系统的主题，重启后保留选择。
- 在设置里管理数据源：启用/停用、切换主源、测速、添加自定义 maccms 源（主源失败自动回退到其它启用源）。
- 在详情页选集卡片上点击下载按钮，把剧集离线保存到本机（支持暂停/继续/删除，重启后任务列表保留，完成后可直接在下载页点击播放）。
- 从 Bangumi 补充评分、制作人员和角色资料，查不到时仍可查看作品和播放。

搜索可以从侧栏或发现页右上角打开。播放器使用深色控件。

播放快捷键：空格暂停或继续，`←` / `→` 快退快进，`↑` / `↓` 调整音量，`F` 全屏，`Esc` 退出全屏。

## 使用前需要知道

在线内容依赖第三方接口，作品、图片和播放地址可能失效。主源请求异常时会尝试备用源，全部失败时显示错误并支持重试；正常的空结果不会触发回退。

首页的全部列表支持继续加载，分类与搜索目前只展示第一页。Bangumi 资料按标题搜索并取首项，可能匹配到同名作品或其他季度。

下载功能已接通：详情页选集卡片右上角即可加入下载队列，下载页可查看进度、暂停/继续/删除，任务在重启后保留；完成后点击任务即可在应用内播放（也可用第三方播放器打开保存的 `.ts` 文件）。当前只支持**未加密的 m3u8 分片流**（加密流会显式报错）。弹幕和自动更新尚未支持。设置页可保存主题，并可在「源管理」中启停/切换/测速/添加自定义数据源。

收藏和观看历史保存在本机，没有账号同步。旧历史里的播放地址可能过期，此时可回到作品详情重新选集。

## 从源码运行

项目以 Windows 桌面端为开发和验证目标。准备 Git、Flutter SDK，以及带有 C++ 桌面开发组件和 Windows SDK 的 Visual Studio。

`pubspec.yaml` 要求 Dart `^3.7.2`，没有单独声明 Flutter 最低版本。本地验证使用 Windows 11、Flutter 3.29.3 / Dart 3.7.2；Visual Studio 2026 的使用依赖本地 Flutter 工具补丁，环境细节见[开发报告](开发报告.md#构建环境)。

两个在 Windows 上实际踩过的前提：

- **开启 Windows 开发者模式**（设置 → 系统 → 开发者选项）。插件构建要创建符号链接，否则 `flutter pub get` 会警告、`flutter build windows` 会直接失败。
- **项目路径不要包含中文/非 ASCII 字符**。着色器编译器（impellerc）无法写入非 ASCII 路径，构建会报 `Could not write file .../ink_sparkle.frag`。如果仓库在中文目录，可用目录联接从 ASCII 路径构建：

  ```powershell
  mklink /J E:\dev\NovaPlay "E:\项目\NovaPlay"
  cd E:\dev\NovaPlay
  flutter build windows
  ```

多窗口播放依赖 `desktop_multi_window`：其 0.3.1 用到了 Flutter 3.35+ 才有的 `DartProject::set_ui_thread_policy`，项目锁定的 Flutter 3.29.3 无法编译，因此 `third_party/desktop_multi_window/` 里 vendor 了一份并移除了该调用（见 `pubspec.yaml` 注释）。升级 Flutter 后可以改回 pub 依赖。

在 PowerShell 中运行：

```powershell
git clone https://github.com/QIAN-SHU-QAQ/NovaPlay.git
cd NovaPlay
flutter doctor -v
flutter pub get
flutter run -d windows
```

如果下载依赖遇到网络问题，可以先在当前 PowerShell 会话设置镜像，再执行 `flutter pub get`：

```powershell
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
```

### 检查与构建

```powershell
flutter analyze
flutter test
flutter build windows --release
```

仓库已配置 GitHub Actions（`.github/workflows/ci.yml`）：每次 push / PR 会检查格式（`dart format --set-exit-if-changed`）、`flutter analyze` 与 `flutter test`。

测试使用离线替身，不需要请求在线片库。实际播放与第三方接口的可用性需要另行实测。

构建目录为 `build/windows/x64/runner/Release/`。运行或复制程序时，请保留整个目录，包括 DLL 和 `data/`；只复制 `nova_play.exe` 无法正常运行。

## 继续开发

接下来先补分类与搜索分页、设置持久化、作品资料匹配和失效地址续播，再做弹幕及发布流程（msix/自动更新）。具体边界和验收条件放在[开发报告](开发报告.md)，提交记录保留了早期开发过程。

报告问题时，附上 Windows 版本、操作步骤、出错页面和错误信息；涉及播放时补充作品、集数及是否能重现。请勿提交个人凭据。

代码采用 [MIT 许可](LICENSE)。应用从第三方接口读取内容，仓库不托管视频；视频、海报和作品资料的权利归各自权利人。
