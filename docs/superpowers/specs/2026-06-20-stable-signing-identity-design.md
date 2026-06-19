# 跨更新保留 TCC 权限的稳定签名身份 — 设计文档

- 日期：2026-06-20
- 状态：已与用户确认，待实现
- 目标：每次发版更新 Plumb 后，用户此前授予的 **Accessibility / Screen Recording** 权限不再失效，无需「先删除旧权限再重新授权」。

## 1. 背景与根因

### 1.1 现象

用户报告：每次用新版本的 `Plumb.app` 覆盖安装后，原先在「系统设置 → 隐私与安全性 → 辅助功能 /
屏幕录制」中已授予 Plumb 的权限都会失效，必须在系统设置里**先删除 Plumb 旧条目、再重新添加并授权**。
这破坏了「静默更新」的体验。

### 1.2 根因（已实测验证）

macOS 的 TCC（Transparency, Consent and Control）数据库**以应用的稳定签名身份（designated
requirement, DR）为键**保存授权记录。当前 `dist/Plumb.app` 是 **ad-hoc 签名**：

```
$ codesign -dvv dist/Plumb.app
Signature=adhoc
TeamIdentifier=not set

$ codesign -d -r- dist/Plumb.app
# designated => cdhash H"c127bf4845e029fe3c4c1ad9e5413108a31eafae"
```

Ad-hoc 签名**没有任何稳定身份**，其 designated requirement 退化为「绑定到某个具体的 cdhash」。
而 cdhash 是对可执行文件**逐字节**的哈希——每次重新编译都会变化。后果：每次发版的 cdhash 都不同，
macOS 视其为**完全不同的应用**，旧 TCC 记录无法匹配新应用 → 授权失效。

> 关键结论：这是**签名层**的问题，不是应用代码的问题。`AccessibilityPermission` /
> `ScreenCapturePermission` / `LaunchAtLogin` 的轮询与跳转逻辑本身是正确的。修复必须发生在
> 「如何签名」这一层，应用代码无需任何行为变更。

### 1.3 已验证的机制（证据）

在 `/tmp` 临时 keychain 中实测了完整链路：

1. `openssl req -x509` 生成自签名证书（CN=`Plumb Local Signer`）。
2. `openssl pkcs12 -export -legacy` 导出为 p12（**必须用 `-legacy`**——OpenSSL 3.x 默认加密算法
   macOS `security` 工具无法读取，会报 `MAC verification failed`）。
3. `security import signer.p12` 导入 keychain——成功，但 `find-identity -v` 报告
   `0 valid identities found`，原始身份为 `CSSMERR_TP_NOT_TRUSTED`。
4. **必须用 `security add-trusted-cert -d -r trustRoot -p codeSign` 将其设为受信任的代码签名根**
   （此步需一次管理员授权）。信任设置后，该证书才成为 `codesign` 可用的「有效身份」。
5. 信任后，`codesign --sign "Plumb Local Signer"` 即可对任意构建产物稳定签名；签名产物的
   designated requirement 退化为「证书 subject + issuer」式的**稳定身份要求**，而非 cdhash。

由此确认：**用一张固定的、被信任的自签名证书签名 → DR 稳定 → TCC 记录可跨更新复用**。

## 2. 关键决策

| 方案 | 说明 | 取舍 |
|------|------|------|
| **A. 自签名证书 + 固定 designated requirement（采用）** | 一次性生成一张自签名代码签名证书并存入登录 keychain（CN 固定），用 `add-trusted-cert` 设为受信任；此后每次 `build_app.sh` 都用该证书签名。DR 绑定证书身份而非 cdhash → 跨更新稳定。 | 修复根因；无需付费 Apple Developer 账号；Gatekeeper 仍提示「未知开发者」（README FAQ 已覆盖，用户体验与现状一致）。 |
| B. 仅靠 ad-hoc + bundleID 试图稳定 | 期望 TCC 只按 bundleID 绑定。 | 近版 macOS 对 ad-hoc 仍按 cdhash 记账，身份漂移依旧；不稳定，不可靠。**不采用**。 |
| C. 仅在应用内提示重授权 | 检测到授权丢失时引导用户重新授权。 | 仅美化表象，根因未解，用户仍需每次重授权。**不采用**（本次范围确认仅做签名修复）。 |

