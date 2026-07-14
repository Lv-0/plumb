#!/usr/bin/env bash
# scripts/release.sh — Plumb 一键发版
#
# 用法：
#   ./scripts/release.sh <版本号>              # 本地签名（默认）
#   ./scripts/release.sh <版本号> --sign developer-id   # Developer ID + 公证
#   ./scripts/release.sh <版本号> --notes-file <path>   # 预写好的 5 语言 appcast notes
#   ./scripts/release.sh <版本号> --skip-bump           # 不 bump README badge（已手动 bump 过）
#   ./scripts/release.sh --help
#
# 详见 RELEASING.md。脚本做的事见 print_plan()。
#
# 安全：本脚本从仓库外的凭据文件读 GitHub token（见 LOCAL_SECRETS.md），
#       不接受 token 命令行参数（避免进 ps/shell history）。

set -euo pipefail

# ───────────────────────── 配置 ─────────────────────────
readonly APP_NAME="Plumb"
readonly DIST_DIR="dist"
readonly APP_DIR="${DIST_DIR}/${APP_NAME}.app"
readonly DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
readonly REPO="Lv-0/plumb"
readonly README_FILES=(README.md README.es.md README.fr.md README.ja.md README.zh.md)
readonly DEFAULT_SIGN_IDENTITY="Plumb Local Signer"
# 凭据文件路径（仓库外，被 .gitignore 忽略）。可通过环境变量覆盖。
readonly SECRETS_FILE="${PLUMB_SECRETS_FILE:-/Users/space/IdeaProjects/comv/setting.txt}"

# ───────────────────────── 参数解析 ─────────────────────────
VERSION=""
SIGN_MODE="local"          # local | developer-id
NOTES_FILE=""              # 预写好的 appcast notes 文件；空则交互编辑
SKIP_BUMP="no"

usage() {
  cat <<'EOF'
用法: scripts/release.sh <版本号> [选项]

选项:
  --sign developer-id      Developer ID 签名 + 公证（默认: 本地签名 Plumb Local Signer）
  --notes-file <path>      预写好的 5 语言 appcast notes 文件（格式见 --print-notes-template）
  --skip-bump              跳过 README badge bump（已手动 bump 时用）
  --print-notes-template   打印 appcast notes 模板到 stdout 后退出
  --help, -h               显示本帮助

示例:
  scripts/release.sh 2.0.48
  scripts/release.sh 2.0.48 --notes-file /tmp/notes-v2.0.48.txt
  scripts/release.sh 2.0.48 --sign developer-id

环境变量:
  PLUMB_SECRETS_FILE       凭据文件路径（默认: /Users/space/IdeaProjects/comv/setting.txt）
  EDITOR                   交互编辑 notes 时用的编辑器
EOF
}

print_notes_template() {
  cat <<'EOF'
# appcast notes for vVERSION — 删掉本行和所有 `# ` 注释行，保留 5 个 `xx: ` 行。
# 这是 OTA 更新对话框里给用户看的简短摘要（2-4 句单段），不是完整 changelog。
# 风格参考: git show e220550 -- appcast.json
en: 
zh: 
es: 
fr: 
ja: 
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --print-notes-template) print_notes_template; exit 0 ;;
    --sign)
      [[ $# -ge 2 ]] || { echo "--sign 需要参数 (local|developer-id)"; exit 2; }
      SIGN_MODE="$2"; shift 2 ;;
    --notes-file)
      [[ $# -ge 2 ]] || { echo "--notes-file 需要路径参数"; exit 2; }
      NOTES_FILE="$2"; shift 2 ;;
    --skip-bump) SKIP_BUMP="yes"; shift ;;
    -*) echo "未知选项: $1"; usage; exit 2 ;;
    *)
      if [[ -z "$VERSION" ]]; then VERSION="$1"
      else echo "多余的位置参数: $1"; exit 2; fi
      shift ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "错误: 缺少版本号参数"
  echo "最新已发布版本: $(git tag --sort=-v:refname | head -1)"
  usage
  exit 1
fi

# 校验版本号格式
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "错误: 版本号格式应为 X.Y.Z，收到: $VERSION"
  exit 1
fi

TAG="v${VERSION}"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.zip"

# ───────────────────────── 辅助函数 ─────────────────────────
c_red()    { printf '\033[31m%s\033[0m' "$*"; }
c_green()  { printf '\033[32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m' "$*"; }

step() { echo; echo "$(c_bold "▶ [$1]") $2"; }
ok()   { echo "  $(c_green '✓') $1"; }
warn() { echo "  $(c_yellow '⚠') $1"; }
die()  { echo "$(c_red '✗ 错误:') $1" >&2; exit 1; }

