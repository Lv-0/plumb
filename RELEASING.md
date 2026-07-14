# RELEASING.md — Plumb 发布流程

> 本文件是**发布操作手册**。每次发版前通读「检查清单」，然后按「标准流程」执行。
> 自动化入口：`scripts/release.sh`（一键完成「构建→验证→打 tag→推送→发布→更新 appcast」）。

---

## 1. 前置条件（一次性配置，已就绪则跳过）

| 项 | 检查命令 | 说明 |
|----|----------|------|
| 本地签名身份 `Plumb Local Signer` | `security find-identity -v \| grep "Plumb Local Signer"` | 缺失则跑 `scripts/make_signing_cert.sh`（一次性，需管理员密码）。**关键**：TCC 权限跨更新保留依赖此稳定身份，ad-hoc 签名会让每次更新都重置权限。 |
| 凭据文件 | `ls /Users/space/IdeaProjects/comv/setting.txt` | 仓库**外**（父目录），含 `github token:` 和 `mac 密码：` 两行。被 `.gitignore` 忽略，永不进 commit。详见 `LOCAL_SECRETS.md`。 |
| 干净工作树 | `git status` | 发版前工作树应干净（无未提交改动）；若要随版发布新代码，先单独 commit 再发版。 |
| 与 origin 同步 | `git fetch --prune --tags origin && git status` | 本地 main 不得落后或分叉；`release.sh` 会再次强制检查。 |

---

## 2. 版本号约定

- 格式：`MAJOR.MINOR.PATCH`（语义化版本），当前大版本 `2.0.x`。
- **只升不降**：新版本号必须严格大于上一个已发布的 tag（`git tag --sort=-v:refname | head -1` 查最新）。
- 版本号出现在 6 处，发版时全部更新：
  1. `README.md` / `README.es.md` / `README.fr.md` / `README.ja.md` / `README.zh.md` 的 release badge（第 16 行附近）
  2. 构建产物 `Info.plist` 的 `CFBundleShortVersionString` + `CFBundleVersion`（由 `build_app.sh` 的 `VERSION` 注入）
  3. `dist/Plumb-{VERSION}.zip` 文件名
  4. git tag `v{VERSION}`
  5. GitHub Release 名 `{VERSION}`
  6. `appcast.json` 的 `version` / `url`（`release.sh` 自动写）

---

## 3. 检查清单（每次发版**逐项**执行）

发布涉及外部副作用（tag、push、GitHub Release、OTA 推送给所有用户），不可撤销。发版前确认：

```bash
# A. 工作树状态：确认要发布的改动都已 commit
git status --short                    # 应为空
git log --oneline origin/main..HEAD   # 看本地领先 origin 的 commit

# B. 密钥安全扫描（commit/push 前必做）
git diff origin/main..HEAD | grep -iE 'ghp_[A-Za-z0-9]{20,}|gho_|github_pat_|setting\.txt|LOCAL_SECRETS|Jxp' \
  && echo "STOP: 密钥泄露" || echo "✓ clean"

# C. 测试 + release 构建
swift test                            # 全绿
swift build -c release                # 无错
bash scripts/tests/release_safety_tests.sh  # 发布脚本顺序与 HTTP 失败闭合门禁

# D. 确认上一个已发布版本（用来决定新版本号）
git tag --sort=-v:refname | head -1   # 例如 v2.0.47
```

- **B 项命中任何一条 → 立即停止**，不得提交/推送。命中说明密钥已进 commit，按 `LOCAL_SECRETS.md` 的「安全建议」撤销并重发 token。
- 若要随版本发布**新代码**：先把新代码 commit（功能 commit + release commit 分开，见下文「commit 结构」），再跑 `release.sh`。

---

## 4. 标准流程（一键）

```bash
# 发版 v2.0.48（举例）
./scripts/release.sh 2.0.48
```

`release.sh` 自动完成：
1. 预检（工作树干净 / fetch 后确认不落后且不分叉 / 测试通过 / release 构建通过 / 密钥扫描）
2. 升 5 个 README badge → commit `release: v{VERSION}`
3. `build_app.sh` + `create_dmg.sh` + `create_zip.sh`（本地签名）
4. 校验签名（codesign verify + 指定要求 = 证书 leaf hash，非 cdhash）
5. 打 tag `v{VERSION}` + push commits & tag 到 origin
6. 创建 GitHub Release（body 来自 `RELEASE_NOTES_FILE` 或交互生成）+ 上传 dmg/zip
7. 更新 `appcast.json`（version/url/sha + 5 语言 notes）→ commit + push

