# Stable Signing Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Plumb a stable code-signing identity (self-signed certificate + fixed designated requirement) so that Accessibility / Screen Recording TCC permissions persist across updates, eliminating the "delete and re-grant after every update" problem.

**Architecture:** A one-time cert-generation script creates a trusted self-signed codesigning identity in the login keychain; `build_app.sh` signs every build with it (graceful ad-hoc fallback when absent); a verification script gates releases by rejecting `cdhash`-bound (ad-hoc) artifacts. No Swift code changes — the fix lives entirely in the signing/packaging layer.

**Tech Stack:** Bash, macOS `security`/`codesign`, OpenSSL (for one-time cert generation), SwiftPM (regression only).

**Spec:** `docs/superpowers/specs/2026-06-20-stable-signing-identity-design.md`

---

## File Structure

| File | Responsibility | Status |
|------|----------------|--------|
| `scripts/make_signing_cert.sh` | One-time, idempotent: generate + import + trust a self-signed codesigning cert in the login keychain. | **Create** |
| `scripts/verify_signing_identity.sh` | Release gate: fail if `dist/Plumb.app` designated requirement is `cdhash` (ad-hoc). | **Create** |
| `scripts/build_app.sh` | Modify the final signing step (line 88) to prefer the cert, fall back to ad-hoc with a warning. | **Modify** |
| `README.md` | Document signing behavior, one-time setup, and the bare-executable limitation. | **Modify** |
| `README.zh.md` | Mirror the English signing docs. | **Modify** |
| `scripts/release_build.sh` | (Optional, Task 6) Insert the verify gate before notarization so it can't ship an ad-hoc build. | **Modify** |

**Out of scope (per spec §7):** in-app re-grant UI, `sign_and_notarize.sh` changes, es/fr/ja README signing docs, keychain-dependent unit tests, migration of old ad-hoc TCC records.

---

## Task 1: Create `scripts/make_signing_cert.sh`

**Files:**
- Create: `scripts/make_signing_cert.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# One-time setup: create a trusted self-signed code-signing identity so that
# Plumb's TCC permissions (Accessibility / Screen Recording) survive updates.
#
# Idempotent: if an identity named PLUMB_SIGNING_IDENTITY already exists, exits 0.
# Requires one administrator authorization (to set the trust setting).
set -euo pipefail

CERT_NAME="${PLUMB_SIGNING_IDENTITY:-Plumb Local Signer}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# 1) Idempotent: skip if the identity already exists in any keychain on the search list.
if security find-identity -v | grep -q "\"${CERT_NAME}\""; then
  echo "签名身份已存在: \"${CERT_NAME}\"（跳过创建）"
  exit 0
fi

# 2) Generate a self-signed cert (10-year validity covers many release cycles).
echo "生成自签名证书: ${CERT_NAME}"
openssl req -x509 -newkey rsa:2048 \
  -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
  -days 3650 -nodes -subj "/CN=${CERT_NAME}" >/dev/null 2>&1

# 3) Export as p12 with legacy encryption (OpenSSL 3.x default is unreadable by
#    the macOS `security` tool — import fails with "MAC verification failed").
PW="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy \
  -in "$WORKDIR/cert.pem" -inkey "$WORKDIR/key.pem" \
  -out "$WORKDIR/signer.p12" -password pass:"$PW" >/dev/null 2>&1

# 4) Import into the user's login keychain and authorize codesign to use it.
LOGIN_KC="$(security login-keychain | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
security import "$WORKDIR/signer.p12" -k "$LOGIN_KC" -P "$PW" -T /usr/bin/codesign

# 5) Trust it as a code-signing root (requires one admin authorization).
#    Without this step the cert is CSSMERR_TP_NOT_TRUSTED and codesign reports
#    "no identities are available".
echo "将证书设为受信任的代码签名根（需要一次管理员授权）…"
sudo security add-trusted-cert -d -r trustRoot -k "$LOGIN_KC" -p codeSign "$WORKDIR/cert.pem"

echo "✅ 签名身份已就绪: \"${CERT_NAME}\""
echo "   之后每次 scripts/build_app.sh 将自动使用该身份签名，TCC 权限可跨更新保留。"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/make_signing_cert.sh`
Expected: no output; `ls -l scripts/make_signing_cert.sh` shows `-rwxr-xr-x`.

