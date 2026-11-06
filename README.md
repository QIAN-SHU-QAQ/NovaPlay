# NovaPlay

Windows 上的动漫聚合播放器，用 Flutter 和 media_kit 编写。可以浏览在线片库、搜索作品、选集播放，也能把作品加入收藏，从观看历史接着看。

目前仍在开发，可从源码运行或自行构建 Windows 运行版。分类与搜索分页、独立播放窗口、HLS 离线下载及可选弹幕已合入；跨进程历史保存、下载暂停进度及播放器重连问题已分轮修复并完成回归，具体验证范围见下方。可下载版本以[主仓库 Releases](https://github.com/QIAN-SHU-QAQ/NovaPlay/releases) 为准。

![NovaPlay 深色主题，发现页](screenshots/home_dark.png)

<details>
<summary>查看浅色主题</summary>

![NovaPlay 浅色主题，发现页](screenshots/home_light.png)

</details>

[项目状态](#项目状态2026-11-06) · [运行方法](#从源码运行) · [在线验收与开发计划](docs/reviews/2026-11-06-online-acceptance-next-phase.md) · [反馈问题](https://github.com/QIAN-SHU-QAQ/NovaPlay/issues)

## 项目状态（2026-11-06）

Windows 实机确认在线发现、搜索、详情、收藏、选集、播放和拖动可用。公开 TS HLS 样片通过下载器层的取消、续传、文件哈希比对和本地解码。R1 历史有序补交与 R6 配置桥已随 [PR #7](https://github.com/QIAN-SHU-QAQ/NovaPlay/pull/7) 合入，两个播放器跨两轮主窗口重启均能恢复同步。验收基线是 `689f8dd`。[基线 CI](https://github.com/QIAN-SHU-QAQ/NovaPlay/actions/runs/42163036020)

**当前发布阻塞项是在线续播定位。** 首页和历史入口均打开了原集，但原生播放器从片头附近播放，随后以较短进度覆盖了原历史。下一版先修复起点定位和历史写入保护，再验收首页、历史、收藏三个入口。[复现与验收条件](docs/reviews/2026-11-06-online-acceptance-next-phase.md)

本轮 Bangumi 请求在测试网络中连接超时，选集和播放仍可用。真实弹幕待专用凭据验收。Windows 便携版已具备打包与校验流程，发布前还要完成干净机器和旧数据升级测试。

## 现在能做什么

- 浏览片库和分类，按标题搜索，查看简介与剧集列表；分类与搜索结果都支持无限滚动分页加载。
- 播放在线视频，切换剧集、倍速、音量和窗口全屏；播放失败时可重试。**视频在独立的播放窗口中打开**，关掉视频窗口不会退出主界面，可以边看边浏览；可在设置里开启「自动播放下一集」并配置默认倍速。
- 配置弹弹play AppId/AppSecret 后，可按作品和集数加载弹幕，并调整透明度、字号和显示区域。
- 保存收藏、搜索历史和观看进度。独立播放器可向主窗口同步进度，主窗口重启后旧播放器可自动重连。首页、历史和收藏提供续播入口，当前在线起点定位问题见上方项目状态。
- 切换浅色、深色或跟随系统的主题，重启后保留选择。
- 在设置里管理数据源：启用/停用、切换主源、测速、添加自定义 maccms 源（主源失败自动回退到其它启用源）。
- 在详情页选集卡片上点击下载按钮，把剧集离线保存到本机（支持暂停/继续/删除、在文件夹中显示，重启后任务列表保留，完成后可直接在下载页点击播放）。
- 从 Bangumi 补充评分、制作人员和角色资料，查不到时仍可查看作品和播放。

搜索可以从侧栏或发现页右上角打开。播放器使用深色控件。

播放快捷键：空格暂停或继续，`←` / `→` 快退快进，`↑` / `↓` 调整音量，`F` 全屏，`Esc` 退出全屏。

## 使用前需要知道

在线内容依赖第三方接口，作品、图片和播放地址可能失效。主源请求异常时会尝试备用源，全部失败时显示错误并支持重试；正常的空结果不会触发回退。

首页、分类和搜索结果都支持继续加载。Bangumi 会按标题相似度和季号判断候选，无法可靠匹配时省略资料。

弹幕为可选功能。请在「设置 → 弹幕 → 弹弹play 账号」填写 AppId/AppSecret。播放器右侧会显示匹配结果或缺少凭据的提示。自动匹配会参考作品名、季数和集数，用户也可以手动选择。[弹弹play 开发者中心](https://dev.dandanplay.com)

详情页选集卡片旁的下载按钮可加入队列，下载页支持暂停、继续、删除和在文件夹中显示，任务在重启后保留。完成后点击任务即可在应用内播放，也可用第三方播放器打开保存的 `.ts` 文件。文件默认保存在系统“文档”目录下的 `NovaPlay/Downloads/`。当前支持未加密、以完整 TS 分片提供的 HLS 点播。

设置页可保存主题、配置自动连播与默认倍速，并可在「源管理」中启停、切换、测速或添加自定义数据源。应用内自动更新尚未实现。

收藏和观看历史保存在本机。旧播放地址失效或续播位置不对时，可以回到作品详情重新选集，再手动定位。

播放窗口是独立进程：每打开一个播放窗口都会启动一个 NovaPlay 进程，关闭播放窗口只结束对应进程，主窗口仍可继续浏览。多个进程写同一份本地配置会互相覆盖，因此**主窗口进程是唯一持久化写入方**：播放器把观看进度、收藏、搜索历史以“语义操作”（例如 upsert 某一条历史）发给主进程，由主进程在最新数据上合并，多个播放窗口同时写也不会互相覆盖；主窗口收到变更后会即时刷新历史/收藏。主窗口关闭时播放器不直接写整份配置，而是把操作写入本地日志（journal），下次启动主窗口时自动合并回放。主窗口重启后会监听新端口并更新端点文件（含会话 token），仍在运行的旧播放器在重试时自动发现并重连，积压的操作随后补交。下载任务配置只由主窗口进程写入。

### 修复状态与限制

2026-11-03/04 的 Windows 实机检验发现的问题，已通过 [PR #4](https://github.com/QIAN-SHU-QAQ/NovaPlay/pull/4)、[PR #5](https://github.com/QIAN-SHU-QAQ/NovaPlay/pull/5)、[PR #6](https://github.com/QIAN-SHU-QAQ/NovaPlay/pull/6) 以及后续 R1–R7 修复分轮处理：

- **观看历史可能丢失（已修复）。** 独立播放器写入的新记录以语义操作（upsert）交给主窗口进程，由主进程在最新历史列表上合并，多个播放器同时写也不会互相覆盖；主窗口历史页会即时刷新，修改“自动播放下一集”等设置不会再覆盖新历史。主窗口关闭期间播放器的操作会写入离线日志，下次启动时合并。
- **暂停下载会重置进度显示（已修复）。** 取消/异常分支改为基于当前任务写回状态，暂停后保留最新进度；继续下载仍会从断点恢复并完成。
- **主窗口重启后旧播放器实时同步中断（已修复并实测）。** 在提交 `2da2d91` 上，保留同一批两个播放器，连续关闭、重开主窗口两次；两轮均能自动发现新会话，观看时间持续更新，离线日志清空，历史与新增收藏保留。旧会话请求被拒绝，当前会话请求正常。
- **断点下载混拼旧分片（已修复）。** 下载器记录清单指纹、分片 URI、大小与 SHA-256。复用分片需要通过本地完整性检查和远端验证，无法确认时重新下载。
- **部分不支持的 HLS 格式被当成功（已修复）。** 下载器在下载主体前明确拒绝 fMP4（`EXT-X-MAP`）、`EXT-X-BYTERANGE`、独立音轨（`EXT-X-MEDIA:TYPE=AUDIO`）、直播/滚动列表和加密流，不会输出缺少初始化段的文件却报告完成。
- **续播刷新地址已合入，播放起点待修。** 首页、历史和收藏会先刷新详情，再定位原集。缺集、身份不明确或刷新失败时返回详情页。Windows 在线验收发现正确的进度参数可能未生效，详见项目状态。
- **弹幕季号匹配与手动关联已合入。** 自动匹配排除明确错季的候选，手动选择按作品和剧集保存，可恢复自动匹配。真实服务验收待测试凭据。
- **Bangumi 匹配与降级已合入。** 明确错季或无法可靠判断时省略资料，角色接口失败时保留已取得的评分和制作资料。手动匹配按作品保存，空结果与窄布局的入口将继续完善。
- **离线旧历史补交覆盖新进度（已修复）。** 写入进入单客户端的 seq 有序队列，补交按旧→新顺序提交；历史按 `watchedAt` 合并（用户主动回退到更早进度时以新的观看时间覆盖），删除记录以 tombstone 防止旧日志复活。主进程回放离线日志同样遵守这些规则。
- **配置桥会话可被省略（已修复）。** 正式协议要求当前会话 token，缺失/空值/类型错误/旧 token 均拒绝；请求先经过允许键、允许操作、结构与大小校验，失败整批拒绝不写入。

R1–R8 的原始验收用例和当前合入状态见 [R1–R8 验收清单](docs/reviews/2026-11-04-development-direction.md)。

### 验收记录（2026-11-06）

PR #7（R1 历史有序补交/版本规则 + R6 配置桥强制会话校验）在修复提交 `b3ab3be` 上的验证记录：

- **自动化测试**：`flutter test` 200/200 通过，`dart format` 无改动，`flutter analyze` 0 issue。
- **GitHub CI**：`CI validation` 通过（精确 head/base 的隔离测试与 Windows 构建）；`Build Windows preview` 通过并产出便携包。
- **集成验证**：main `1f0b338` + 本 PR 合并后 200/200 测试通过；Windows Release 构建成功，`scripts/test-scripts.ps1` 边界回归全部通过。
- **实机验证**：双播放器 + 主窗口重启场景通过——R6 会话校验生效、旧播放器自动重连、离线日志回放后观看时间单调前进、日志清空。
- **合并后复验**：在 `689f8dd` 重跑 200 项 Flutter 测试和 Windows Release 构建，并在独立配置中完成双播放器两轮重启。缺失、空值、错误类型和旧会话均被拒绝。旧操作重传保留 20 秒进度，后来主动回退到 5 秒可保存。[PR #7 合并记录](https://github.com/QIAN-SHU-QAQ/NovaPlay/pull/7)

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

仓库已配置 GitHub Actions：主分支 push 和 PR 的受控 CI 会检查自动化策略、Dart 格式、`flutter analyze`、`flutter test` 并构建 Windows Release。PR 由主分支机器人自动派发验证；纯文档满足条件后自动合并，代码需要当前提交的维护者审核，关键代码还需专项验收。规则和异常处理见 [PR 自动检查与合并](.github/AUTOMATION.md)。

测试使用离线替身，不需要请求在线片库。实际播放与第三方接口的可用性需要另行实测。

2026-11-04 在 Windows、Flutter 3.29.3 / Dart 3.7.2 下，针对合并提交 [`2da2d91`](https://github.com/QIAN-SHU-QAQ/NovaPlay/commit/2da2d91dd3ab86b2660dc8c85e40135a8f2bef39) 使用锁定依赖完成检验：

| 检查 | 结果 |
| --- | --- |
| Dart 格式检查 | 78 个文件，0 修改 |
| `flutter analyze` | 无问题 |
| `flutter test` | 120 个测试全部通过 |
| Windows Release 构建 | 成功 |
| 双播放器跨两次主窗口重启 | 两轮自动重连，两个作品的观看时间持续推进 |
| 离线日志与数据保留 | 两轮积压日志均清空，两条历史及主窗口新增收藏保留 |
| 会话检查 | 携带旧会话的请求被拒绝，当前会话请求成功 |

本轮实机回归使用本地测试源与公开 HLS 样片，重点验证跨进程存储和重连。此前已分轮验证在线播放、全屏按钮及 Esc 恢复、分类和搜索分页、HLS 下载、离线播放、暂停后重启续传及自动切集；本轮未重新操作全部功能，也未做长期压力测试或安装包验收。

**真实弹幕服务仍未完成验收**：没有有效的弹弹play AppId/AppSecret，尚未验证真实服务的鉴权、匹配和滚动效果。以上通过结论限定于列出的检查与操作场景。

构建目录为 `build/windows/x64/runner/Release/`。运行或复制程序时，请保留整个目录，包括 DLL 和 `data/`；只复制 `nova_play.exe` 无法正常运行。

### Windows 播放失败排查（Low 完整性标签）

如果播放时界面显示：

```
PathAccessException: Cannot create file, path = '\?\C:\Users\<用户>\AppData\Local\Temp\...' (OS Error: 拒绝访问, errno = 5)
```

通常是**运行目录里的文件带了 Low 完整性标签**（某些沙箱化构建/复制环境会把子进程降到 Low IL，其产物会继承 Low 标签）。Windows 会据此以 Low 完整性启动程序，media_kit 因此无法在 `%TEMP%` 创建临时播放列表文件，视频无法播放。

检查与修复（在 PowerShell 中执行）：

```powershell
# 查看是否带 Low 标签
icacls "E:\项目\NovaPlay\运行版" /T | Select-String "Mandatory Label"
# 统一改成 Medium（对整个运行目录执行一次）
icacls "E:\项目\NovaPlay\运行版" /setintegritylevel Medium /T
```

修复后重新启动应用，任务管理器中 `nova_play.exe` 的完整性级别应为「中等 / Medium」。以后每次构建并复制到运行目录后，如果构建环境是沙箱（或用脚本部署），都需要重新执行这条命令；仓库里的 `scripts/deploy-release.ps1` 会自动完成复制、修正标签和更新快捷方式：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy-release.ps1
```

### 构建 Windows 便携预览包

仓库提供 `scripts/package-portable.ps1`：从 Release 构建目录生成版本化便携 ZIP、附使用说明与许可，并输出 SHA-256 校验文件。缺少 exe/DLL/`data/` 或发现日志、缓存、个人配置等不应分发的文件时会直接失败。

```powershell
flutter build windows --release
powershell -ExecutionPolicy Bypass -File scripts\package-portable.ps1
```

产物在 `dist/`：`NovaPlay-<版本>-windows-x64.zip` 与同名 `.sha256`。CI 工作流 [windows-build](.github/workflows/windows-build.yml) 会在干净的 Windows runner 上执行锁定依赖解析、格式、分析、测试、Release 构建和打包；手动触发时可选择创建 draft Release，由维护者核对资产后再公开。干净机器验收（无 Flutter/VS、含中文和空格路径）仍需人工执行并记录。


## 参考

弹幕功能选型时做过的调研（结论：渲染直接用 MIT 依赖，数据协议自行实现）：

| 项目或文档 | 本项目中的用途 |
| --- | --- |
| [Predidit/canvas_danmaku](https://github.com/Predidit/canvas_danmaku) | 直接依赖，使用 Dart Canvas 渲染弹幕 |
| [Predidit/Kazumi](https://github.com/Predidit/Kazumi) | 流程参考，未直接复用代码 |
| [open-ani/animeko](https://github.com/open-ani/animeko) | 协议实现参考，未直接复用代码 |
| [弹弹play 开放 API](https://doc.dandanplay.com/open/) | 弹幕数据来源，需要配置 AppId/AppSecret |

## 继续开发

下一批按以下顺序交付，详细文件范围、复现步骤和通过条件见 [在线验收与下一阶段开发计划](docs/reviews/2026-11-06-online-acceptance-next-phase.md)。

1. **P0 修复在线续播。** 三个入口都要回到原集和原位置，失败或取消时保留旧进度。
2. **P1 完善外部资料并验收 Windows 预览版。** 补上 Bangumi 的错误与空结果提示、手动纠正入口，单独记录真实弹幕实测。续播修复通过后，在干净 Windows 环境验证便携包、下载重启恢复和旧数据升级。
3. **P2 做本地追番管理。** 预览版验收后先交付想看、在看、看完和筛选，覆盖多季隔离和重启保留。

分页、播放设置、下载与弹幕的基础实现已随 [PR #3](https://github.com/QIAN-SHU-QAQ/NovaPlay/pull/3) 合入。[开发报告](开发报告.md)和早期开发计划中的待办需要按当前实现重新核对，不能再将这些功能全部视为尚未实现。

报告问题时，附上 Windows 版本、操作步骤、出错页面和错误信息；涉及播放时补充作品、集数及是否能重现。请勿提交个人凭据。

代码采用 [MIT 许可](LICENSE)。应用从第三方接口读取内容，仓库不托管视频；视频、海报和作品资料的权利归各自权利人。
