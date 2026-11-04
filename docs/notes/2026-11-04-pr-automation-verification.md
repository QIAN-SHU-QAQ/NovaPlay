# 文档 PR 自动合并验证

此文档通过独立 PR 添加，用于实测 [PR 自动检查与合并](../../.github/AUTOMATION.md) 的完整链路。

验收目标：

1. 机器人识别仅新增 Markdown 的改动。
2. 自动验证精确 PR head 与 main 的测试合并提交。
3. 自动化策略测试、Flutter 格式/分析/测试和 Windows Release 构建通过。
4. GitHub Actions 机器人提交批准 Review。
5. GitHub 在分支保护条件满足后自动 squash 合并，无需维护者手动批准或点击合并。
6. CI 结束后由独立通知 job 自动唤起 controller；第二轮验证不手动运行 controller，以确认无人值守链路。

实际结果以对应 PR 的状态检查、Review 与合并记录为准。此文档的加入不代表应用功能、真实弹幕服务或便携包已经完成专项验收。
