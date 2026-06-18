# GitHub 项目介绍文案（中英双语）

## Repository Name

- `Plumb`

## Short Description（用于仓库 Description）

- 中文：macOS 菜单栏窗口居中工具：启动即居中，支持自动检测，排除 Dock 与状态栏后精确居中。
- English: A macOS menu bar window-centering tool with launch-time centering and optional auto-detection, centered within usable screen area excluding Dock and menu bar.

## About（用于仓库首页介绍）

- 中文：  
  Plumb 是一个轻量的 macOS 窗口管理工具。它会在启动时立即将前台窗口居中，并支持自动居中检测开关和检测间隔切换。项目通过可用屏幕区域计算（自动排除 Dock 与状态栏）实现稳定居中，适合多显示器场景。  
  许可证：MIT。

- English:  
  Plumb is a lightweight macOS window management utility. It centers the frontmost window immediately on launch, with optional auto-centering detection and interval switching. It computes centering within the usable screen area (excluding Dock and menu bar) for stable behavior, including multi-display setups.  
  License: MIT.

## Suggested Topics

- `macos`
- `swift`
- `window-manager`
- `menu-bar-app`
- `accessibility`
- `notarization`

## Release Notes Snippet（免费分发安装说明，可直接复制）

- 中文：  
  本版本为未公证分发包。下载后请将 `Plumb.app` 拖入 `Applications`，然后在应用目录中右键“打开”并确认。若系统拦截，请前往“系统设置 -> 隐私与安全性”点击“仍要打开”。如仍失败，可执行：`xattr -dr com.apple.quarantine /Applications/Plumb.app`。

- English:  
  This release is distributed without Apple notarization. Drag `Plumb.app` to `Applications`, then right-click and choose “Open”. If blocked, click “Open Anyway” in `System Settings -> Privacy & Security`. If needed, run: `xattr -dr com.apple.quarantine /Applications/Plumb.app`.
