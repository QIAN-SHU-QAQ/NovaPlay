# NovaPlay 可靠性改进

目标：落实审查中优先级最高的四项改进，保持现有 Flutter/Riverpod 架构与历史存储格式兼容。

## 设计与验收

- 数据源：主源异常时尝试备用源；按来源正确映射分类；所有源异常时抛出可展示的错误，正常空结果仍为空。备用源资源使用带来源的 ID，旧主源数字 ID 继续可读。详情优化线路时仅替换匹配的剧集地址，不替换作品身份；匹配必须避免同名季度误选。
- 搜索：只接受最新请求结果；清除、销毁后丢弃在途响应；新搜索不展示旧结果，空结果有明确文案。
- 播放器：加载失败可重试，监听播放错误与缓冲；切集保留音量、速度并更新标题；串行处理切集，避免异步回调越过销毁；自绘控制层独占控制，使用现有 media_kit_video 原生全屏接口并在退出时恢复窗口。
- 验证：新增离线行为回归测试，先确认失败，再实现并通过；运行全部测试、静态分析、Windows release 构建；审查 diff 并更新文档。

## 执行任务

- [x] 数据源与来源身份：修改 `lib/services/scraper/lziapi_scraper.dart`，新增数据源回退、ID 路由、正常空结果、全部失败、分类映射与剧集身份测试。
- [x] 搜索：修改 `lib/providers/search_provider.dart`、`lib/features/search/search_screen.dart`，新增请求乱序、旧请求错误、clear/dispose 和空结果测试。
- [x] 播放器：分离可测试的播放会话逻辑，修改 `lib/features/player/player_screen.dart`，测试失败重试、切集、标题、偏好保留、退出安全和全屏调用。
- [x] 集成审查：运行 `flutter analyze --no-pub`、`flutter test --no-pub`、`flutter build windows --release --no-pub`，修复发现的问题，记录结果与验证边界。

## 最终验证（2026-10-30）

- `flutter test --no-pub --reporter expanded`：58 项通过（原 15 项，新增 43 项）。
- `flutter analyze --no-pub`：No issues found。
- `flutter build windows --release --no-pub`：成功生成 `build/windows/x64/runner/Release/nova_play.exe`。
- 桌面实测：启动最终 release，首页与详情加载、视频播放、下一集与标题更新、深色控件可读性、F 原生全屏、Esc 恢复窗口均通过；验证实例已关闭。
- 网络失败、回退、跨源身份、请求乱序、异步错误续播与销毁边界使用离线测试覆盖；未对每个第三方视频地址做可用性保证。
- 实现分支为 `codex/reliability-fixes`，提交与远端状态以 Git 记录为准。

本轮不实现下载、弹幕、分类分页或打包更新；远端提交按用户指示执行。
