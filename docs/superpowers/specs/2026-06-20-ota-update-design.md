# 软件内 OTA 自动更新 — 设计文档

- 日期：2026-06-20
- 状态：已与用户确认（架构/数据格式/组件/错误处理四节均经确认），待实现
- 目标：为 Plumb 增加软件内自动更新（OTA）。用户无需手动去 GitHub 下载 DMG、拖拽覆盖，即可一键升级；并保证升级后 **TCC 权限（辅助功能 / 屏幕录制）不失效**。

## 1. 背景与定位

### 1.1 用户诉求

「每次更新版本后都要重新授权权限，能否用软件内 OTA 升级避免重复授权？」

### 1.2 关键澄清：OTA 与权限保留是两件正交的事

TCC 权限按应用的**签名身份**（designated requirement）授权，与更新方式无关：

| | 解决权限重置？ | 改善更新体验？ |
|---|---|---|
| 稳定签名修复（另一 spec，已实现） | ✅ | ❌ |
| OTA 自动更新（本 spec） | ❌ | ✅ |
| 两者结合 | ✅ | ✅ |

- 即使用 OTA 后台替换新 `.app`，若新 `.app` 仍是 **ad-hoc 签名**（DR=cdhash），权限照样丢。
- 只有当新 `.app` 来自**稳定证书签名构建**（签名修复 spec 已实现），OTA 替换后权限才保留。
- **结论**：OTA 与签名修复正交，但 OTA 装的新 app 依赖签名修复才能保留权限。两者协同发布。

### 1.3 已确认的核心决策

| 决策点 | 选择 |
|--------|------|
| 实现方式 | 自研最小 OTA（零第三方依赖，契合纯 SwiftPM 项目） |
| 更新源 | `appcast.json` 随发版提交到 repo，经 `raw.githubusercontent.com` 拉取 |
| 安装方式 | 独立安装器进程：主 app 退出后由安装器提权替换 `/Applications/Plumb.app` |
| 更新包校验 | sha256 完整性校验（防损坏/截断） |
| 检查时机 | 启动后台静默检查一次 + 菜单「检查更新…」手动触发 |
| 版本号 | 语义化版本 semver（`major.minor.patch`） |
| 降级策略 | 只升不降 |

## 2. 架构与流程

### 2.1 双入口（同一 SwiftPM target）

主 app 与安装器是**同一可执行文件的两个模式**，通过 `UserDefaults` 标志分流（沿用 `main.swift` 现有自测模式约定，而非命令行参数）：

- 正常模式：`main.swift` 现有分支 → `AppDelegate`
- 安装器模式：主 app 退出前写入 `defaults write com.comet.plumb installerMode -bool true` 并设置待安装路径，再以 Launch Services 重开自身 → `main.swift` 检测到 `installerMode` → 进入 `UpdateInstaller` delegate → 完成后清零标志并重启正常模式。

> 采用 UserDefaults 标志而非 `--installer` 命令行参数，原因是本项目自测 harness 一贯用 `defaults write ... then open app` 的 Launch Services 触发方式（见 `main.swift` 注释与 SelfTest*.swift）。保持一致。

### 2.2 更新流程

```
主 app 启动（正常模式）
   │
   ├─（后台异步）拉 appcast.json → semver 比较 →
   │     旧/相等/本机 < minOS → 静默；新版本 → 菜单栏徽章提示
   │
   └─用户点「检查更新…」或接受提示
        │
        ├─展示更新信息（版本号 + 当前语言 notes）→ 用户确认「更新」
        ├─下载 Plumb-{ver}.zip 到临时目录
        ├─sha256 校验 → 不匹配则报错中止、删临时文件
        ├─解压 zip 得到新 Plumb.app，校验目录结构
        ├─写 installerMode 标志 + 待安装 app 临时路径到 UserDefaults
        ├─以 Launch Services 重开自身（进入安装器模式）
        └─主 app 正常模式退出
              │
              └─安装器进程（极简 NSWindow，.regular 激活策略）：
                    ├─显示进度
                    ├─AuthorizationCopyRights 提权（弹系统密码框，一次）
                    ├─原子替换 /Applications/Plumb.app（先到临时目录就位+校验，再一次性替换）
                    ├─清零 installerMode 标志
                    └─以 Launch Services 启动 /Applications/Plumb.app（回到正常模式）
```

