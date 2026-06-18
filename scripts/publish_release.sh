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
## v1.0.2

### ✨ 改进
- **设置窗口液态玻璃**：设置窗口现呈现真正的 macOS 26 Liquid Glass（折射 + 边缘 lensing 高光），而非此前的毛玻璃/灰板观感。
- 根因修复：Plumb 为菜单栏 accessory 应用，其窗口默认无法成为 key window，导致 `NSGlassEffectView` 渲染成非激活态（不透明）。现打开设置时临时切到 `.regular` 激活策略并 `makeKeyAndOrderFront`，激活玻璃折射。

### ℹ️ 说明
- 需 macOS 26+。在彩色/有图案壁纸上液态玻璃效果最明显（深色纯色壁纸上玻璃质感会偏弱，这是 Liquid Glass 的固有特性）。
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
