# PR 自动检查与合并

目标：贡献者提交后自动完成检查，纯文档自动合并；代码只需维护者完成一次当前提交的审核，满足条件后自动合并，不再手动等待 CI 或点击合并。

## 当前规则

| 类型 | 条件 | 合并方式 |
| --- | --- | --- |
| 纯文档 | 仅新增/修改根 README.md 或 docs/ 下 Markdown；完整 CI 通过；无维护者要求修改 | 机器人批准，GitHub 自动 squash 合并 |
| 普通代码 | CI 通过，有写权限的其他维护者批准当前 head SHA | GitHub 自动 squash 合并 |
| 关键代码 | 普通代码条件，加专项验收确认 | GitHub 自动 squash 合并 |

关键代码包括历史存储、配置桥、下载服务/HLS、历史续播、主入口、Windows 原生文件、依赖、scripts/ 和 .github/。删除、重命名、图片和其他格式不属于文档自动放行范围；AGENTS.md、CLAUDE.md、SKILL.md 也不自动放行。完整文件分类见 [policy.cjs](automation/policy.cjs)。

关键代码的批准 Review 必须包含单独一行：

```text
Acceptance-SHA: 当前 PR 的完整 40 位 head SHA
```

在同一批准中附 [R1–R8 对应验收](../docs/reviews/2026-11-04-development-direction.md) 的实际证据。把标记写在 PR 正文、评论或标签中不会代替批准；旧 SHA 的批准不能用于新提交。未执行的实机项目仍应如实标记，不能仅补一行标记就声称验收完成。

主分支要求 `PR policy`、`CI validation` 两个状态，要求最新分支与 main 同步、至少一次有效批准、解决所有 Review 讨论，禁止强推和删除；管理员也遵守规则。新提交使旧批准失效。普通代码不会得到机器人批准；本流程没有调用 AI 模型进行语义审查。

## 如何运行

1. PR 新建或更新后，主分支上的 controller 获取文件与审核元数据，设置状态并启用等待合并。
2. controller 从主分支派发 CI，参数绑定 PR 编号、完整 head SHA 和 main SHA。
3. CI 在 GitHub 托管的 Windows 2022 临时 runner 检出测试合并提交，验证两个父提交，执行自动化策略测试、Flutter 格式/分析/测试与 Windows Release 构建。构建目录作为 7 天 artifact 保留，尚未代表通过便携版分发验收。
4. 完成后 controller 验证三个必需 job 的真实结果；纯文档才获得机器人批准。代码等待维护者审核和必要的专项验收。
5. GitHub 最终检查分支保护要求并合并。若显示分支落后，贡献者先同步 main，等待新的检查和审核。

合并机器人只检出主分支，不执行 PR 代码或读取 PR 构建产物。运行 PR 代码的 CI 没有写权限、没有引用 secrets、不使用共享缓存，不在开发者本机运行。Actions 默认 token 仍为只读，仅 controller 的 job 获得合并所需权限；允许 Actions 创建批准 Review，以支持文档自动化。

## 失败与恢复

- `CI validation` 失败：查看状态链接中的 job；修复后推送，或在对应 CI 页面 Re-run failed jobs。
- `PR policy` 等待：普通代码需要批准当前提交；关键代码另需批准中的 Acceptance-SHA 标记；Draft 需要先切为 Ready for review。
- controller 异常：状态会失败而非放行；修复后在 Actions → PR policy controller → Run workflow 重新核对所有开放 PR。
- 维护者要求修改、撤销批准或有新提交时，原批准不能作为放行依据。
- 暂停自动化：先关闭仓库 Allow auto-merge；保留分支保护，再停用 controller。不要删除必需检查来强行通过失败 PR。

## 配置验收

- 策略测试必须覆盖文档白名单、混合修改、重命名/删除、维护者身份、旧提交批准、撤销、关键代码验收标记及 head/base 身份。
- 主分支 CI 必须在干净 runner 完成自动化测试、Flutter 测试和 Windows 构建。
- 用一个真正的纯文档 PR 检查“自动派发 → CI → bot 批准 → 自动合并”，并确认代码 PR 留在审核等待状态。
- 本流程建立的是检查和合并机制；应用功能仍按各自验收要求交付。