### 2.3 关键架构不变量

- **主 app 不替换自己**：主 app 退出后由独立安装器进程完成替换，避免「运行中二进制被覆盖」。
- **提权隔离**：只有安装器进程接触 `AuthorizationCopyRights` 与 `/Applications`。主 app 永不提权、不写 `/Applications`。安全边界清晰。
- **与签名修复协同**：OTA 装的新 `.app` 来自 `build_app.sh` 稳定证书签名分支 → 替换后 DR 不变 → TCC 权限保留。

## 3. 数据格式与版本链

### 3.1 appcast.json（单条记录）

随发版提交到 repo（路径 `dist/appcast.json`，发布时一并 push），经 `raw.githubusercontent.com/Lv-0/plumb/main/dist/appcast.json` 拉取：

```json
{
  "version": "1.0.6",
  "url": "https://github.com/Lv-0/plumb/releases/download/v1.0.6/Plumb-1.0.6.zip",
  "sha256": "a3f5...e1b2",
  "notes": {
    "en": "In-app updates + permissions now survive updates.",
    "zh": "软件内更新 + 权限现在可跨更新保留。",
    "es": "(示例占位符，实际发版时填完整)",
    "fr": "(示例占位符，实际发版时填完整)",
    "ja": "(示例占位符，实际发版时填完整)"
  },
  "minOS": "26.0"
}
```

设计要点：
- **单条记录而非数组**：只指向「最新版本」，配合「只升不降」，避免历史版本匹配复杂度。发新版只需覆盖此文件。
- **notes 多语言**：复用项目现有 5 语策略（en/zh/es/fr/ja），按当前 UI 语言取，缺则回退 en。
- **sha256**：对下载 zip 做完整性校验（防损坏/截断）。
- **minOS**：主 app 拉到 appcast 后先比 `minOS` 与本机系统版本，不满足则**静默不提示**，避免引导装一个跑不起来的版本。
- **url 指向 Releases 资产**：zip 由 `build_app.sh` 产出、`create_zip.sh`（新增）旁路生成、`publish_release.sh` 上传。zip 内即签名后的 `Plumb.app`，与 DMG 同源。

### 3.2 版本来源链

`scripts/build_app.sh` 的 `VERSION` 变量 → 写入 `Info.plist` 的 `CFBundleShortVersionString` → 主 app 启动读取作为「当前版本」 → 与 appcast 的 `version` 做 semver 比较（只升不降）。

### 3.3 zip 签名不变性

zip 内的 `Plumb.app` 走 `build_app.sh` 稳定证书签名分支，替换进 `/Applications` 后 DR 不变 → TCC 权限保留。OTA 与签名修复在此处交汇。若用户机器无稳定证书（仍 ad-hoc 构建），OTA 装的也是 ad-hoc，权限仍会丢——README 注明此前提。

## 4. 组件拆分

每个文件单一职责、可独立测试。