confirm() {
  local prompt="$1"
  read -r -p "$(c_bold "?") ${prompt} [y/N] " ans
  [[ "${ans:-}" =~ ^[Yy]$ ]]
}

# 从凭据文件提取 GitHub token（不落中间文件、不进 history）。
# 格式约定: 文件内一行 "github token: <token>"。
load_github_token() {
  [[ -f "$SECRETS_FILE" ]] || die "凭据文件不存在: $SECRETS_FILE（见 LOCAL_SECRETS.md）"
  local tok
  tok=$(grep '^github token:' "$SECRETS_FILE" | head -1 | sed 's/^github token:[[:space:]]*//' | tr -d '[:space:]')
  [[ -n "$tok" ]] || die "凭据文件中未找到 'github token:' 行: $SECRETS_FILE"
  GITHUB_TOKEN="$tok"
}

# ───────────────────────── 计划展示 ─────────────────────────
print_plan() {
  local sign_desc notes_desc
  if [[ "$SIGN_MODE" == "developer-id" ]]; then
    sign_desc="${SIGN_MODE} (needs DEVELOPER_ID_APP + NOTARY_PROFILE)"
  else
    sign_desc="${SIGN_MODE} (Plumb Local Signer)"
  fi
  if [[ -n "$NOTES_FILE" ]]; then
    notes_desc="${NOTES_FILE} (prewritten)"
  else
    notes_desc="interactive (\$EDITOR)"
  fi

  cat <<EOF
$(c_bold "Plumb release plan: ${TAG}")

  version:     ${VERSION}
  sign mode:   ${sign_desc}
  skip-bump:   ${SKIP_BUMP}
  notes:       ${notes_desc}

steps:
  1. preflight: clean tree / on main / version strictly > latest tag /
     Testing failure canary / swift test / swift build -c release / secret scan / signing identity
  2. $([[ "$SKIP_BUMP" == "yes" ]] && echo "skip README bump" || echo "bump 5 README badges -> commit 'release: ${TAG}'")
  3. build signed .app + DMG + OTA zip
  4. verify codesign (DR must be cert leaf hash, NOT cdhash)
  5. tag ${TAG} + push commits & tag to origin
  6. create GitHub Release + upload dmg/zip (token from ${SECRETS_FILE})
  7. update appcast.json (version/url/sha + 5-lang notes) -> 2 chore commits + push

EOF
  if [[ "$SIGN_MODE" == "developer-id" ]]; then
    warn "Developer ID mode: needs DEVELOPER_ID_APP + NOTARY_PROFILE; notarization takes minutes"
  fi
}

