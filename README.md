# Plumb

[English](./README.en.md) | 简体中文

`Plumb` 是一个 macOS 菜单栏窗口管理工具：支持自动居中与按指定 App 自动平铺。

## 功能

- 启动立即居中一次
- 之后仅在“窗口关闭后重新打开 / 切换到新窗口”时居中一次
- 拖动移动窗口不会触发再次居中
- 排除 Dock 与状态栏后居中（基于 `screen.frame - screen.visibleFrame`）
- 支持“指定 App 自动平铺”（白名单），可配置统一边距
- 菜单栏图标与应用图标自动生成

## 自动平铺（指定 App）

- 菜单栏 `平铺设置…` 中可开启/关闭功能
- 可配置统一四边距（px）
- 可从已安装应用列表中选择白名单 App（默认隐藏系统应用，可切换）
- 白名单 App 触发时优先平铺，不再自动居中
- 触发粒度为“每个进程首次窗口一次”；同一进程内后续不重复触发
- 若窗口不支持修改尺寸，则跳过该窗口

语义参考 Amethyst 配置思路：
- `window-margin-size`：对应本项目平铺边距
- `floating + floating-is-blacklist=false`：对应本项目“白名单自动平铺”

## 系统要求

- macOS 13+
- Xcode Command Line Tools（`xcode-select --install`）

## 本地构建

```bash
swift test
swift build -c release
./.build/release/Plumb
```

## 打包

```bash
scripts/build_app.sh
scripts/create_dmg.sh
```

输出：

- `dist/Plumb.app`
- `dist/Plumb.dmg`

DMG 打开后会包含两个项目：

- `Plumb.app`
- `Applications`（系统应用目录快捷方式）

安装方式：将 `Plumb.app` 拖到 `Applications`。

## 签名与公证（Developer ID）

```bash
export DEVELOPER_ID_APP="Developer ID Application: YOUR_NAME (TEAMID)"
export NOTARY_PROFILE="AC_NOTARY"
scripts/sign_and_notarize.sh
```

## 安装说明
1. 打开 DMG，将 `Plumb.app` 拖到 `Applications`。
2. 到 `Applications` 中右键 `Plumb.app` -> `打开` -> 再次点击 `打开`。
3. 若仍被拦截：`系统设置 -> 隐私与安全性` 页面底部点击“仍要打开”。
4. 若仍失败，可在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/Plumb.app
```

注意：这是非公证分发的常见安装流程，不是应用自身代码损坏。

## 权限

### 辅助功能（Accessibility）

- 路径：`系统设置 -> 隐私与安全性 -> 辅助功能`
- 为什么需要：  
  应用通过 macOS Accessibility API 读取前台窗口的位置/尺寸，并写入新位置来执行“窗口居中”。
- 不授权会怎样：  
  无法获取窗口几何信息，也无法移动窗口，居中功能不可用。

### 屏幕录制（Screen Recording）

- 路径：`系统设置 -> 隐私与安全性 -> 屏幕录制`
- 为什么需要：  
  需要获取完整屏幕可见区域上下文，以便正确识别可用显示区域并精确避开 Dock/状态栏进行居中。
- 不授权会怎样：  
  屏幕上下文能力受限，可能导致多屏或复杂布局下的居中判断不稳定。

### 权限边界说明

- 本项目不会上传屏幕内容，不会进行网络采集。
- 权限仅用于本地窗口几何计算与窗口位置调整。

## 开源协议

MIT License，见 [LICENSE](./LICENSE)。