| 文件 | 职责 | 依赖 |
|------|------|------|
| `AppVersion.swift` | semver 解析与比较（纯逻辑，无 IO）。读取 `CFBundleShortVersionString` 作为当前版本。`struct AppVersion: Comparable`。 | 无 |
| `UpdateManifest.swift` | appcast.json 的 `Codable` 模型 + JSON 解码。`struct UpdateManifest: Codable { version, url, sha256, notes:[String:String], minOS }`。提供 `notes(for locale)` 回退 en。 | AppVersion（minOS 比较） |
| `UpdateChecker.swift` | 拉取 appcast（`protocol ManifestFetcher { func fetch() async throws -> Data }`，生产 `URLSessionManifestFetcher`，测试 `MockManifestFetcher`）、解析、版本比较、minOS 门槛。返回 `enum UpdateResult { .upToDate / .available(UpdateManifest) / .error }`。 | AppVersion, UpdateManifest |
| `UpdateDownloader.swift` | 下载 zip 到临时目录、sha256 校验（CryptoKit）、解压得到 `Plumb.app`，校验目录结构。返回临时 app 路径或抛错。 | CryptoKit |
| `UpdateInstaller.swift` | 安装器模式入口（installerMode 标志触发）。极简 NSWindow 显示进度，`AuthorizationCopyRights` 提权，执行 `cp -R` 原子替换 `/Applications/Plumb.app`，清标志，重启主 app。 | 无 |
| `UpdateCoordinator.swift` | 编排者：Checker→展示→用户确认→Downloader→写 installerMode→重开→退出。主 app 调用的唯一入口。后台检查与手动检查共用。 | 上述全部 |
| `main.swift`（改） | 加 `installerMode` 分支（在自测分支之后、正常 AppDelegate 之前）：命中 → `UpdateInstallerDelegate` + `.regular` 激活策略 + `run()`。 | UpdateInstaller |
| `AppDelegate.swift`（改） | 菜单加「检查更新…」；`applicationDidFinishLaunching` 异步调 `UpdateCoordinator.checkForUpdatesInBackground()`；更新可用时菜单栏徽章提示。 | UpdateCoordinator |
| `Localization.swift`（改） | 加 5 语 keys：`checkForUpdates`、`newVersionAvailable`、`update`、`updating`、`updateFailed`、`updateComplete`、`cancel` 等。 | — |

### 4.1 测试覆盖

- **纯逻辑单测（PlumbTests）**：
  - `AppVersion` semver 比较：`1.0.5 < 1.0.10`、`1.2.0 > 1.1.9`、相等、降级忽略。
  - `UpdateManifest` 解码：完整 JSON、缺 notes 语种回退 en、minOS 不满足判为「无更新」。
  - `UpdateChecker`：注入 `MockManifestFetcher` 返回固定 JSON，验证 `.upToDate/.available/.error` 分支与 minOS 门槛，全程不触网。
  - `UpdateDownloader` sha256：正确 hash 通过、错误 hash 抛错（用固定临时文件，不触网）。
- **手动端到端（交付前）**：构造一个「新版本」appcast（version 高于当前），验证主 app 检测→下载→sha256 校验→安装器提权替换→重启→版本号已变，**且权限保留**（依赖签名修复落地）。

## 5. 错误处理与边界

| 环节 | 失败情况 | 处理 |
|------|---------|------|
| 后台检查 | 网络/超时/解析失败 | **静默忽略**（不打扰），下次启动再试。记日志（复用已有日志机制）。 |
| 手动检查 | 同上 | 弹窗提示「检查更新失败，请检查网络后重试」，不阻塞 app。 |
| 版本比较 | appcast version 格式非法 | 视为「无更新」。 |
| minOS 门槛 | 本机系统 < minOS | 静默不提示。 |
| 下载 | 网络中断/空间不足 | 删临时文件，提示「下载失败，请重试」。 |
| sha256 校验 | hash 不匹配 | 删临时文件，提示「更新包校验失败，可能已损坏，请稍后重试或前往 GitHub 手动下载」。 |
| 解压 | zip 损坏/结构不对 | 同上提示。 |
| 提权 | 用户取消/密码错误 | 安装器窗口提示「安装已取消」，**保留旧版本不动**。 |
| 替换 | cp 失败（磁盘满等） | 回滚：原 `/Applications/Plumb.app` 不动，提示安装失败。 |
| 重启主 app | 失败 | 提示「更新已完成，请手动启动 Plumb」。 |

### 5.1 核心安全/一致性不变量

- **原子替换**：新 app 先完整就位并通过 sha256 校验，才触发提权替换；替换失败绝不留半装状态（原 app 不动）。
- **提权最小化**：安装器只执行预定义 `cp -R` + 重启，路径来自主 app 校验后的固定临时位置，不接受用户输入路径。
- **只升不降**：semver 比较确保不引导降级。
- **权限保留前提**：替换进来的新 app 来自签名构建（DR 稳定）才保留权限。跳过签名修复则权限仍丢，README 注明。