# ───────────────────────── 预检 ─────────────────────────
preflight() {
  step "1/7" "预检"

  # 1.1 工作树: 允许有未 commit 的改动，但必须先 commit 或 stash（避免把无关改动打进 tag）
  if [[ -n "$(git status --porcelain)" ]]; then
    die "工作树不干净。请先 commit 或 stash 所有改动:\n$(git status --short)"
  fi
  ok "工作树干净"

  # 1.2 当前分支 = main
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD)
  [[ "$branch" == "main" ]] || die "当前分支 ${branch}，发版应在 main 上"
  ok "在 main 分支"

  # 1.3 本地不领先未推送的无关 commit（避免把意外 commit 打进 tag）
  #     注: 允许领先，但会显示出来让用户在 confirm 时看到
  local ahead
  ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "?")
  if [[ "$ahead" != "0" && "$ahead" != "?" ]]; then
    warn "本地领先 origin/main ${ahead} 个 commit，它们会被一并推送:"
    git log --oneline origin/main..HEAD | sed 's/^/      /'
  fi

  # 1.4 版本号严格大于最新 tag
  local latest
  latest=$(git tag --sort=-v:refname | head -1)
  # 用 sort -V 比较（macOS 自带 BSD sort 支持 -V）
  if [[ "$latest" != "" ]] && printf '%s\n%s\n' "$latest" "v$VERSION" | sort -V -C; then
    if [[ "v$VERSION" == "$latest" ]]; then
      die "版本号 ${VERSION} 等于已发布的 tag ${latest}（版本号只升不降且不能重复）"
    fi
  fi
  # 严格大于: vVERSION 必须排在 latest 之后
  if [[ "$latest" != "" ]]; then
    if ! printf '%s\n%s\n' "$latest" "v$VERSION" | sort -V -u | tail -1 | grep -qx "v$VERSION"; then
      die "版本号 ${VERSION} 不大于最新已发布版本 ${latest}（版本号只升不降）"
    fi
  fi
  ok "版本号 ${VERSION} > 最新 tag ${latest:-(无)}"

  # 1.5 tag 不已存在
  if git rev-parse "$TAG" >/dev/null 2>&1; then
    die "tag ${TAG} 已存在"
  fi
  ok "tag ${TAG} 不存在"

  # 1.6 测试框架失败门禁：这个过滤测试在环境变量开启时必须失败。若它错误返回 0，
  # 正常测试的绿色结果不可信，发版必须停止。
  step "1/7" "验证 Testing 失败门禁"
  local canary_log canary_rc
  canary_log=$(mktemp "${TMPDIR:-/tmp}/plumb-testing-canary.XXXXXX")
  set +e
  PLUMB_TEST_FAILURE_CANARY=1 swift test --filter testingFrameworkFailureCanary >"$canary_log" 2>&1
  canary_rc=$?
  set -e
  if [[ $canary_rc -eq 0 ]]; then
    rm -f "$canary_log"
    die "Testing 失败门禁未拦截故意失败断言"
  fi
  if ! grep -Fq 'testingFrameworkFailureCanary()' "$canary_log" ||
     ! grep -Fq 'Expectation failed: true == false' "$canary_log" ||
     ! grep -Fq '1 issue' "$canary_log"; then
    cat "$canary_log" >&2
    rm -f "$canary_log"
    die "Testing 失败门禁因编译/链接/runner 异常失败，未命中预期断言"
  fi
  rm -f "$canary_log"
  ok "Testing 失败门禁有效"

  # 1.7 测试
  step "1/7" "运行测试 (swift test)"
  if ! swift test 2>&1 | tail -3; then
    die "测试失败"
  fi
  ok "测试通过"

  # 1.8 release 构建
  step "1/7" "release 构建 (swift build -c release)"
  if ! swift build -c release 2>&1 | tail -3; then
    die "release 构建失败"
  fi
  ok "release 构建通过"

  # 1.9 密钥扫描: 待推送的 commit 不应含密钥模式
  step "1/7" "密钥安全扫描"
  local diff_to_scan
  diff_to_scan=$(git diff origin/main..HEAD 2>/dev/null || true)
  if echo "$diff_to_scan" | grep -qiE 'ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_|setting\.txt|LOCAL_SECRETS|Jxp'; then
    die "待推送 diff 中检测到密钥模式。STOP — 见 LOCAL_SECRETS.md 安全建议"
  fi
  ok "待推送 diff 无密钥泄露"

  # 1.10 签名身份
  step "1/7" "检查签名身份"
  if [[ "$SIGN_MODE" == "local" ]]; then
    if ! security find-identity -v 2>/dev/null | grep -q "\"${DEFAULT_SIGN_IDENTITY}\""; then
      die "未找到签名身份 '${DEFAULT_SIGN_IDENTITY}'。运行 scripts/make_signing_cert.sh 生成（一次性）"
    fi
    ok "签名身份 ${DEFAULT_SIGN_IDENTITY} 就绪"
  else
    : "${DEVELOPER_ID_APP:?Developer ID 模式需要 DEVELOPER_ID_APP 环境变量}"
    : "${NOTARY_PROFILE:?Developer ID 模式需要 NOTARY_PROFILE 环境变量}"
    ok "Developer ID + 公证 profile 就绪"
  fi
}

# ───────────────────────── bump README ─────────────────────────
bump_readme() {
  [[ "$SKIP_BUMP" == "yes" ]] && { warn "跳过 README bump（--skip-bump）"; return; }

  step "2/7" "bump README badge → release: ${TAG}"

  # 从最新 tag 读旧版本号（badge 里现有的）
  local latest_tag latest_ver
  latest_tag=$(git tag --sort=-v:refname | head -1)
  latest_ver="${latest_tag#v}"

  local changed=0 f
  for f in "${README_FILES[@]}"; do
    [[ -f "$f" ]] || { warn "README 文件缺失，跳过: $f"; continue; }
    # 精确替换 badge URL 里的版本号: release-vOLD-success → release-vNEW-success
    if grep -q "release-v${latest_ver}-success" "$f"; then
      # 用 | 做分隔避免 URL 里的 / 冲突
      sed -i '' "s|release-v${latest_ver}-success|release-v${VERSION}-success|g" "$f"
      changed=$((changed + 1))
    else
      warn "$f 中未找到 release-v${latest_ver}-success，跳过（可能已 bump 或格式变了）"
    fi
  done

  if [[ $changed -eq 0 ]]; then
    die "没有 README 被 bump。检查 badge 格式或加 --skip-bump"
  fi
  ok "bumped ${changed} 个 README"

  git add "${README_FILES[@]}"
  git commit -q -m "release: ${TAG}

Bump release badge (${changed} READMEs) to ${VERSION}.

See RELEASING.md for the release process."
  ok "commit: release: ${TAG}"
}

