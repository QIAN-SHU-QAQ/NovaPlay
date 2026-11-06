# NovaPlay Windows 预览版（便携包）

本包是可直接运行的 Windows 预览版，解压即用，不需要安装 Flutter 或 Visual Studio。

## 运行要求

- Windows 10 / Windows 11（64 位）
- 首次运行若提示缺少运行库，请安装
  [Microsoft Visual C++ 可再发行程序包（2015-2022 x64）](https://aka.ms/vs/17/release/vc_redist.x64.exe)
- 解压路径可以包含中文和空格，不需要管理员权限

## 使用

1. 将 ZIP 解压到任意目录（例如 `D:\软件\NovaPlay` 或 `C:\Users\你的用户名\Desktop\NovaPlay`）。
2. 双击 `nova_play.exe` 启动。
3. 网络视频需要能访问对应站点；本程序不内置任何内容。

观看历史、收藏、设置保存在 `%APPDATA%\com.novaplay\nova_play`，卸载时删除该目录即可。
播放窗口是独立进程，关闭播放窗口不会退出主界面。

## 已知限制

- 续播会尝试刷新详情。当前 Windows 在线验收发现，播放器有时从片头附近开始并覆盖原进度。遇到起点错误时，可在作品详情重新选集并手动定位。[项目状态与验收](https://github.com/QIAN-SHU-QAQ/NovaPlay/blob/main/docs/reviews/2026-11-06-online-acceptance-next-phase.md)
- 弹幕需要自备弹弹play AppId/AppSecret（设置 → 弹幕）；匹配不准时可在播放器里使用「手动匹配弹幕」。
- 下载仅支持未加密、完整 TS 的 HLS VOD；fMP4/BYTERANGE/独立音轨/直播会被明确拒绝。
- 预览包未做代码签名，Windows SmartScreen 可能提示「未知发布者」，请核对 ZIP 的 SHA-256 后再运行。
- 本预览版不包含自动更新；请从 [Releases](https://github.com/QIAN-SHU-QAQ/NovaPlay/releases) 下载新版本。

## 校验

发布资产同时提供 `NovaPlay-<版本>-windows-x64.zip.sha256`，可用 PowerShell 校验：

```powershell
Get-FileHash .\NovaPlay-<版本>-windows-x64.zip -Algorithm SHA256
```

结果应与 `.sha256` 文件中的值一致。
