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
- 播放在线视频，切换剧集、倍速、音量和窗口全屏；播放失败时可重试。
- 保存收藏、搜索历史和观看进度，从首页或历史页继续播放。
- 切换浅色、深色或跟随系统的主题，重启后保留选择。
- 从 Bangumi 补充评分、制作人员和角色资料，查不到时仍可查看作品和播放。

搜索可以从侧栏或发现页右上角打开。播放器使用深色控件。

播放快捷键：空格暂停或继续，`←` / `→` 快退快进，`↑` / `↓` 调整音量，`F` 全屏，`Esc` 退出全屏。

## 使用前需要知道

在线内容依赖第三方接口，作品、图片和播放地址可能失效。主源请求异常时会尝试备用源，全部失败时显示错误并支持重试；正常的空结果不会触发回退。

首页的全部列表支持继续加载，分类与搜索目前只展示第一页。Bangumi 资料按标题搜索并取首项，可能匹配到同名作品或其他季度。

下载页会说明功能尚未开放，不会生成下载任务。设置页目前可保存主题，其余未实现选项已禁用。弹幕、源管理和自动更新也还不能使用。

收藏和观看历史保存在本机，没有账号同步。旧历史里的播放地址可能过期，此时可回到作品详情重新选集。

## 从源码运行

项目以 Windows 桌面端为开发和验证目标。准备 Git、Flutter SDK，以及带有 C++ 桌面开发组件和 Windows SDK 的 Visual Studio。

`pubspec.yaml` 要求 Dart `^3.7.2`，没有单独声明 Flutter 最低版本。本地验证使用 Windows 11、Flutter 3.29.3 / Dart 3.7.2；Visual Studio 2026 的使用依赖本地 Flutter 工具补丁，环境细节见[开发报告](开发报告.md#构建环境)。

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

测试使用离线替身，不需要请求在线片库。实际播放与第三方接口的可用性需要另行实测。

构建目录为 `build/windows/x64/runner/Release/`。运行或复制程序时，请保留整个目录，包括 DLL 和 `data/`；只复制 `nova_play.exe` 无法正常运行。

## 继续开发

接下来先补分类与搜索分页、设置持久化、作品资料匹配和失效地址续播，再做 HLS 下载、弹幕及发布流程。具体边界和验收条件放在[开发报告](开发报告.md)，提交记录保留了早期开发过程。

报告问题时，附上 Windows 版本、操作步骤、出错页面和错误信息；涉及播放时补充作品、集数及是否能重现。请勿提交个人凭据。

代码采用 [MIT 许可](LICENSE)。应用从第三方接口读取内容，仓库不托管视频；视频、海报和作品资料的权利归各自权利人。