## 6. YAGNI（明确不做）

- ❌ 增量更新（delta patch）——单 .app 体积小，全量替换足够。
- ❌ 强制更新/到期机制——菜单栏小工具无此需求。
- ❌ 更新历史/回滚到旧版本——「只升不降」，GitHub Releases 即历史归档。
- ❌ 自定义更新源配置——硬编码 `Lv-0/plumb` repo，YAGNI。
- ❌ 自动静默安装（不经用户确认）——总要用户点「更新」，避免后台静默提权。
- ❌ EdDSA 防篡改签名——已选 sha256 完整性校验，足够当前威胁模型。
- ❌ 后台定时轮询——仅启动检查一次 + 手动，避免常驻网络活动。

## 7. 涉及文件清单

| 文件 | 改动 |
|------|------|
| `Sources/Plumb/AppVersion.swift` | **新增** — semver 解析与比较。 |
| `Sources/Plumb/UpdateManifest.swift` | **新增** — appcast Codable 模型。 |
| `Sources/Plumb/UpdateChecker.swift` | **新增** — 拉取/比较/门槛，ManifestFetcher 协议。 |
| `Sources/Plumb/UpdateDownloader.swift` | **新增** — 下载/sha256/解压。 |
| `Sources/Plumb/UpdateInstaller.swift` | **新增** — 安装器模式（提权替换）。 |
| `Sources/Plumb/UpdateCoordinator.swift` | **新增** — 编排者。 |
| `Sources/Plumb/main.swift` | **修改** — 加 `installerMode` 分支。 |
| `Sources/Plumb/AppDelegate.swift` | **修改** — 菜单项 + 后台检查。 |
| `Sources/Plumb/Localization.swift` | **修改** — 5 语 OTA 文案 keys。 |
| `Tests/PlumbTests/*OTA*.swift` | **新增** — 纯逻辑单测。 |
| `scripts/create_zip.sh` | **新增** — 把签名后 `.app` 打成 `Plumb-{ver}.zip`，供 OTA。 |
| `scripts/build_app.sh` | **修改** — 暴露 VERSION 给 zip 脚本（已读 VERSION 变量）。 |
| `scripts/publish_release.sh` | **修改** — 上传 zip asset；维护 `dist/appcast.json`。 |
| `dist/appcast.json` | **新增/随发版更新** — 版本清单。 |
| `README.md` / `README.zh.md` | **修改** — 文档化软件内更新功能。 |

## 8. 与签名修复的发布关系

- 签名修复（另一 spec）已实现（6 commits），卡在证书信任需 sudo 密码。
- OTA（本 spec）待实现。**OTA 实现本身不依赖签名修复的 cert 信任步骤**——两者可独立编码与单测。
  只有「端到端验证 TCC 权限保留」（成功标准 #5）需要签名修复的 cert 已被信任。
- **发版顺序**：两者一起发版（OTA 首版即装签名后的 app）。用户一次升级即同时获得「权限保留 + 自动更新」。
- 实现顺序建议：先解锁签名修复的 cert 信任（需用户 sudo 密码），再做 OTA，最后联合打包发版——确保 OTA 装的 app 权限能保留，端到端可验证。

## 9. 成功标准（验收）

1. `AppVersion` / `UpdateManifest` / `UpdateChecker` / `UpdateDownloader` 纯逻辑单测全绿（注入 mock，不触网）。
2. 菜单「检查更新…」可手动触发；启动时后台静默检查一次（有缓存，避免每次启动都请求）。
3. 检测到新版本：展示版本号 + 当前语言 notes，用户点「更新」后下载 → sha256 校验 → 安装器提权替换 → 重启。
4. 替换失败/用户取消：原 `/Applications/Plumb.app` 完好不动，提示明确。
5. **端到端**：安装的新版本版本号已变，且（依赖签名修复）TCC 权限保留。
6. `scripts/create_zip.sh` 产出 `Plumb-{ver}.zip`，`publish_release.sh` 上传 zip + 维护 appcast.json。
7. README（en/zh）文档化软件内更新。
8. `swift test` 全绿、`swift build -c release` 成功。
