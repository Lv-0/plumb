#!/usr/bin/env bash
set -euo pipefail

# Publish a GitHub Release and upload dist/Plumb.dmg.
#
# Usage:
#   GITHUB_TOKEN=... scripts/publish_release.sh v0.1.4
#
# Notes:
# - Does not embed tokens anywhere; relies on $GITHUB_TOKEN from the environment.
# - Release notes intentionally exclude installation steps (per project requirement).

TAG="${1:-}"
if [[ -z "${TAG}" ]]; then
  echo "Usage: GITHUB_TOKEN=... $0 <tag>  (e.g. v0.1.4)"
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "Missing env var: GITHUB_TOKEN"
  exit 1
fi

REPO="${GITHUB_REPOSITORY:-Lv-0/plumb}"
ASSET_PATH="dist/Plumb.dmg"
ASSET_NAME="$(basename "${ASSET_PATH}")"

if [[ ! -f "${ASSET_PATH}" ]]; then
  echo "Missing asset: ${ASSET_PATH}"
  exit 1
fi

api() {
  curl -sS \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

json_escape() {
  # Reads the body from stdin and prints a JSON-escaped string.
  # NOTE: the python script must be passed as a -c argument (not a heredoc),
  # because a `<<'PY'` heredoc consumes python's stdin, leaving nothing for
  # sys.stdin.read() to read — which silently produced an empty body.
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

RELEASE_NAME="${TAG#v}"

BODY=$(
  cat <<'EOF' | json_escape
## v1.0.0 — 首个正式版本

全新品牌 **Plumb**（取自铅锤线 plumb line——找到真正的中心），全新视觉，全新设置界面。

### 🎨 全新设计与品牌
- 更名为 **Plumb**，全新水滴 Logo（灵感：三体"水滴"的极致圆润 + 2026 Apple Design Award 极简诗意风）。
- **Liquid Glass 设置界面**（macOS 26）：毛玻璃质感、应用搜索、药丸开关、平滑重排。
- 全新菜单栏图标。

### ✨ 新功能
- **指定 App 自动平铺**（白名单）：可配置统一四边边距，白名单 App 触发时优先平铺。
- **设置窗口实时刷新应用列表**：新安装的应用立即出现在选择器中（无需重启 App）。
- 居中段支持白名单：可仅对选定 App 自动居中。

### 🐛 修复
- 多显示器：窗口居中停留在当前所在屏幕，不再从 2 号屏跳到 1 号屏。
- 次级窗口（对话框/面板）排除在自动居中外，仅标准主窗口被居中。
- 窗口部分在屏外时：先移回可见区，再居中。
- 自动居中在 App 激活/新窗口时可靠触发（无需来回切换）。

### ℹ️ 注意
- Bundle ID 变更为 `com.comet.plumb`（macOS 视为新应用；旧测试者的设置不会迁移）。
- macOS 13+ 运行；Liquid Glass 界面需 macOS 26。
EOF
)

payload=$(
  cat <<EOF
{
  "tag_name": "${TAG}",
  "name": "${RELEASE_NAME}",
  "body": ${BODY},
  "draft": false,
  "prerelease": false
}
EOF
)

echo "[1/3] Create release ${TAG} on ${REPO}"
create_resp="$(api -X POST "https://api.github.com/repos/${REPO}/releases" -d "${payload}" || true)"

release_id="$(echo "${create_resp}" | jq -r '.id // empty')"
upload_url="$(echo "${create_resp}" | jq -r '.upload_url // empty' | sed 's/{?name,label}//')"

if [[ -z "${release_id}" || -z "${upload_url}" ]]; then
  echo "Release may already exist, fetching by tag..."
  get_resp="$(api "https://api.github.com/repos/${REPO}/releases/tags/${TAG}")"
  release_id="$(echo "${get_resp}" | jq -r '.id')"
  upload_url="$(echo "${get_resp}" | jq -r '.upload_url' | sed 's/{?name,label}//')"
fi

if [[ -z "${release_id}" || -z "${upload_url}" ]]; then
  echo "Failed to create or fetch release for tag: ${TAG}"
  exit 1
fi

echo "[2/3] Ensure no duplicate asset: ${ASSET_NAME}"
assets="$(api "https://api.github.com/repos/${REPO}/releases/${release_id}/assets")"
existing_id="$(echo "${assets}" | jq -r ".[] | select(.name==\"${ASSET_NAME}\") | .id" | head -n 1)"
if [[ -n "${existing_id}" ]]; then
  api -X DELETE "https://api.github.com/repos/${REPO}/releases/assets/${existing_id}" >/dev/null
fi

echo "[3/3] Upload asset: ${ASSET_NAME}"
curl -sS \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"${ASSET_PATH}" \
  "${upload_url}?name=${ASSET_NAME}" \
  >/dev/null

echo "Release published: ${TAG} (asset: ${ASSET_NAME})"
