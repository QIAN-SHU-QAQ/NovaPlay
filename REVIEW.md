# NovaPlay 代码评审与改进建议

> 更新（2026-10-30 晚）：已同步上游 main（`f8c6764`，上游 force-push 重写历史：播放器改为 PlaybackSession/FullscreenSession、数据源可靠性修复、UI 重写、新增 78 个测试、文档重写）。本文件中的播放器生命周期等问题上游已自行解决；本地保留并移植了「写入串行化、可配置数据源、m3u8 下载器、CI」等增量。以下内容保留作历史记录，最新状态见 `state/current-state.md`。
>
> 更新（2026-10-30 上午）：P0-1（播放器生命周期/错误重试）、P0-2（历史写入串行化 + 15s 节流）、P0-3（可配置数据源 + 显式错误）已修复；工程化项已完成 GitHub Actions CI、全量 `dart format`、README 构建前提说明。
>
> 评审日期：2026-10-29 ｜ 评审对象：`QIAN-SHU-QAQ/NovaPlay` @ `c57c3cb`
> 评审方式：源码通读 + 实际执行 `pub get` / `analyze` / `test` / `build` / `format` 检查

## 0. 实测结果（这台机器，Flutter 3.29.3 + VS 2022 17.10）

| 检查 | 结果 | 说明 |
|---|---|---|
| `flutter pub get` | ✅ 50s | 有 `Building with plugins requires symlink support` 警告 |
| `flutter analyze` | ✅ **0 issue** | 与 README 宣称一致 |
| `flutter test` | ✅ **15/15 通过** | 21s；含 10 个持久层测试 + 2 个冒烟测试 |
| `flutter build windows` | ❌ 2s 失败 | 缺"开发者模式"（非管理员无法创建符号链接），**README 未写这个前提** |
| `dart format` 检查 | ⚠️ **44 个文件里 37 个会被改动** | 代码未统一格式化 |
| `flutter pub outdated` | ⚠️ 大量落后 | riverpod 2.6→3.4、go_router 14.8→18.1、google_fonts 6.3→9.0、media_kit_video 1.3→2.0、intl 0.19→0.20、cached_network_image 3.4→4.0、shimmer 3→4 |

## 1. 总体评价

**做得好的地方**

- 目录分层清晰（core / models / providers / services / features / shared），命名一致，读起来顺畅
- Riverpod 用法规范（手写 StateNotifier + FutureProvider.family），没有滥用全局状态
- 首页/详情页的错误态、空态、图片 errorWidget 都有兜底
- README + 开发报告质量高，踩坑记录（Flutter 补丁、m3u8 无加密、dandanplay 403）对后来者很有价值
- analyze 0 issue、有基础测试，作为个人项目基础很扎实

**主要短板**

1. **可靠性**：播放器有生命周期漏洞，历史写入有放大问题
2. **单点依赖**：只有一个真实数据源，源挂 = 应用不可用
3. **功能缺口**：下载/弹幕/设置仍是占位（开发报告已承认）
4. **工程化**：无 CI、未格式化、依赖落后 18 个月
5. **发布**：无安装包、应用名还是 `nova_play`、版本号 1.0.0 与完成度不符

---

## 2. P0 · 正确性与稳定性（建议先修）

### 2.1 播放器 `setState` 生命周期漏洞

`lib/features/player/player_screen.dart:117-140` 的 `_initPlayer()` 在多个 `await` 之后直接 `setState()`，没有 `mounted` 检查。用户在视频初始化完成前返回，会触发 `setState() called after dispose()`。

```dart
await _player.open(Media(url), play: true);   // 可能耗时数秒
...
setState(() { _isInitialized = true; });      // widget 可能已 dispose
```

**修复**：每个 await 之后加 `if (!mounted) return;`；同时用可取消的初始化令牌（切集时取消上一次初始化，避免旧请求覆盖新状态）。

### 2.2 观看历史的"写放大"