**前置**：`release.sh` 需要交互编辑 appcast notes（5 语言），或通过 `--notes-file` 提供预写好的 notes。详见脚本 `--help`。

### 4.1 appcast notes（5 语言，OTA 对话框文案）

`appcast.json` 的 `notes` 字段是用户在 OTA 更新对话框里看到的**简短摘要**（2–4 句，单段），**不是** GitHub Release 的完整 markdown（那是 `dist/release-notes-v{VERSION}.md`）。两者区别：

| | `dist/release-notes-v{VERSION}.md` | `appcast.json` → `notes` |
|---|---|---|
| 用途 | GitHub Release 页面 | 应用内 OTA 更新对话框 |
| 格式 | 完整 markdown，双语（en + zh 段落） | 单段纯文本 × 5 语言（en/zh/es/fr/ja） |
| 长度 | 不限 | 2–4 句（对话框空间有限） |
| 谁写 | 手写 | 手写（**不能从 markdown 自动提取**，因为是创意性多语本地化摘要） |

`release.sh` 会用 `$EDITOR` 打开一个临时文件让你填 5 语言 notes（或 `--notes-file` 指定预写文件）。模板：

```
en: <2-4 句英文摘要，突出最重要的 1-2 个改动 + 测试数>
zh: <中文摘要>
es: <西语>
fr: <法语>
ja: <日语>
```

历史 notes 风格参考：`git show e220550 -- appcast.json`（v2.0.45 的 notes）。

---

## 5. commit 结构（历史约定）

每个版本通常是 2 个 commit：

1. **功能 commit**（若有代码改动）：`fix: ...` / `feat: ...` / `refactor: ...`，只含源码改动。
2. **release commit**：`release: v{VERSION}`，**只**含 5 个 README badge 的版本号 bump。

之后：
3. `release.sh` 自动产生：git tag、`chore(release): appcast.json for v{VERSION}`（version/url/sha）、`chore(release): refresh appcast notes for v{VERSION}`（5 语言 notes）。

> ⚠️ `release` commit 和 appcast 两个 `chore` commit 是分开的，因为 badge bump 是「声明发版」、appcast sha 是「构建产物就绪后回填」、appcast notes 是「文案就绪后回填」——三者时机不同，分开 commit 让 history 可读、可回滚。

---

## 6. 签名路径

代码保留两条构建签名路径，但当前发布入口**只允许本地签名**：

| | 本地签名（默认） | Developer ID + 公证 |
|---|---|---|
| 脚本 | `release.sh`（默认） | `release.sh --sign developer-id`（当前硬阻断） |
| 身份 | `Plumb Local Signer`（自签） | `Developer ID Application: ...`（需 Apple 开发者账号） |
| 公证 | ❌ 不公证 | ✅ notarytool + stapler |
| Gatekeeper | 首次打开可能被拦为「已损坏」→ `xattr -dr com.apple.quarantine` | ✅ 直开 |
| TCC 跨更新保留 | ✅（证书 leaf hash 指定要求） | 同 Team ID 的后续更新可保留；首次从本地证书迁移不能直接保证 |
| 环境变量 | 无需 | `DEVELOPER_ID_APP` + `NOTARY_PROFILE` |
| 当前可用 | ✅ 本机已就绪 | ⛔ bridge signer allowlist 与分阶段 OTA 迁移发布前禁止发版 |

> **当前禁止 Developer ID 发版。** 已发布客户端把 `Plumb Local Signer` 的 leaf hash 纳入 designated requirement，直接发布 Developer ID ZIP 会在客户端签名身份校验阶段失败。`release.sh` 会在任何构建、tag、push 或发布动作前硬阻断该模式。解除门禁前必须先以本地签名发布 bridge（精确 allowlist 未来 signer），并为未安装 bridge 的旧客户端提供持续可达的分阶段升级路径；静态单一 appcast 不能自动解决漏装 bridge 的客户端。