用户已确认：**采用 A，范围严格限定为签名修复**（不叠加 in-app 重授权提示）。

## 3. 架构：签名身份的生成与使用

### 3.1 一次性：证书生成脚本（新增 `scripts/make_signing_cert.sh`）

负责在**开发者本机**生成一次自签名证书并装入登录 keychain、设为受信任。幂等：若同名身份已存在则跳过。

```bash
#!/usr/bin/env bash
set -euo pipefail

CERT_NAME="${PLUMB_SIGNING_IDENTITY:-Plumb Local Signer}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
PW="$(openssl rand -hex 16)"

# 1) 幂等：若登录 keychain 已存在同名身份，直接退出
if security find-identity -v | grep -q "\"${CERT_NAME}\""; then
  echo "签名身份已存在: ${CERT_NAME}（跳过）"
  exit 0
fi

# 2) 生成自签名证书（10 年有效期，足够覆盖多次发版周期）
openssl req -x509 -newkey rsa:2048 -keyout "$WORKDIR/key.pem" \
  -out "$WORKDIR/cert.pem" -days 3650 -nodes \
  -subj "/CN=${CERT_NAME}" >/dev/null 2>&1

# 3) 导出为 p12（-legacy：兼容 macOS security 工具的旧加密）
openssl pkcs12 -export -legacy \
  -in "$WORKDIR/cert.pem" -inkey "$WORKDIR/key.pem" \
  -out "$WORKDIR/signer.p12" -password pass:"$PW" >/dev/null 2>&1

# 4) 装入登录 keychain，并授权 codesign 使用
LOGIN_KC="$(security login-keychain | sed 's/^["]*//; s/["]*$//')"
security import "$WORKDIR/signer.p12" -k "$LOGIN_KC" -P "$PW" -T /usr/bin/codesign

# 5) 设为受信任的代码签名根（需管理员授权一次）
sudo security add-trusted-cert -d -r trustRoot \
  -k "$LOGIN_KC" -p codeSign "$WORKDIR/cert.pem"

echo "签名身份已就绪: ${CERT_NAME}"
```

**设计要点：**

- **幂等**：重复运行不会创建重复证书或报错。
- **`-legacy` 必需**：实测 OpenSSL 3.x 默认加密导致 import 报 `MAC verification failed`。
- **`add-trusted-cert -p codeSign` 必需**：未设信任时证书为 `NOT_TRUSTED`，`codesign` 找不到「有效身份」。
- **一次管理员授权**：仅在创建证书时需要（信任根设置）；之后每次 `build_app.sh` 无需特权。

### 3.2 每次构建：`build_app.sh` 改用证书签名（替换 ad-hoc 签名行）

当前 `scripts/build_app.sh` 末尾：

```bash
codesign --force --deep --sign - "${APP_DIR}" >/dev/null   # ad-hoc，DR=cdhash
```

改为优先使用固定证书；证书不存在时**优雅回退到 ad-hoc** 并打印明显警告（不阻断开发构建）：

```bash
SIGN_IDENTITY="${PLUMB_SIGNING_IDENTITY:-Plumb Local Signer}"
if security find-identity -v | grep -q "\"${SIGN_IDENTITY}\""; then
  codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_DIR}" >/dev/null
  echo "  签名身份: ${SIGN_IDENTITY}（稳定，TCC 权限可跨更新保留）"
else
  echo "  ⚠️ 未找到签名身份 '${SIGN_IDENTITY}'，回退到 ad-hoc 签名。"
  echo "     → 此构建的 TCC 权限将无法跨更新保留。"
  echo "     → 运行 scripts/make_signing_cert.sh 生成稳定签名身份（一次性）。"
  codesign --force --deep --sign - "${APP_DIR}" >/dev/null
fi
```

**设计要点：**

- **优雅降级**：开发者未跑过 `make_signing_cert.sh` 时，`build_app.sh` 仍可工作（ad-hoc），只是不解决
  权限问题，并打印指引。CI / 无 keychain 环境不受阻。