- [ ] **Step 3: Syntax-check the script (no execution / no keychain changes)**

Run: `bash -n scripts/make_signing_cert.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/make_signing_cert.sh
git commit -m "feat(signing): add one-time self-signed cert generator

Idempotent script to create a trusted code-signing identity so TCC
permissions (Accessibility / Screen Recording) survive updates."
```

---

## Task 2: Create `scripts/verify_signing_identity.sh`

**Files:**
- Create: `scripts/verify_signing_identity.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Release gate: ensure dist/Plumb.app has a stable designated requirement
# (NOT cdhash). An ad-hoc signature's DR is "cdhash ...", which makes every
# rebuild look like a brand-new app to TCC and invalidates Accessibility /
# Screen Recording grants. Fail loudly so an ad-hoc build can't ship.
set -euo pipefail

APP_DIR="${1:-dist/Plumb.app}"

if [[ ! -d "${APP_DIR}" ]]; then
  echo "❌ 未找到 app 包: ${APP_DIR}"
  exit 1
fi

DR="$(codesign -d -r- "${APP_DIR}" 2>&1)"
if echo "${DR}" | grep -q "cdhash"; then
  echo "❌ 签名为 ad-hoc（DR=cdhash），TCC 权限无法跨更新保留："
  echo "${DR}" | grep "designated"
  echo ""
  echo "修复：运行 scripts/make_signing_cert.sh 生成稳定签名身份后重新构建。"
  exit 1
fi

echo "✅ 签名为稳定身份要求（TCC 权限可跨更新保留）："
echo "${DR}" | grep "designated"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/verify_signing_identity.sh`
Expected: `-rwxr-xr-x`.

- [ ] **Step 3: Syntax-check**

Run: `bash -n scripts/verify_signing_identity.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Verify it FAILS against the current ad-hoc dist (negative test)**

Run: `scripts/verify_signing_identity.sh dist/Plumb.app || echo "EXIT=$?"`
Expected: prints `❌ 签名为 ad-hoc（DR=cdhash）...` and `EXIT=1`. This confirms the gate correctly rejects the current ad-hoc build before we change `build_app.sh`.

- [ ] **Step 5: Commit**

```bash
git add scripts/verify_signing_identity.sh
git commit -m "feat(signing): add release gate that rejects ad-hoc signatures

Ad-hoc DR is cdhash-bound, which invalidates TCC grants every rebuild.
The gate fails any build whose designated requirement is cdhash."
```

---

## Task 3: Modify `scripts/build_app.sh` to use the certificate

**Files:**
- Modify: `scripts/build_app.sh` (replace line 88 and its comment block, lines 83–88)

- [ ] **Step 1: Read current signing block to confirm exact text**

Run: `sed -n '83,90p' scripts/build_app.sh`
Expected output (confirm before editing):
```
# The release binary carries an ad-hoc linker signature that predates the bundle resources
# (icons, Info.plist). Without re-signing after resources are in place, the resource seal is
# broken and codesign --verify fails — which can surface as a "damaged" app on a clean Mac.
# Re-sign the whole bundle ad-hoc so the resource directory is properly sealed.
# (Distribution builds replace this with a Developer ID signature via sign_and_notarize.sh.)
codesign --force --deep --sign - "${APP_DIR}" >/dev/null
```

- [ ] **Step 2: Replace the ad-hoc signing block with cert-first logic**

Replace lines 83–88 (the 5-line comment + the `codesign --sign -` line) with:

```bash
# Re-sign the whole bundle so the resource directory (icons, Info.plist) is properly
# sealed — otherwise codesign --verify fails and the app reads as "damaged" on a clean Mac.
#
# Prefer a stable self-signed identity so TCC permissions (Accessibility / Screen Recording)
# survive updates. An ad-hoc signature's designated requirement is cdhash-bound, which makes
# every rebuild look like a brand-new app to TCC. Generate the identity once with
# scripts/make_signing_cert.sh. (Distribution builds replace this with a Developer ID
# signature via sign_and_notarize.sh — same stable-identity mechanism, no code change needed.)
SIGN_IDENTITY="${PLUMB_SIGNING_IDENTITY:-Plumb Local Signer}"
if security find-identity -v | grep -q "\"${SIGN_IDENTITY}\""; then
  codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_DIR}" >/dev/null
  echo "  签名身份: ${SIGN_IDENTITY}（稳定，TCC 权限可跨更新保留）"