- `player_screen.dart:81-84`：`Timer.periodic(5s)` 调 `_recordHistory()`
- `database_service.dart:110-123`：每次 `saveHistory` 都把**最多 100 条**历史整体 JSON 序列化后 `setString` 写回
- `history_item.dart:9,54-64`：每条历史都保存**完整剧集快照**（每集含 id/title/url/playUrl）

长番（几百集）+ 100 条历史时，每 5 秒重写几百 KB 的 SharedPreferences 文件，既费 IO 也可能卡 UI 线程；而且读-改-写不是原子的，定时器和 dispose 同时触发时有丢更新风险。

**修复建议**：
1. 写入节流：改为每 15–30 秒 + 暂停/切集/退出时写，而不是固定 5 秒
2. 快照瘦身：历史只存 `episodeIndex` + 当前集标题/URL；完整剧集列表放缓存表按 videoId 引用
3. 持久层换成 SQLite（drift/sqlite3）或 Hive：异步、可迁移、无整文件重写
4. 写操作串行化（单写队列），避免并发丢更新

### 2.3 数据源单点 + 脆弱回退

`lib/services/scraper/lziapi_scraper.dart`：
- `_apiSources` 硬编码两个第三方 API（第 23–26 行）
- 备用源靠标题模糊匹配（第 187–218 行），可能匹配错剧
- `getPlayUrls()` 解析失败时**静默返回原 URL**（第 259–262 行），用户只会看到播放失败
- 没有源健康检查、没有源管理界面

这是产品级风险：**聚合类应用的数据源寿命通常只有几个月**，源一挂整个应用就废了。

**修复建议**：
- 把"源"变成可配置/可订阅的规则（参考 Kazumi 的规则 JSON），设置页支持导入、启用/禁用、测速
- 多源聚合搜索 + 结果去重合并（按标题+年份归一化）
- 失败显式上报（错误码 + 重试按钮 + 一键换源），不要静默

### 2.4 网络层

`lib/core/network/http_client.dart`：
- 第 22–26 行 `LogInterceptor` **无条件开启**，release 版本也会打印所有请求 URL（日志噪音 + 隐私/带宽信息泄露）
- 无重试/退避、无缓存、无并发限制、无代理设置

**修复**：`if (kDebugMode)` 才挂 LogInterceptor；加 retry（指数退避，仅幂等 GET）、`dio_cache_interceptor` 或自建首页/详情缓存；设置页加 HTTP 代理（国内用户刚需）。

---

## 3. P1 · 体验与功能

| # | 问题 | 位置/证据 | 建议 |
|---|---|---|---|
| 3.1 | 播放失败只 `debugPrint`，界面无限 loading | `player_screen.dart:137-139` | 错误态 + 重试 + 自动换源 |
| 3.2 | 无自动连播 | 未监听 `player.stream.completed` | 播完自动下一集（可在设置开关） |
| 3.3 | 倍速/音量不记忆 | 设置项未接线 | 打开时读取 `playback_speed` 等已存的设置 |
| 3.4 | 无字幕轨/硬解开关/PiP/媒体键 | — | mpv `hwdec=auto-safe` 开关、`sub-add`、`GlobalHotKey`/媒体键 |
| 3.5 | 设置页大量占位 | `settings_screen.dart:16` | 先接线已有存储字段（画质/自动播放/弹幕开关） |
| 3.6 | 下载是 mock，且 `Dio.download` 对 m3u8 无效 | `download_screen.dart:13`、`download_service.dart:89` | Phase 3：解析 master/子 playlist、分片并发下载、断点续传（记录已完成分片）、任务持久化、ts 拼接或 mpv 直接播 |
| 3.7 | 搜索只查当前源 | `video_provider.dart` / search | 多源聚合 + 去重 + 按相关度排序 |
| 3.8 | 字体运行时下载 | `theme.dart:56` 用 `google_fonts` | 首启离线会字体回退；打包 Noto Sans SC 子集，或直接用系统中文字体 |
| 3.9 | 播放器单文件 824 行 | `player_screen.dart` | 拆成 controller + 控制栏 + 侧面板，补 golden test |
| 3.10 | 冒烟测试吞异常 | `test/settings_smoke_test.dart:27-28` | `takeException()` 后应断言为 null，否则等于没测 |