- **显式可选环境变量** `PLUMB_SIGNING_IDENTITY`：允许自定义身份名；默认 `Plumb Local Signer`。
- **不修改 `sign_and_notarize.sh`**：那是 Developer ID 路径，与本次自签名修复正交；将来接入 Developer ID
  时，该脚本会覆盖 `build_app.sh` 的自签名为 Developer ID（TCC 同样按稳定身份保留，本方案天然向上兼容）。

### 3.3 验证 designated requirement 稳定性（构建后）

新增 `scripts/verify_signing_identity.sh`，校验产物的 DR 是否为稳定身份（非 cdhash），用于发版前的门禁：

```bash
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="dist/Plumb.app"
DR="$(codesign -d -r- "${APP_DIR}" 2>&1)"
if echo "${DR}" | grep -q "cdhash"; then
  echo "❌ DR 仍为 cdhash（ad-hoc），TCC 权限无法跨更新保留："
  echo "${DR}"
  exit 1
fi
echo "✅ DR 为稳定身份要求（TCC 权限可跨更新保留）："
echo "${DR}" | grep "designated"
```

> 该脚本作为 release 前自检的一部分（见第 7 节）。
>
> **与优雅降级的关系（重要）**：`build_app.sh` 在证书缺失时回退到 ad-hoc，会让本脚本以非零退出失败。
> 这是有意的——它是**发版门禁**：发版构建必须在证书存在的机器上完成。开发者日常/CI 构建不受此门禁约束
> （不跑此脚本即可）。两者职责清晰：`build_app.sh` 负责产出可用产物（容错），`verify_signing_identity.sh`
> 负责拦截不满足发版要求（ad-hoc）的产物上Release。

## 4. README 文档更新

在 `README.md` 的 **Permissions** 章节或 **Build locally** 章节新增小节，说明：

1. **为什么权限会失效（旧版本）**：ad-hoc 签名 → DR=cdhash → 每次更新被视为新应用。
2. **新行为**：自签名证书 → DR 绑定证书身份 → 跨更新权限保留。
3. **一次性设置（仅从源码构建者）**：`scripts/make_signing_cert.sh`。
4. **明确局限（build-from-source 裸可执行路径）**：`swift build` 产出的**裸可执行文件无 .app 包、
   无稳定身份**，TCC 按 cdhash 记账，权限无法跨构建保留。**稳定权限仅对 `scripts/build_app.sh`
   产出的、用证书签名的 `.app` 包生效**。README 「Build from source」段已存在的裸可执行示例应补此说明。

同时同步到 `README.zh.md`（中文，主仓库默认语言对照）。其余 es/fr/ja 本次**不**同步该技术细节
（保持发版说明的多语言策略：功能文案多语，构建/签名说明仅 en/zh 两语，与现有 README 结构一致）。

## 5. 行为与不变量

- **稳定身份**：所有经 `build_app.sh`（证书存在分支）产出的 `.app`，DR 必须为非 cdhash 的稳定身份要求。
- **DR 内容**：自签名证书的 designated requirement 形如 `identifier "com.comet.plumb" and certificate
  leaf = H"<cert-hash>" and certificate 1 = H"<ca-hash>"`（codesign 自动派生，无需手写）。
- **跨更新复用**：只要证书不变，新旧版本 `.app` 的 DR 一致 → TCC 记录复用 → 权限不失效。
- **bundleID 不变**：`com.comet.plumb` 保持不变（bundleID 也是 TCC 匹配的一部分）。
- **优雅降级**：证书缺失时构建不阻断，仅降级为 ad-hoc 并打印警告。
- **向上兼容 Developer ID**：将来接入 `sign_and_notarize.sh`（Developer ID）时，TCC 按 Team ID 保留，
  机制与本方案一致，无需改动应用代码。

## 6. 测试策略

本方案核心改动在**脚本与签名层**，Swift 应用代码零变更，故测试策略分三档：

### 6.1 既有单元测试（必须全绿，回归保护）

```bash
swift test                        # 所有既有测试（WindowGeometry / Localization / LaunchAtLogin 等）
swift build -c release            # 确保应用仍能正常编译
```

> 这些测试验证「应用代码未被破坏」。签名变更不应影响任何既有测试结果。

### 6.2 脚本级验证（新增）

`scripts/make_signing_cert.sh` 与 `scripts/verify_signing_identity.sh` 的正确性通过**发版前手动集成验证**
（第 7 节）覆盖，不引入需要 keychain / 管理员权限的自动化单测（此类测试不可在 CI/无头环境复现）。