else
  echo "  ⚠️  未找到签名身份 '${SIGN_IDENTITY}'，回退到 ad-hoc 签名。"
  echo "      → 此构建的 TCC 权限将无法跨更新保留。"
  echo "      → 运行 scripts/make_signing_cert.sh 生成稳定签名身份（一次性，需管理员授权）。"
  codesign --force --deep --sign - "${APP_DIR}" >/dev/null
fi
```

- [ ] **Step 3: Syntax-check the modified script**

Run: `bash -n scripts/build_app.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Verify the graceful-fallback path works without the cert present**

(No cert in keychain yet.) Run: `scripts/build_app.sh 2>&1 | tail -8`
Expected: prints the `⚠️ 未找到签名身份 ... 回退到 ad-hoc 签名` warning, then `[4/4] 完成: dist/Plumb.app`. Exit 0. Confirms the fallback branch is syntactically and behaviorally correct.

- [ ] **Step 5: Confirm fallback still produces an ad-hoc artifact (gate catches it)**

Run: `scripts/verify_signing_identity.sh dist/Plumb.app || echo "EXIT=$?"`
Expected: `EXIT=1` with the ad-hoc message. Confirms the two scripts interact correctly in the no-cert case.

- [ ] **Step 6: Commit**

```bash
git add scripts/build_app.sh
git commit -m "feat(signing): sign builds with stable identity, fall back to ad-hoc

build_app.sh now prefers the self-signed cert so TCC permissions
survive updates; degrades gracefully to ad-hoc with a clear warning
when the identity is absent."
```

---

## Task 4: Update `README.md` (English)

**Files:**
- Modify: `README.md` — extend the **Permissions** section and the FAQ.

- [ ] **Step 1: Read the current Permissions section + FAQ to find insertion points**

Run: `sed -n '123,145p;205,215p' README.md`
Confirm: section header `## Permissions` near line 123; the `xattr` quarantine line near 210.

- [ ] **Step 2: Add a "Why permissions survive updates" subsection under Permissions**

Insert immediately after the existing `### Permission boundary` subsection (after its bullet list, before the next `##` section):

```markdown
### Why permissions may need re-granting (and how this is fixed)

macOS keys Accessibility and Screen Recording grants on an app's **stable signing identity** (its designated requirement). Early Plumb releases were signed *ad-hoc* — a signature whose identity is just the binary's hash (`cdhash`), which changes on every rebuild. The result: each update looked like a brand-new app to macOS, so its grants were discarded.

From this release on, Plumb is signed with a **stable self-signed certificate**, so the designated requirement is bound to the certificate identity rather than to a per-build hash. Grants now persist across updates — grant once, keep across upgrades.

**One-time note for users upgrading from an ad-hoc release:** because the old grants were keyed to the old hash, you will need to re-grant Accessibility / Screen Recording **one last time** when upgrading to this version. After that, future updates preserve your grants automatically.

**Limitation — building from source with a bare executable:** the permission-stability guarantee only applies to the signed `.app` bundle produced by `scripts/build_app.sh`. A bare executable from `swift build` / `swift run` has no `.app` bundle and no stable signing identity, so its TCC grants are keyed to `cdhash` and reset on every rebuild. Use the `.app` build for day-to-day testing of permission-dependent features.
```

- [ ] **Step 3: Add a build-time setup note to the FAQ section**

Append a new FAQ entry after the existing Gatekeeper/quarantine FAQ:

