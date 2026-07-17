<div align="center">

<img src="assets/AppIcon-base.png" width="140" height="140" alt="Plumb">

# Plumb

一线垂下，落定正中。

> 让你的 Mac 使用起来更加优雅。

自动居中与平铺 macOS App，强迫症爱好者的福音！

[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg?style=flat-square)](#系统要求)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138.svg?style=flat-square)](https://swift.org)
[![Release](https://img.shields.io/badge/release-v2.0.58-success.svg?style=flat-square)](#下载安装)

[English](./README.md) · **简体中文** · [Español](./README.es.md) · [Français](./README.fr.md) · [日本語](./README.ja.md)

</div>

---

## 📖 目录

- [简介](#简介)
- [✨ 功能特性](#-功能特性)
- [📐 自动平铺](#-自动平铺)
- [📸 效果预览](#-效果预览)
- [下载安装](#下载安装)
- [使用说明](#使用说明)
- [权限说明](#权限说明)
- [系统要求](#系统要求)
- [本地构建](#本地构建)
- [打包与发布](#打包与发布)
- [常见问题](#常见问题)
- [开源协议](#开源协议)

## 简介

`Plumb` 是一个 **macOS 菜单栏窗口管理工具**：支持自动居中与按指定 App 自动平铺。

名字取自「铅锤线」（plumb line）——木匠把它垂下，用以找到真正的垂直与中心。Plumb 做的也正是这件事：把窗口温柔地安放到屏幕的正中或指定位置。

- 🪧 常驻菜单栏，无 Dock 图标，零打扰
- 🎯 按 App 激活 / Space 周期重新评估布局，并在当前周期内抑制重复处理
- 🖥️ 基于可用屏幕区域计算（自动排除 Dock 与状态栏），多显示器场景稳定
- 📐 指定 App 自动平铺（白名单），支持全局边距与按 App 单独设置四向边距
- 🪟 Liquid Glass 设置界面（macOS 26），毛玻璃质感、应用搜索、药丸开关

## ✨ 功能特性

| 功能 | 说明 |
| --- | --- |
| 🎯 按激活周期排版 | App 重新激活或切换 Space 时重新评估布局，当前周期内不重复处理 |
| ✋ 尊重手动布局 | 真正移动或缩放窗口后，当前 App 激活 / Space 周期内不再自动调整该窗口 |
| 🖥️ 精确避开 Dock/状态栏 | 基于 `screen.frame - screen.visibleFrame`，多屏稳定 |
| 📐 指定 App 自动平铺 | 白名单机制，可配置全局边距（px） |
| 🎚️ 按 App 单独设置四向边距 | 在平铺列表点击任意应用展开抽屉，分别设置上、下、左、右边距；未覆盖的应用使用全局默认值 |
| 🔄 实时刷新应用列表 | 新安装的应用立即出现在设置选择器中，无需重启 |
| 🪟 Liquid Glass 设置界面 | macOS 26 毛玻璃质感、搜索、药丸开关 |
| 🧠 四坐标系智能识别 | 自动识别不同 App 的窗口坐标系并稳定缓存 |
| 🪧 无打扰菜单栏驻留 | 仅菜单栏图标，不占用 Dock |

## 📐 自动平铺

在菜单栏 `平铺设置…` 中可开启/关闭功能，灵活管理你的工作流。

- 可配置统一四边距（px）
- **按 App 单独设置四向边距**：在平铺应用列表点击任意应用，展开行内边距抽屉，分别设置上、下、左、右边距。未覆盖的应用会在四个方向上使用全局边距；点击「使用默认」会移除该应用的覆盖值。
- 可从已安装应用列表中选择白名单 App（默认隐藏系统应用，可切换）
- 白名单 App 触发时**优先平铺**，不再自动居中
- 触发粒度为一个 App 激活 / Space 周期，而不是进程的整个生命周期；重新激活 App 或切换 Space 会开始新一轮评估
- Plumb 会依次尝试标准 AX 尺寸写入与 AXFrame 回退。仅移动位置不算平铺成功；系统会在有限次数内重试，只接受目标宽度或已定义的垂直锚定妥协形态
- 对文档类 App（Pages、Numbers、Word、Excel），模板库与文件列表只居中；已保存文档会平铺，识别到的未保存文档会先短暂等待窗口尺寸稳定再平铺

> 语义参考 Amethyst 配置思路：
> - `window-margin-size`：对应本项目平铺边距
> - `floating + floating-is-blacklist=false`：对应本项目「白名单自动平铺」

## 📸 效果预览

<table>
  <tr>
    <td width="50%" align="center"><b>居中 — 应用白名单</b></td>
    <td width="50%" align="center"><b>平铺 — 按 App 边距抽屉</b></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="assets/Centering.png" alt="居中标签页"></td>
    <td width="50%" align="center"><img src="assets/Tiling.png" alt="平铺标签页与按 App 边距抽屉"></td>
  </tr>
  <tr>
    <td width="100%" colspan="2" align="center"><b>权限 — 辅助功能、屏幕录制、开机自启</b></td>
  </tr>
  <tr>
    <td width="100%" colspan="2" align="center"><img src="assets/Permissions.png" alt="权限标签页"></td>
  </tr>
</table>

## 下载安装

### 方式一：下载 DMG（推荐）

1. 从 [Releases](../../releases) 下载最新版 `Plumb.dmg`。
2. 打开 DMG，将 `Plumb.app` 拖到 `Applications`。
3. 到 `Applications` 中右键 `Plumb.app` → `打开` → 再次点击 `打开`。
4. 若仍被拦截：前往 `系统设置 → 隐私与安全性`，页面底部点击「仍要打开」。

### 方式二：源码构建

```bash
swift build -c release
./.build/release/Plumb
```

详见 [本地构建](#本地构建)。

## 使用说明

1. 启动后，菜单栏出现 Plumb 图标。
2. 授予 [辅助功能（Accessibility）](#辅助功能accessibility) 权限——居中功能依赖此权限。
3.（可选）授予 [屏幕录制（Screen Recording）](#屏幕录制screen-recording) 权限，以提升多显示器坐标识别稳定性。
4. 点击菜单栏图标：
   - 即可手动触发居中
   - 打开 `平铺设置…` 配置白名单与边距

> 💡 **设计原则**：自动布局以当前 App 激活 / Space 周期为边界。真正手动移动或缩放窗口后，本周期内会保留你的布局；重新激活 App 或切换 Space 会清除手动标记并重新评估布局。

## 权限说明

### 辅助功能（Accessibility）

- **路径**：`系统设置 → 隐私与安全性 → 辅助功能`
- **为什么需要**：应用通过 macOS Accessibility API 读取前台窗口的位置/尺寸，并写入新位置来执行「窗口居中」。
- **不授权会怎样**：无法获取窗口几何信息，也无法移动窗口，居中功能不可用。

### 屏幕录制（Screen Recording）

- **路径**：`系统设置 → 隐私与安全性 → 屏幕录制`
- **为什么需要**：需要获取完整屏幕可见区域上下文，以便正确识别可用显示区域并精确避开 Dock/状态栏进行居中。
- **不授权会怎样**：屏幕上下文能力受限，可能导致多屏或复杂布局下的居中判断不稳定。

### 权限边界说明

- ❌ 本项目**不会上传屏幕内容**，**不会进行网络采集**。
- ✅ 权限**仅用于**本地窗口几何计算与窗口位置调整。

### 为什么权限可能需要重新授权（以及如何修复）

macOS 以应用的**稳定签名身份**（designated requirement）为键保存「辅助功能」与「屏幕录制」授权。ad-hoc 签名的身份只是可执行文件的哈希（`cdhash`），每次重新编译都会变化——每次更新都被 macOS 视为一个全新应用，授权记录随之失效。

Plumb 现在改用**稳定的本地证书**（`Plumb Local Signer`）签名，而非 ad-hoc。由于 designated requirement 绑定到证书（而非每次构建的 `cdhash`），**在首个稳定签名版本之后**，你的授权可跨更新保留。要在某台机器上启用此机制，运行一次 `scripts/make_signing_cert.sh`（需一次管理员密码以信任该证书）；之后的构建会自动使用稳定身份。在没有受信任证书的机器上，构建会回退到 ad-hoc，每次更新后仍需重新授权。

**局限——从源码编译裸可执行文件：** `swift build` / `swift run` 产出的裸可执行文件没有 `.app` 包、没有稳定签名身份，其 TCC 授权以 `cdhash` 为键，每次重新编译都会失效。日常测试依赖权限的功能时，请使用 `.app` 构建产物（通过 `scripts/build_app.sh`）。

### 自动更新

Plumb 会在启动时（每 6 小时至多一次）以及通过菜单栏的「检查更新…」检查更新。检测到新版本时可一键更新——Plumb 会下载更新包、校验其 SHA-256 完整性，然后重开进入一个小型安装器替换 `/Applications/Plumb.app` 并自动重启应用。如果 app bundle 归你所有（例如从 DMG 拖拽安装），安装器会静默替换、无需密码；否则会请求一次密码。在稳定签名身份就位后，辅助功能 / 屏幕录制权限可跨更新保留（见[为什么权限可能需要重新授权](#为什么权限可能需要重新授权以及如何修复)）。

## 系统要求

- **macOS 26+**（基于 macOS 26 SDK 构建，使用 Liquid Glass 界面，不支持更低版本）
- Xcode Command Line Tools（`xcode-select --install`）

## 本地构建

```bash
# 运行测试
swift test

# 构建 Release 版本
swift build -c release

# 直接运行
./.build/release/Plumb
```

## 打包与发布

### 一键发布（推荐）

`scripts/release.sh` 端到端完成整个流程 —— bump 版本、构建、签名、打包、打 tag、推送、发布 GitHub Release、更新 OTA appcast：

```bash
# 先写 5 语言 OTA notes（en/zh/es/fr/ja，每种一行）
scripts/release.sh --print-notes-template > /tmp/notes.txt
$EDITOR /tmp/notes.txt

# 然后发布（默认本地签名）
bash scripts/release.sh 2.0.50 --notes-file /tmp/notes.txt
```

执行顺序：预检（工作树、测试、release 构建、密钥扫描）→ bump 5 个 README badge → 构建签名 `.app` + DMG + OTA zip → 校验 codesign（并断言指定要求是证书 leaf hash，让 TCC 权限跨更新保留）→ 打 tag + 推送 → 创建 GitHub Release 并上传 assets → 更新 `appcast.json`（version/url/sha + 5 语言 notes）。完整细节与安全说明见 [RELEASING.md](./RELEASING.md)。

### 单独构建产物

```bash
scripts/build_app.sh      # 生成 dist/Plumb.app（用 Plumb Local Signer 签名）
scripts/create_dmg.sh     # 生成 dist/Plumb.dmg
scripts/create_zip.sh     # 生成 dist/Plumb-<version>.zip（用于 OTA）
```

DMG 包含 `Plumb.app` 和 `Applications` 快捷方式 —— 拖拽安装。

### 签名模式

| 模式 | 适用 | 方式 |
| --- | --- | --- |
| **本地签名**（默认） | 日常构建、测试 | `scripts/build_app.sh` 自动用 `Plumb Local Signer`（先跑一次 `scripts/make_signing_cert.sh`） |
| **Developer ID + 公证** | 公开发发分、无 Gatekeeper 拦截 | `scripts/release.sh --sign developer-id`（需 `DEVELOPER_ID_APP` + `NOTARY_PROFILE` 环境变量），或单独跑 `scripts/sign_and_notarize.sh` |

> ⚠️ 本地签名/未公证的 DMG 在新 Mac 上可能被 Gatekeeper 拦截，可能显示「已损坏」—— 运行 `xattr -dr com.apple.quarantine /Applications/Plumb.app`（见[常见问题](#常见问题)）。

## 常见问题

<details>
<summary><b>打开 Plumb.app 时提示「已损坏」或「无法验证开发者」？</b></summary>

这是非公证分发的常见 Gatekeeper 流程，**不是应用自身代码损坏**。可执行：

```bash
xattr -dr com.apple.quarantine /Applications/Plumb.app
```

或前往 `系统设置 → 隐私与安全性`，点击页面底部的「仍要打开」。

</details>

<details>
<summary><b>每次从源码重新编译后权限都失效？</b></summary>

你在使用裸可执行（`swift run`）或 ad-hoc 的 `.app`。两者都没有稳定的签名身份，macOS 会把每次构建当成新应用。每次重新构建后需重新授予这两个权限（辅助功能、屏幕录制）。

要让授权跨重新构建保留，需要受信任的签名身份。`scripts/make_signing_cert.sh` 会生成一张带 `codeSigning` 扩展密钥用法的自签名代码签名证书；在你的机器上信任之后，`scripts/build_app.sh` 会自动使用它，授权即可跨重新构建保留。该证书的信任步骤会写入 admin 信任域，因此在部分 macOS 版本上必须在交互式 Terminal 里运行（`sudo security add-trusted-cert` 步骤需要交互式密码）。

</details>

<details>
<summary><b>居中功能不生效？</b></summary>

请检查是否已授予 **辅助功能（Accessibility）** 权限：`系统设置 → 隐私与安全性 → 辅助功能`，并确保 Plumb 处于开启状态。授权后可能需要重启 Plumb。

</details>

<details>
<summary><b>多显示器场景下窗口居中位置不准？</b></summary>

请授予 **屏幕录制（Screen Recording）** 权限，Plumb 会通过 `CGWindowList` API 作为辅助信号来更精确地识别窗口所属屏幕与坐标系。

</details>

<details>
<summary><b>我手动拖动了窗口，又被自动居中回来了？</b></summary>

在当前 App 激活 / Space 周期内，真正移动或缩放窗口后，Plumb 会保留你设置的位置与尺寸。重新激活 App 或切换 Space 会开始新的布局周期，届时窗口可能再次被居中或平铺。

</details>

## 开源协议

本项目基于 [MIT License](./LICENSE) 开源。

---

<div align="center">

[English](./README.md) · **简体中文** · [Español](./README.es.md) · [Français](./README.fr.md) · [日本語](./README.ja.md)

如果 Plumb 对你有帮助，欢迎 ⭐ Star 支持。

</div>
