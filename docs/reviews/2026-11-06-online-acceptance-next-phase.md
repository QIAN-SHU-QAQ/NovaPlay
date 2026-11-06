# NovaPlay 在线验收与下一阶段开发计划

验收日期为 2026-11-06，基线为 Windows Release 和 GitHub `main` 的 `689f8dd485380b18903ed41b02d0250e451fbdb4`。本轮使用独立应用配置、真实网络和公开 HLS 测试样片。每项工作单独提交 PR，先记录失败样例，再以专项回归和合并后实机结果收口。[基线提交](https://github.com/QIAN-SHU-QAQ/NovaPlay/commit/689f8dd485380b18903ed41b02d0250e451fbdb4) · [基线 CI](https://github.com/QIAN-SHU-QAQ/NovaPlay/actions/runs/42163036020)

**目标** 先修复在线续播覆盖旧进度，再完成外部服务降级和 Windows 预览版验收，最后推进追番功能。

## 在线验收

| 项目 | 结果 | 实测证据 |
| --- | --- | --- |
| 合并后基础验证 | 通过 | 200 项 Flutter 测试、17 项自动化策略测试、打包脚本回归和 Windows Release 构建通过。两个播放器跨两轮主窗口重启自动重连，离线日志回放，两条历史与收藏保留。 |
| 发现与搜索 | 通过 | Windows 发现页展示在线海报，搜索「间谍过家家」显示 20 条。独立 HTTP 探测中 LziApi 和 360zy 对同一查询均返回 200。 |
| 详情、收藏、在线播放和拖动 | 通过 | 《间谍过家家第二季》显示 12 集。收藏后按钮显示已收藏。第 2 集在独立播放器出画，手动拖动到约 4:08 后继续播放并写入历史。360zy 本轮验证了搜索接口。 |
| 在线续播 | 失败 | 首页传入第 2 集和 `startAt=273`，播放器从片头附近播放，历史写入约 29 秒。历史入口传入第 2 集和 `startAt=320`，播放器仍从片头附近播放，历史写入约 39 秒。 |
| 公开 HLS 原生对照 | 复现 | 在 Windows libmpv 上，当前 `PlaybackSession` 以 180 秒续播时首次有效位置约 5 秒。同一 Mux 公开样片改用 `Media(start: 180s)` 做独立对照时，时长约 635 秒且位置实际推进到约 181 秒。 |
| 公开 HLS 下载与本地解码 | 下载器层通过 | 真实 HTTPS TS 样片下载 3 片后取消，当时没有完成文件。用新的下载器实例继续，完成 41 片，共 4,812,236 字节。产物 SHA-256 与一次性下载一致，libmpv 从本地文件解码并推进到约 2 秒。 |
| Bangumi | 降级通过，资料验收受阻 | 本机两次直接连接 `api.bgm.tv` 超时，详情页仍可选集和播放。页面缺少可用资料时也缺少可见的手动匹配入口。 |
| 弹幕 | 缺凭据路径通过 | 播放器显示未配置弹弹play账号，视频继续播放。真实鉴权、错季纠正和滚动表现留待专用测试凭据验收。 |
| 第三方片源内容 | 记录 | 样本播放期间观察到片内广告。后续预览版验收用自制或明确授权的媒体，片源内容质量作为单独维度记录。 |

公开样片来自 [Mux HLS 测试流](https://test-streams.mux.dev/)。Bangumi 接口定义见 [Bangumi API](https://bangumi.github.io/api/)。

[R1–R8 验收清单](2026-11-04-development-direction.md) 保留原始用例和各任务的合入状态。本计划以实测结果安排后续工作。

## PR 1 · P0 · 让续播在原生播放器真正生效

范围文件为 `lib/features/player/playback_session.dart`、`lib/features/player/player_screen.dart` 和 `test/features/player/playback_session_test.dart`。入口通过 `lib/core/utils/play_launcher.dart` 共用启动参数，保留现有的作品与集数校验。实测已确认参数传入独立进程，修复重点是媒体加载和进度确认之间的时序。

- [ ] 先增加能复现时序的回归。替身让 `open()` 返回时媒体还未可定位，先发出 0 秒和 5 秒位置，再发出已加载后的目标位置。断言 180 秒的续播在确认前保持待完成，历史维持 180 秒。
- [ ] 用加载时的起点参数替代「`open()` 刚返回就立即 `seek()`」的路径，并用时长及连续位置事件确认当前请求实际抵达目标。确认之前暂停该次会话的历史写入。候选方案已通过独立原生对照，应用内落地仍需验收。
- [ ] 覆盖启动失败、取消、重试和快速切集。旧请求的事件不得完成新请求。重试保留上次已确认进度，新集从自身起点开始。用户明确拖回较早位置或选择从头播放后，允许保存新位置。
- [ ] 执行 `flutter test test/features/player/playback_session_test.dart test/features/player/player_screen_test.dart test/home_layout_test.dart test/services/history_resume_test.dart`。专项测试通过后跑完整测试、分析和 Windows Release 构建。
- [ ] Windows 实机用两种样本确认。用可控源模拟旧地址失效和新地址替换，再用公开在线 HLS 验证原生起点。首页、历史、收藏分别从第 2 集约 180 秒继续，首次稳定画面位置落在 178–185 秒，历史随后向前写入。失败或取消时保持原进度。现有配置桥重连及 20 秒旧记录保护、主动回退 5 秒的回归同时通过。

**发布门槛** 当前版本的在线续播会覆盖历史进度。预览版以 PR 1 的原生实机证据作为放行条件。

## PR 2 · P1 · 外部资料失败可见，手动纠正可达

范围文件为 `lib/services/bangumi_api.dart`、`lib/providers/bangumi_provider.dart`、`lib/features/detail/detail_screen.dart` 和 `test/services/bangumi_api_test.dart`。需要在现有详情页组件测试中覆盖宽、窄两种布局。

- [ ] 用替身分别触发连接超时、空候选和角色接口失败。详情区分别显示「资料暂不可用，可重试」「无可靠匹配，可手选」和可用的部分资料，选集与播放入口保持可用。
- [ ] 把手动匹配入口放在可独立显示的资料区域，覆盖自动匹配为空、窄布局和已有关联时的解除操作。沿用完整作品 ID 持久化，避免两季或同名作品互相覆盖。
- [ ] 在能连接 Bangumi 的 Windows 网络上，验证同一作品的两季分别匹配、手选重启后保留、接口失败时映射仍可读。
- [ ] 作为独立的服务验收批次，用专用弹幕凭据跑两季各一集、暂停、拖动、倍速、切集和关闭弹幕。按作品、集数、弹幕数量和请求结果记录证据，敏感配置留在测试机。

## 验收批次 · P1 · Windows 便携预览版

沿用 `scripts/package-portable.ps1`、`scripts/test-scripts.ps1` 和 `.github/workflows/windows-build.yml`。先让 PR 1 通过，再在干净机器验收同一构建产物。

- [ ] 对同一 Git 提交的 Release ZIP 校验 SHA-256，在没有 Flutter 和 Visual Studio 的 Windows 环境解压到含中文与空格的路径。逐项核对启动、在线搜索、播放与续播、收藏和设置重启后可读。
- [ ] 以已通过的下载器层对照为基线，用同一公开 TS HLS 样片完成应用层暂停、关程序、重开、续传，再断网播放并拖到中段及末尾。记录完成文件哈希与一次性下载一致。升级样本核对历史、收藏、设置、下载任务及已有下载路径。
- [ ] 记录提交、系统版本、包哈希和实测范围后准备草稿发布。若外部服务条件尚未具备，在预览说明中逐项标明验收范围。

## 预览版之后 · P2 · 追番管理第一版

以 `lib/models/video_model.dart` 的作品身份和 `lib/services/database_service.dart` 的现有持久化入口为起点。第一版做本地「想看／在看／看完」和筛选。验收覆盖两季各有独立状态、同名作品互不覆盖、跨重启保留及旧收藏和历史可继续使用。云同步、提醒和项目改名分别立项。