# ───────────────────────── 构建 ─────────────────────────
build_artifacts() {
  step "3/7" "构建签名 .app + DMG + OTA zip"

  VERSION="$VERSION" scripts/build_app.sh >/dev/null
  ok "build_app.sh → ${APP_DIR}"

  scripts/create_dmg.sh >/dev/null
  ok "create_dmg.sh → ${DMG_PATH}"

  VERSION="$VERSION" scripts/create_zip.sh >/dev/null
  ok "create_zip.sh → ${ZIP_PATH}"
}

# ───────────────────────── 签名校验 ─────────────────────────
verify_signature() {
  step "4/7" "校验签名"

  codesign --verify --deep --strict --verbose=1 "${APP_DIR}" 2>&1 | sed 's/^/      /' || die "codesign --verify 失败"
  ok "codesign --verify 通过"

  # DR 必须是证书 leaf hash（H"..."), 不能是 cdhash —— 否则 TCC 权限每次更新都重置。
  local dr
  dr=$(codesign -d -r- "${APP_DIR}" 2>&1 | grep '^designated' || true)
  if echo "$dr" | grep -q "certificate leaf"; then
    ok "DR = 证书 leaf hash（TCC 权限可跨更新保留）"
  elif echo "$dr" | grep -q "cdhash"; then
    die "DR = cdhash（ad-hoc 签名）！TCC 权限将无法跨更新保留。请确认 Plumb Local Signer 身份存在并重新 build。"
  else
    warn "无法识别 DR 形式: ${dr:-(空)}"
  fi

  # 版本号嵌入校验
  local embedded
  embedded=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_DIR}/Contents/Info.plist" 2>/dev/null || echo "")
  [[ "$embedded" == "$VERSION" ]] || die ".app 内嵌版本号 ${embedded} != ${VERSION}"
  ok ".app 版本号 = ${VERSION}"

  # zip 完整性
  unzip -t "${ZIP_PATH}" >/dev/null || die "zip 完整性校验失败"
  ok "zip 完整性 OK (sha256: $(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}'))"
}

# ───────────────────────── tag + push ─────────────────────────
tag_and_push() {
  step "5/7" "打 tag ${TAG} + push"
  git tag -a "$TAG" -m "${TAG}"
  ok "tag ${TAG} 创建"

  git push origin main
  ok "push commits → origin/main"

  git push origin "$TAG"
  ok "push tag ${TAG}"
}

# ───────────────────────── GitHub Release ─────────────────────────
publish_github_release() {
  step "6/7" "创建 GitHub Release + 上传 assets"
  load_github_token
  export GITHUB_TOKEN VERSION

  # release notes（GitHub Release body）: 用预写文件，否则从最近 commit log 生成一个简版
  local notes_body_file
  notes_body_file=$(mktemp)
  # RETURN trap fires after the function exits, at which point the local is
  # already out of scope — guard with :- so set -u doesn't fatal on cleanup.
  trap 'rm -f "${notes_body_file:-}"' RETURN
  local md="dist/release-notes-${TAG}.md"
  if [[ -f "$md" ]]; then
    cp "$md" "$notes_body_file"
    ok "Release body 来自 ${md}"
  else
    warn "未找到 ${md}，从 commit log 生成简版 Release body"
    {
      echo "## What's new"
      echo ""
      git log --oneline "$(git tag --sort=-v:refname | head -1)"..HEAD 2>/dev/null \
        | head -20 | sed 's/^/* /'
    } > "$notes_body_file"
  fi

  RELEASE_NOTES_FILE="$notes_body_file" bash scripts/publish_release.sh "$TAG" >/dev/null
  ok "publish_release.sh → Release ${TAG} 已发布 (assets: Plumb.dmg, Plumb-${VERSION}.zip)"
  ok "publish_release.sh 已更新 appcast.json 的 version/url/sha256（未含 notes）"
}