```markdown
### Permissions reset every time I rebuild from source

You're running the bare executable (`swift run`) or an ad-hoc `.app`. Both have an unstable signing identity, so macOS treats each build as a new app. To get stable permissions locally:

1. Run `scripts/make_signing_cert.sh` once (it asks for your password once to trust the certificate).
2. Build the app with `scripts/build_app.sh`. It will print `签名身份: Plumb Local Signer` and your grants will now persist across rebuilds.
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(readme): explain stable signing identity and re-grant once on upgrade"
```

---

## Task 5: Update `README.zh.md` (Chinese mirror)

**Files:**
- Modify: `README.zh.md`

- [ ] **Step 1: Locate the parallel sections in the Chinese README**

Run: `grep -n "权限\|授权\|签名\|quarantine\|xattr\|## " README.zh.md`
Identify the Chinese "权限" (Permissions) section and the FAQ that mentions `xattr`.

- [ ] **Step 2: Add the Chinese "为什么权限需要重新授权（以及如何修复）" subsection**

Insert after the Chinese permission-boundary subsection (mirror of Task 4 Step 2):

```markdown
### 为什么权限可能需要重新授权（以及如何修复）

macOS 以应用的**稳定签名身份**（designated requirement）为键保存「辅助功能」与「屏幕录制」授权。早期版本的 Plumb 使用 **ad-hoc 签名**——这种签名的身份只是可执行文件的哈希（`cdhash`），每次重新编译都会变化。结果：每次更新都被 macOS 视为一个全新应用，授权记录随之失效。

从本版本起，Plumb 改用**固定的自签名证书**签名，designated requirement 绑定到证书身份而非每次构建的哈希。授权因此可跨更新保留——授权一次，升级后依然有效。

**从 ad-hoc 版本升级的用户请注意：** 由于旧授权绑定的是旧的哈希，升级到本版本时仍需**最后一次**重新授予「辅助功能 / 屏幕录制」权限。此后所有更新都将自动保留授权。

**局限——从源码编译裸可执行文件：** 权限稳定性的保证仅适用于由 `scripts/build_app.sh` 产出的、经签名的 `.app` 包。`swift build` / `swift run` 产出的裸可执行文件没有 `.app` 包、没有稳定签名身份，其 TCC 授权以 `cdhash` 为键，每次重新编译都会失效。日常测试依赖权限的功能时，请使用 `.app` 构建产物。
```

- [ ] **Step 3: Add the Chinese FAQ entry (mirror of Task 4 Step 3)**

```markdown
### 每次从源码重新编译后权限都失效

你在使用裸可执行（`swift run`）或 ad-hoc 的 `.app`。两者都没有稳定的签名身份，macOS 会把每次构建当成新应用。要在本地获得稳定权限：

1. 运行一次 `scripts/make_signing_cert.sh`（会请求一次密码以设置证书信任）。
2. 用 `scripts/build_app.sh` 构建。输出会包含 `签名身份: Plumb Local Signer`，此后授权即可跨重新构建保留。
```

- [ ] **Step 4: Commit**

```bash
git add README.zh.md
git commit -m "docs(readme-zh): mirror stable-signing-identity explanation in Chinese"
```

---

## Task 6: Wire the verify gate into `scripts/release_build.sh`

**Files:**
- Modify: `scripts/release_build.sh` (insert a gate after build_app.sh)

- [ ] **Step 1: Read the current release_build.sh**

Current content (6 numbered steps region):
```
[1/4] Build app bundle → scripts/build_app.sh
[2/4] Create installer dmg → scripts/create_dmg.sh
[3/4] Sign + notarize release artifact → scripts/sign_and_notarize.sh
[4/4] Verify notarized dmg → spctl --assess ...
```

- [ ] **Step 2: Insert the signing-identity gate as a new step between build and dmg**

Modify so the gate runs right after building the app, before the DMG is created. Update the step numbering from `[N/4]` to `[N/5]`. Final script:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "[1/5] Build app bundle"
scripts/build_app.sh

echo "[2/5] Verify stable signing identity (reject ad-hoc)"
scripts/verify_signing_identity.sh dist/Plumb.app