---

## 4. P2 · 工程化与发布

1. **没有 CI**（仓库无 `.github`）：建议加 GitHub Actions —— `analyze` + `test` + `dart format --set-exit-if-changed`；再加 Windows release 工作流（构建 zip / msix 并挂 release）。
2. **格式化不统一**：37/44 个文件没跑过 `dart format`。先一次性格式化，再在 CI + pre-commit 锁住。
3. **依赖落后 18 个月**：Flutter 3.29.3 是 2025-04 的版本。建议先补测试，再分批升级（riverpod 3 / go_router 18 / media_kit 2 都是 breaking change，别一次跳）。
4. **构建前提没写全**：README 只写了 Flutter + VS，实际 `pub get`/`build` 需要 **Windows 开发者模式**（符号链接）。我实测 `flutter build windows` 直接报 `Building with plugins requires symlink support` 失败，文档要补，CI 的 windows runner 默认也可能踩。
5. **发布物缺失**：`windows/runner/Runner.rc` 里 ProductName/CompanyName 还是 `nova_play` / `com.novaplay`；无 msix、无签名、无自动更新；版本 `1.0.0` 与未完成的功能不符，建议改 `0.9.x` 并加 CHANGELOG。
6. **仓库卫生**：只有 2 个 commit（init 全量 + docs），`方案.txt` 这类内部过程文档可以移到 `docs/` 或 wiki；建议补 CONTRIBUTING、issue 模板、SECURITY.md、`.editorconfig`、dependabot。
7. **测试覆盖低**：15 个测试 / 6578 行 Dart。优先补：maccms 解析（`_parseEpisodes` 是纯逻辑，最值得测）、provider 状态机、历史/收藏并发写、播放器控制栏 widget test；CI 里出覆盖率。
8. **架构可测性**：`HttpClient` / `DatabaseService` / `DownloadService` 都是单例直接 new，绕过 Riverpod，测试没法注入。建议改成 provider 注入 + repository 层 + sealed 错误类型（替代到处 `e.toString()`）+ 统一日志（替代 `debugPrint`）。

---

## 5. 功能路线建议（对齐 Kazumi 生态）

- **规则化数据源**：规则 JSON 导入/在线订阅/测速/启用禁用 —— 这是同类项目的分水岭
- **弹幕**：dandanplay AppId + 签名（开发报告已调研），复用已写好的渲染层
- **追番与更新提醒**：Bangumi 日历 + 本地通知，收藏页显示"今日更新"
- **数据同步**：WebDAV 备份收藏/历史/设置，换机器不丢
- **便携模式**：免安装 zip + 配置目录随包，适合 Windows 分发
- **网络体验**：代理设置、镜像源、连接超时/并发可调
- **播放增强**：硬解开关、字幕轨、画中画、媒体键、睡眠抑制

## 6. 合规提醒

抓取第三方聚合站存在版权与 ToS 风险。项目已有免责声明，建议进一步收敛边界：**不内置任何资源/源、源由用户自行配置、播放页保留来源与合规提示**，并把这条写进 README 显著位置。

---

## 7. 本地复现命令

```powershell
# 需要：Flutter 3.29.3、VS 2022 C++ 负载、Windows 开发者模式（符号链接）
flutter pub get
flutter analyze        # 0 issue
flutter test           # 15 passed
dart format --output=none --set-exit-if-changed lib test   # 当前会报 37 个文件
flutter build windows --debug   # 需开发者模式
```

> 本文件是评审产出，未提交到 git（untracked），不影响仓库原有代码；`pubspec.lock` 已还原。