# ───────────────────────── appcast notes ─────────────────────────
collect_appcast_notes() {
  # 返回（echo 到 stdout）一个临时文件路径，内容是解析后的 JSON 片段（5 个 "lang": "..." 键值对）。
  # 调用方负责 rm。
  # ⚠️ 本函数 stdout 只能输出路径本身 —— 所有诊断/进度必须走 stderr，否则会被
  #    parsed=$(collect_appcast_notes) 捕获进路径变量。
  local parsed
  parsed=$(mktemp)

  if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || die "notes 文件不存在: $NOTES_FILE"
    ok "使用预写 notes 文件: $NOTES_FILE" >&2
  else
    NOTES_FILE=$(mktemp -t plumb_notes)
    # 模板里 VERSION 占位替换
    print_notes_template | sed "s/VERSION/${VERSION}/g" > "$NOTES_FILE"
    local editor="${EDITOR:-vi}"
    {
      echo
      echo "$(c_bold "?") 用 ${editor} 编辑 appcast notes（5 语言 OTA 摘要）。"
      echo "    保存退出继续；格式: 5 行 'xx: <摘要>'，删掉 '# ' 注释行。"
      echo "    风格参考: git show e220550 -- appcast.json"
      echo
    } >&2
    read -r -p "$(c_bold "?") 打开编辑器? [Y/n] " ans
    if [[ ! "${ans:-Y}" =~ ^[Nn]$ ]]; then
      "$editor" "$NOTES_FILE" || die "编辑器退出非零"
    fi
  fi

  # 解析: 提取每行 "xx: value"（xx ∈ en/zh/es/fr/ja），输出 JSON 键值对。
  # 容忍前导 # 注释行和空行。
  python3 - "$NOTES_FILE" "$parsed" <<'PY' || { rm -f "$NOTES_FILE" "$parsed"; die "notes 解析失败"; }
import json, re, sys
src, out = sys.argv[1], sys.argv[2]
langs = ["en", "zh", "es", "fr", "ja"]
notes = {}
with open(src, encoding="utf-8") as f:
    for line in f:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = re.match(r"^(en|zh|es|fr|ja)\s*:\s*(.*)$", s)
        if m and m.group(2).strip():
            notes[m.group(1)] = m.group(2).strip()
missing = [l for l in langs if l not in notes]
if missing:
    sys.stderr.write(f"错误: notes 缺少语言: {', '.join(missing)}\n")
    sys.exit(1)
with open(out, "w", encoding="utf-8") as f:
    for i, l in enumerate(langs):
        comma = "," if i < len(langs) - 1 else ""
        f.write(f'    {json.dumps(l)}: {json.dumps(notes[l])}{comma}\n')
sys.stderr.write(f"  ✓ 解析到 {len(notes)} 语言 notes\n")
PY

  # 交互模式下清理我们 mktemp 的 NOTES_FILE；预写的 --notes-file 不删。
  echo "$parsed"
}

update_appcast_notes() {
  step "7/7" "更新 appcast notes（5 语言）"

  local parsed
  parsed=$(collect_appcast_notes)

  # 读当前 appcast.json，替换 notes 块（从 '  "notes": {' 到 '  },' 之间），
  # 再用 python 重排保证格式 + 校验 JSON 合法。
  python3 - "$parsed" <<'PY' || { rm -f "$parsed"; die "appcast notes 写入失败"; }
import json, pathlib, sys
parsed = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
# parsed 是 5 行 "    "lang": "value",?  — 重建 notes dict
import re
notes = {}
for m in re.finditer(r'"(en|zh|es|fr|ja)":\s*("(?:[^"\\]|\\.)*")', parsed):
    notes[m.group(1)] = json.loads(m.group(2))

p = pathlib.Path("appcast.json")
m = json.loads(p.read_text(encoding="utf-8"))
m["notes"] = notes
p.write_text(json.dumps(m, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print("appcast.json notes 已更新")
PY
  rm -f "$parsed"

  # 校验 JSON
  python3 -c "import json; json.load(open('appcast.json'))" || die "appcast.json 不是合法 JSON"
  ok "appcast.json JSON 合法"

  git add appcast.json
  git commit -q -m "chore(release): refresh appcast notes for ${TAG}"
  git push origin main
  ok "commit + push: chore(release): refresh appcast notes for ${TAG}"
}

# ───────────────────────── 主流程 ─────────────────────────
main() {
  print_plan
  echo
  confirm "确认按此计划发版 ${TAG}?" || { echo "已取消"; exit 0; }

  preflight
  bump_readme
  build_artifacts
  verify_signature
  tag_and_push
  publish_github_release
  update_appcast_notes

  echo
  echo "$(c_green "$(c_bold "✓ 发版完成: ${TAG}")")"
  echo "  Release:    https://github.com/${REPO}/releases/tag/${TAG}"
  echo "  OTA 索引:   appcast.json → ${VERSION}（5 语言 notes 已更新）"
  echo "  本地产物:   ${DMG_PATH}, ${ZIP_PATH}"
  echo
  echo "  $(c_yellow '发版后建议:') 在真实 mac 上拉取 appcast.json 验证 OTA 流程"
}

main "$@"