echo "[3/5] Create installer dmg"
scripts/create_dmg.sh

echo "[4/5] Sign + notarize release artifact"
scripts/sign_and_notarize.sh

echo "[5/5] Verify notarized dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 dist/Plumb.dmg

echo "Release artifact ready: dist/Plumb.dmg"
```

> Note: `sign_and_notarize.sh` is the Developer ID path. In this environment (no Developer ID) it will be skipped/not run — see Task 8. The verify gate at step 2 is what enforces stable identity for the self-signed path.

- [ ] **Step 3: Syntax-check**

Run: `bash -n scripts/release_build.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/release_build.sh
git commit -m "feat(release): gate release_build on stable signing identity"
```

---

## Task 7: Regression — `swift test` and `swift build -c release`

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `swift test 2>&1 | tail -30`
Expected: all tests pass; `Executed N tests, with 0 failures`. No Swift code changed, so this is a pure regression guard.

- [ ] **Step 2: Run a release build of the binary**

Run: `swift build -c release 2>&1 | tail -10`
Expected: `Build complete!` with exit 0.

- [ ] **Step 3: If any test/build fails — STOP**

Do not proceed to packaging. Investigate with the systematic-debugging skill. A failure here means something in the environment/spec assumption is wrong, not that the signing change broke app code (it touched zero Swift files).

---

## Task 8: Manual integration verification — grants persist across an update

**This is the core success criterion (spec §6.3, §10-5).** It requires a Mac desktop session with GUI access (TCC prompts are GUI). Steps marked 👤 need the human.

**Files:** none (verification only)

- [ ] **Step 1: Baseline — current ad-hoc dist already has grants lost on rebuild (sanity check the gate)**

Run: `scripts/verify_signing_identity.sh dist/Plumb.app; echo "EXIT=$?"`
Expected: `EXIT=1` (ad-hoc rejected). This is the "before" state.

- [ ] **Step 2: Generate the stable identity (one-time, 👤 admin password)**

👤 Run: `scripts/make_signing_cert.sh`
Expected: prompts for admin password once, then prints `✅ 签名身份已就绪: "Plumb Local Signer"`.

- [ ] **Step 3: Build with the cert and verify stable DR**

Run: `scripts/build_app.sh 2>&1 | tail -5`
Expected: prints `签名身份: Plumb Local Signer（稳定，TCC 权限可跨更新保留）`.

Run: `scripts/verify_signing_identity.sh dist/Plumb.app; echo "EXIT=$?"`
Expected: prints the `✅ 签名为稳定身份要求` line with a `designated => identifier ... and certificate leaf ...` (NOT cdhash), `EXIT=0`.

- [ ] **Step 4: Install this cert-signed build and grant permissions (👤)**

👤 Copy `dist/Plumb.app` to `/Applications/`, launch it, open Settings → Permissions, grant Accessibility and Screen Recording when prompted. Confirm both show "已授权".

- [ ] **Step 5: Rebuild (simulating an update) WITHOUT touching the certificate**

Run: `scripts/build_app.sh`
👤 Replace `/Applications/Plumb.app` with the fresh `dist/Plumb.app`, relaunch.

- [ ] **Step 6: Verify grants persisted (the decisive check)**

👤 Open Settings → Permissions.
Expected: both Accessibility and Screen Recording still show "已授权" — **no re-grant needed**. This is the fix working end-to-end.

If grants were reset: STOP, use systematic-debugging. Likely causes: the cert's designated requirement changed (re-ran make_signing_cert and got a new cert), or the bundleID changed.

- [ ] **Step 7: Record the result**

Note in the commit message / release notes: "Verified: TCC grants persist across update with stable signing identity."

---

## Task 9: Package the release DMG

**Files:** none (produces `dist/Plumb.dmg`)

- [ ] **Step 1: Build + package (skip Developer ID notarization — no cert in this env)**

Run: `scripts/build_app.sh && scripts/verify_signing_identity.sh dist/Plumb.app && scripts/create_dmg.sh`
Expected: `dist/Plumb.app` stable-signed (verify gate passes), then `dist/Plumb.dmg` created.

> Do NOT run `scripts/release_build.sh` as-is here: its step 4 (`sign_and_notarize.sh`) requires a Developer ID which this environment does not have. The verify gate's job is done by calling `verify_signing_identity.sh` explicitly in the chain above. (The release_build.sh wiring in Task 6 is for when a Developer ID is present; it's correct but not runnable in this env.)

- [ ] **Step 2: Confirm the DMG contains the stable-signed app**

Run: `hdiutil attach dist/Plumb.dmg -nobrowse -mountpoint /tmp/plumbmnt >/dev/null 2>&1 && codesign -d -r- /tmp/plumbmnt/Plumb.app 2>&1 | grep designated; hdiutil detach /tmp/plumbmnt >/dev/null`
Expected: the `designated` line is NOT cdhash (it's a certificate-based requirement).

- [ ] **Step 3: If anything is cdhash — STOP and re-check the cert was used**

---

## Task 10: Update release notes in `publish_release.sh` and publish

**Files:**
- Modify: `scripts/publish_release.sh` (update the embedded release body)

- [ ] **Step 1: Determine the new version tag**

Run: `git describe --tags --abbrev=0 2>/dev/null` to find the latest tag. Plan the next tag, e.g. `v1.0.5` (one patch bump above the latest — confirm against the actual output). Record the chosen tag as `NEWTAG` for use in the following steps.

- [ ] **Step 2: Update the `BODY` heredoc in publish_release.sh (lines 51–62)**

Replace the `## v1.0.4 ... EOF` body with a new release-notes body for `NEWTAG` (substitute the real version number for the `X.Y.Z` placeholders):

