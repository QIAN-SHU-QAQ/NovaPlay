# NovaPlay

Windows 上的动漫聚合播放器，用 Flutter 和 media_kit 编写。可以浏览在线片库、搜索作品、选集播放，也能把作品加入收藏，从观看历史接着看。

目前仍在开发，可从源码运行或自行构建 Windows 运行版。分类与搜索分页、独立播放窗口、HLS 离线下载及可选弹幕已合入；发布前仍需修复下方列出的已知问题。可下载版本以[主仓库 Releases](https://github.com/QIAN-SHU-QAQ/NovaPlay/releases) 为准。

![NovaPlay 深色主题，发现页](screenshots/home_dark.png)

<details>
<summary>查看浅色主题</summary>

![NovaPlay 浅色主题，发现页](screenshots/home_light.png)

</details>

[运行方法](#从源码运行) · [开发报告与待办](开发报告.md) · [反馈问题](https://github.com/QIAN-SHU-QAQ/NovaPlay/issues)

## 现在能做什么

- 浏览片库和分类，按标题搜索，查看简介与剧集列表；分类与搜索结果都支持无限滚动分页加载。
- 播放在线视频，切换剧集、倍速、音量和窗口全屏；播放失败时可重试。**视频在独立的播放窗口中打开**，关掉视频窗口不会退出主界面，可以边看边浏览；可在设置里开启「自动播放下一集」并配置默认倍速。
- 播放时显示弹幕：数据来自弹弹play 开放弹幕网络，按作品名/集数自动匹配；在设置里填写免费的 AppId/AppSecret 后可调整透明度、字号、显示区域，播放器内可一键开关。
- 保存收藏、搜索历史和观看进度，从首页或历史页继续播放；当前独立播放进程的历史同步存在缺陷，详见[已知问题](#已知问题)。
- 切换浅色、深色或跟随系统的主题，重启后保留选择。
- 在设置里管理数据源：启用/停用、切换主源、测速、添加自定义 maccms 源（主源失败自动回退到其它启用源）。
- 在详情页选集卡片上点击下载按钮，把剧集离线保存到本机（支持暂停/继续/删除、在文件夹中显示，重启后任务列表保留，完成后可直接在下载页点击播放）。
- 从 Bangumi 补充评分、制作人员和角色资料，查不到时仍可查看作品和播放。

搜索可以从侧栏或发现页右上角打开。播放器使用深色控件。

播放快捷键：空格暂停或继续，`←` / `→` 快退快进，`↑` / `↓` 调整音量，`F` 全屏，`Esc` 退出全屏。

## 使用前需要知道

在线内容依赖第三方接口，作品、图片和播放地址可能失效。主源请求异常时会尝试备用源，全部失败时显示错误并支持重试；正常的空结果不会触发回退。

首页、分类和搜索结果都支持继续加载。Bangumi 资料按标题搜索并取首项，可能匹配到同名作品或其他季度。

弹幕为可选功能：需要先在[弹弹play 开发者中心](https://dev.dandanplay.com)免费申请 AppId/AppSecret，填入「设置 → 弹幕 → 弹弹play 账号」。未配置时不会加载弹幕，播放器右侧会显示提示。弹幕按作品名 + 集数自动匹配，作品标题差异较大（如改名、剧场版）时可能匹配不到；匹配结果会显示在播放器右侧面板底部。

下载功能已接通：详情页选集卡片旁的下载按钮可加入队列，下载页支持暂停、继续、删除和在文件夹中显示，任务在重启后保留。完成后点击任务即可在应用内播放，也可用第三方播放器打开保存的 `.ts` 文件。文件默认保存在系统“文档”目录下的 `NovaPlay/Downloads/`。当前只支持**未加密的 m3u8 分片流**，加密流会显式报错。

设置页可保存主题、配置自动连播与默认倍速，并可在「源管理」中启停、切换、测速或添加自定义数据源。应用内自动更新尚未实现。

收藏和观看历史保存在本机，没有账号同步。旧历史里的播放地址可能过期，此时可回到作品详情重新选集。

播放窗口是独立进程：每打开一个播放窗口都会启动一个 NovaPlay 进程，关闭播放窗口只结束对应进程，主窗口仍可继续浏览。

### 已知问题

2026-11-03 对合并提交 `25d3082` 的 Windows 实机检验发现：

- **观看历史可能丢失。** 独立播放器已经写入磁盘的新记录，返回主窗口后仍未显示；随后在主窗口修改“自动播放下一集”等设置，会以旧缓存覆盖配置文件，导致新历史丢失。当前的重新加载逻辑尚未解决 Windows 下的跨进程缓存问题，这是发布前需要优先修复的缺陷。
- **暂停下载会重置进度显示。** 下载到 67% 时暂停，进度显示及保存值会变成 0%；已完成分片仍保留，继续下载后能恢复进度并完成。

上述问题尚未修复。第三方片源失效、旧历史播放地址过期及 Bangumi 同名作品误匹配，也仍需在使用中留意。

## 从源码运行

项目以 Windows 桌面端为开发和验证目标。准备 Git、Flutter SDK，以及带有 C++ 桌面开发组件和 Windows SDK 的 Visual Studio。

`pubspec.yaml` 要求 Dart `^3.7.2`，没有单独声明 Flutter 最低版本。本地验证使用 Windows 11、Flutter 3.29.3 / Dart 3.7.2；Visual Studio 2026 的使用依赖本地 Flutter 工具补丁，环境细节见[开发报告](开发报告.md#构建环境)。

两个在 Windows 上实际踩过的前提：

- **开启 Windows 开发者模式**（设置 → 系统 → 开发者选项）。插件构建要创建符号链接，否则 `flutter pub get` 会警告、`flutter build windows` 会直接失败。
- **项目路径不要包含中文/非 ASCII 字符**。着色器编译器（impellerc）无法写入非 ASCII 路径，构建会报 `Could not write file .../ink_sparkle.frag`。如果仓库在中文目录，可用目录联接从 ASCII 路径构建：

  ```powershell
  New-Item -ItemType Directory -Path E:\dev -Force
  New-Item -ItemType Junction -Path E:\dev\NovaPlay -Target "E:\项目\NovaPlay"
  Set-Location E:\dev\NovaPlay
  flutter build windows
  ```

在 PowerShell 中运行：

```powershell
git clone https://github.com/QIAN-SHU-QAQ/NovaPlay.git
cd NovaPlay
flutter doctor -v
flutter pub get --enforce-lockfile
flutter run -d windows
```

如果下载依赖遇到网络问题，可以先在当前 PowerShell 会话设置镜像，再执行 `flutter pub get`：

```powershell
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
```

切换包源后请检查 `pubspec.lock` 的差异，避免把源切换引起的依赖版本变化混入其他修改。复现下面的检验结果时，应使用仓库锁定的版本。

### 检查与构建

```powershell
flutter analyze
flutter test
flutter build windows --release
```

仓库已配置 GitHub Actions（`.github/workflows/ci.yml`）：每次 push / PR 会检查格式（`dart format --set-exit-if-changed`）、`flutter analyze` 与 `flutter test`。

测试使用离线替身，不需要请求在线片库。实际播放与第三方接口的可用性需要另行实测。

2026-11-03 在 Windows、Flutter 3.29.3 / Dart 3.7.2 下，针对提交 `25d3082` 使用锁定依赖完成检验：

| 检查 | 结果 |
| --- | --- |
| Dart 格式检查 | 76 个文件，0 修改 |
| `flutter analyze` | 无问题 |
| `flutter test` | 114 个测试全部通过 |
| Windows Release 构建 | 成功 |
| 实机交互 | 在线播放、主窗口与播放器独立操作、全屏按钮及 Esc 恢复、分类和搜索第二页、HLS 下载、离线播放、暂停后重启续传均通过；自动切集及窗口标题更新已验证 |

分页和下载实测使用本地测试源与公开 HLS 样片，在线播放另使用内置真实片源。**没有有效的弹弹play AppId/AppSecret，本轮未验证真实弹幕服务的鉴权、匹配和滚动效果。** 自动测试全部通过，仍不代表[已知问题](#已知问题)已经解决。

构建目录为 `build/windows/x64/runner/Release/`。运行或复制程序时，请保留整个目录，包括 DLL 和 `data/`；只复制 `nova_play.exe` 无法正常运行。

## 参考

弹幕功能选型时做过的调研（结论：渲染直接用 MIT 依赖，数据协议自行实现）：

| 项目或文档 | 本项目中的用途 |
| --- | --- |
| [Predidit/canvas_danmaku](https://github.com/Predidit/canvas_danmaku) | 直接依赖，使用 Dart Canvas 渲染弹幕 |
| [Predidit/Kazumi](https://github.com/Predidit/Kazumi) | 流程参考，未直接复用代码 |
| [open-ani/animeko](https://github.com/open-ani/animeko) | 协议实现参考，未直接复用代码 |
| [弹弹play 开放 API](https://doc.dandanplay.com/open/) | 弹幕数据来源，需要配置 AppId/AppSecret |

## 继续开发

先修复观看历史的跨进程存储问题和下载暂停时的进度显示，再补真实弹幕服务验证。后续再考虑手动选择弹幕匹配结果、屏蔽词、发布打包、自动更新及依赖升级。

分页、播放设置、下载与弹幕的基础实现已随 [PR #3](https://github.com/QIAN-SHU-QAQ/NovaPlay/pull/3) 合入。[开发报告](开发报告.md)和早期开发计划中的待办需要按当前实现重新核对，不能再将这些功能全部视为尚未实现。

报告问题时，附上 Windows 版本、操作步骤、出错页面和错误信息；涉及播放时补充作品、集数及是否能重现。请勿提交个人凭据。

代码采用 [MIT 许可](LICENSE)。应用从第三方接口读取内容，仓库不托管视频；视频、海报和作品资料的权利归各自权利人。