保留的 Developer ID 构建实现严格按以下顺序生成最终产物：签名 app（Hardened Runtime + timestamp）→ 精确校验 Authority/Team ID → 从该 app 创建 DMG → 签名并提交 DMG 公证 → staple/验证 app 与 DMG → Gatekeeper 验证 → 最后从已 staple 的 app 创建 OTA ZIP。它只供 bridge 准备与本地验证；当前不得用于发布。公证前不会运行 Gatekeeper 验证，因为尚未取得票据的 Developer ID app 可能被系统正确拒绝。

`scripts/sign_and_notarize.sh` 可在 bridge 开发期间分阶段运行 `--sign-app` / `--notarize-dmg` 来验证产物，但不得把结果发布或写入 appcast。待 bridge 与分阶段迁移完成后，再恢复由 `release.sh --sign developer-id` 统一编排。`scripts/release_build.sh` 是旧入口，仅保留作参考。

---

## 7. OTA 工作原理（背景）

应用内更新读 `appcast.json`：
1. `UpdateCoordinator` 拉取 `appcast.json`，比对 `version` 与本机 `CFBundleShortVersionString`。
2. 有新版 → 用 `notes[当前语言]`（回退 en）弹对话框。
3. 用户确认 → 下载 `url` 指向的 zip，校验 `sha256` 和归档/bundle/签名信任边界，再事务安装。

**所以 `appcast.json` 是 OTA 的唯一索引**：`version`/`url`/`sha256` 错了用户就更新不到或校验失败；`notes` 错了用户看到错误描述。三者必须在 GitHub Release 的 DMG/ZIP 均上传成功，且远端名称、状态和字节数复核通过**之后**再更新（否则用户被提示去下载一个不存在或不完整的 zip）。所有 GitHub HTTP 请求均以 4xx/5xx 为失败，`release.sh` 严格遵循这个顺序。

GitHub Release asset 一经发布即视为**不可变**。重跑 `publish_release.sh` 时，若远端已有同名 asset，脚本会实际下载并比较 SHA-256：完全一致才复用；不一致立即失败，绝不 DELETE/替换。`TAG` 也必须严格等于 `v${VERSION}`。

`minOS` 字段：当前 `26.0`。提升最低系统要求时才改。

---

## 8. 回滚 / 修复已发版本

GitHub Release 和 tag 一旦发布，**不应删除**（可能有用户已经更新到该版本）。处理方式：

- **appcast notes 写错了**（最常见）：直接改 `appcast.json` → commit `chore(release): fix appcast notes for v{VERSION}` → push。无害（只影响尚未更新的用户看到的文案）。
- **构建有 bug**：发**新版本**（如 v2.0.48 → v2.0.49）修复，**不要**改已发布的 tag/release。更新 `appcast.json` 指向新版本即可让用户继续往前更新。
- **sha256 对不上 / 已发布产物需要变化**：不得覆盖原 tag 或 asset；修复构建后发布一个更高的新版本。只有本地文件与线上同名 asset 的 SHA-256 已完全一致时，才可用 `publish_release.sh` 安全续跑中断的发布。

---

## 9. 脚本索引

| 脚本 | 用途 | 何时用 |
|------|------|--------|
| `scripts/release.sh` | **一键发版**（本文件主流程） | 每次发版 |
| `scripts/build_app.sh` | 本地签名构建 .app | `release.sh` 内部调用；单独重构建时 |
| `scripts/create_dmg.sh` | 打 DMG | `release.sh` 内部 |
| `scripts/create_zip.sh` | 打 OTA zip | `release.sh` 内部 |
| `scripts/publish_release.sh` | 创建 GitHub Release + 上传 + 更新 appcast(version/url/sha)；已有 asset 仅同 SHA 复用 | `release.sh` 内部；仅续跑完全相同产物的中断发布 |
| `scripts/sign_and_notarize.sh` | Developer ID 签名 + 公证 | 仅 bridge 开发/本地验证；当前不得发布产物 |
| `scripts/tests/release_safety_tests.sh` | 发布脚本语法、产物顺序与 HTTP 失败注入门禁 | 修改发布脚本后、发版前 |
| `scripts/release_build.sh` | 旧的 Developer ID 全流水线（保留参考） | 已被 `release.sh` 取代 |
| `scripts/make_signing_cert.sh` | 一次性生成本地签名身份 | 仅初次配置 |
| `scripts/verify_signing_identity.sh` | 查 .app 签名身份 | 调试 |
| `scripts/generate_icons.sh` | 生成 AppIcon.icns / StatusIconTemplate.png | `build_app.sh` 内部 |