```
## vX.Y.Z

### ✨ New
- **Permissions now survive updates**: Plumb is signed with a stable identity, so your Accessibility / Screen Recording grants persist across version upgrades — no more "delete and re-grant" after each update. (If upgrading from an older ad-hoc release, you'll re-grant **once**; after that, grants are preserved automatically.)

### ℹ️ Notes
- Requires macOS 26+.
- This release's DMG is self-signed (not Developer-ID-notarized); if Gatekeeper blocks it on first open as "damaged", run `xattr -dr com.apple.quarantine /Applications/Plumb.app` (see README FAQ).
```

- [ ] **Step 3: Commit the release-notes update**

```bash
git add scripts/publish_release.sh
git commit -m "chore(release): vX.Y.Z release notes (stable signing identity)"
```

- [ ] **Step 4: Push all commits**

```bash
git push origin main
```
Expected: pushes the script + README + release_build + release-notes commits.

- [ ] **Step 5: Tag the release**

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

- [ ] **Step 6: Publish the GitHub Release**

👤 Ensure `GITHUB_TOKEN` is set in the environment, then:
Run: `GITHUB_TOKEN=... scripts/publish_release.sh vX.Y.Z`
Expected: `[1/3]`, `[2/3]`, `[3/3]`, then `Release published: vX.Y.Z (asset: Plumb.dmg)`.

- [ ] **Step 7: Verify the release exists with the asset**

Run: `gh release view vX.Y.Z --repo Lv-0/plumb` (or `curl` the API)
Expected: release titled `vX.Y.Z` with `Plumb.dmg` attached.

---

## Done Criteria (spec §10)

- [ ] `scripts/make_signing_cert.sh` exists, is executable, idempotent, `bash -n` clean.
- [ ] `scripts/verify_signing_identity.sh` exists, is executable, fails on ad-hoc, passes on cert-signed.
- [ ] `scripts/build_app.sh` signs with the cert when present, falls back to ad-hoc with warning otherwise.
- [ ] `release_build.sh` gates on stable identity.
- [ ] `README.md` + `README.zh.md` document the behavior, one-time setup, and bare-executable limitation.
- [ ] `swift test` green; `swift build -c release` succeeds.
- [ ] Manual integration check: grants persist across a simulated update.
- [ ] `dist/Plumb.dmg` ships the stable-signed app; release published on GitHub.