### 6.3 手动集成验证（交付前必须执行，写入 spec）

验证权限真正跨更新保留的端到端流程：

1. 用旧版（ad-hoc）`Plumb.app` 安装并授予 Accessibility + Screen Recording 权限。
2. 运行 `scripts/make_signing_cert.sh`（一次管理员授权）生成证书。
3. `scripts/build_app.sh` 构建新版 `.app`（确认输出「签名身份: Plumb Local Signer」）。
4. `scripts/verify_signing_identity.sh` 确认 DR 非 cdhash。
5. 用新版覆盖安装（替换 `/Applications/Plumb.app`）。
6. 启动新版 → **确认权限仍为已授权状态**（无需删除/重授权）。
7. 权限界面（Permissions tab）显示「已授权」。
8. **关键对照**：在另一台/另一用户下用旧 ad-hoc 覆盖安装，确认权限**仍会失效**（证明根因被正确识别，
   修复确实源于签名而非其他偶然因素）。

## 7. 范围之外（YAGNI）

- ❌ **不**做 in-app 重新授权提示（用户确认本次仅签名修复）。
- ❌ **不**改动 `sign_and_notarize.sh`（Developer ID 路径，与自签名正交）。
- ❌ **不**为 es/fr/ja 同步签名技术说明（保持多语言策略：功能文案多语，构建/签名说明仅 en/zh）。
- ❌ **不**为脚本编写需 keychain/管理员权限的自动化单测（环境不可复现）。
- ❌ **不**迁移旧的 ad-hoc TCC 记录（无 API 可做；旧用户首次升级到此版本时仍需重授权一次，
   此后跨更新稳定）。

## 8. 涉及文件清单

| 文件 | 改动 |
|------|------|
| `scripts/make_signing_cert.sh` | **新增** —— 一次性生成自签名证书 + 设信任（幂等）。 |
| `scripts/verify_signing_identity.sh` | **新增** —— 校验产物 DR 非 cdhash（发版前门禁）。 |
| `scripts/build_app.sh` | **修改** —— 末尾 ad-hoc 签名行改为「证书优先，缺失则优雅回退」。 |
| `README.md` | **修改** —— Permissions / Build locally 章节说明新签名行为与一次性设置；标注裸可执行局限。 |
| `README.zh.md` | **修改** —— 与英文版同步签名说明。 |
| Swift 应用代码 | **零变更** —— 签名层修复，应用行为不变。 |

## 9. 风险与缓解

- **开发者首次需一次管理员授权（`add-trusted-cert`）**：不可避免；脚本幂等，只需一次。文档明确说明。
- **Gatekeeper 仍提示「未知开发者」**：与现状一致，README FAQ 已覆盖
  （`xattr -dr com.apple.quarantine ...`）。本方案不恶化、也不消除此提示（消除需 Developer ID + 公证，
  属另一独立工作项）。
- **旧用户首次升级到此版本仍需重授权一次**：因旧记录绑定的是 ad-hoc cdhash，无法迁移。此次升级后
  即进入稳定轨道。README 明确告知。
- **证书误删/过期**：重新运行 `make_signing_cert.sh` 会生成新证书（新 DR），用户需重授权一次。
  默认有效期 10 年，覆盖多个发版周期。文档说明。
- **CI 环境**：CI 上无该证书时 `build_app.sh` 回退 ad-hoc（仍产出可用 artifact），不影响 CI 通过；
  仅开发者本机构建用于发版时才需证书。

## 10. 成功标准（验收）

1. `scripts/make_signing_cert.sh` 幂等运行，生成名为 `Plumb Local Signer` 的受信任签名身份。
2. `scripts/build_app.sh` 在证书存在时用其签名，并打印稳定身份提示；证书缺失时优雅回退 ad-hoc + 警告。
3. `scripts/verify_signing_identity.sh` 对证书构建产物返回「DR 非 cdhash」。
4. `swift test` 全绿、`swift build -c release` 成功（应用代码零回归）。
5. 手动集成验证（第 6.3 节）：新版覆盖安装后权限**仍为已授权**，无需删除/重授权。
6. README（en/zh）补充签名行为与一次性设置说明，含裸可执行局限说明。
