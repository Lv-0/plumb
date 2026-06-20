#!/usr/bin/env bash
set -euo pipefail

# Publish a GitHub Release and upload dist/Plumb.dmg + dist/Plumb-{VERSION}.zip,
# then commit appcast.json so in-app OTA sees the new version.
#
# Usage:
#   GITHUB_TOKEN=... VERSION=1.0.7 scripts/publish_release.sh v1.0.7
#
# Notes:
# - Does not embed tokens anywhere; relies on $GITHUB_TOKEN from the environment.
# - VERSION must match the tag's numeric version (used for the zip asset name).

TAG="${1:-}"
if [[ -z "${TAG}" ]]; then
  echo "Usage: GITHUB_TOKEN=... VERSION=1.0.7 $0 <tag>  (e.g. v1.0.7)"
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "Missing env var: GITHUB_TOKEN"
  exit 1
fi

VERSION="${VERSION:-${TAG#v}}"   # strip leading 'v' from tag as a fallback
REPO="${GITHUB_REPOSITORY:-Lv-0/plumb}"
DMG_PATH="dist/Plumb.dmg"
ZIP_PATH="dist/Plumb-${VERSION}.zip"

if [[ ! -f "${DMG_PATH}" ]]; then
  echo "Missing asset: ${DMG_PATH}"
  exit 1
fi
if [[ ! -f "${ZIP_PATH}" ]]; then
  echo "Missing asset: ${ZIP_PATH} (run scripts/create_zip.sh first)"
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

# Upload (or replace) one asset by name. Usage: upload_asset <release_id> <assets_json> <path> <name>
upload_asset() {
  local release_id="$1"
  local assets="$2"
  local path="$3"
  local name="$4"

  local existing_id
  existing_id="$(echo "${assets}" | jq -r ".[] | select(.name==\"${name}\") | .id" | head -n 1)"
  if [[ -n "${existing_id}" ]]; then
    api -X DELETE "https://api.github.com/repos/${REPO}/releases/assets/${existing_id}" >/dev/null
  fi

  local upload_url
  upload_url="$(api "https://api.github.com/repos/${REPO}/releases/${release_id}" | jq -r '.upload_url' | sed 's/{?name,label}//')"
  echo "  uploading ${name}..."
  curl -sS \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"${path}" \
    "${upload_url}?name=${name}" \
    >/dev/null
}

RELEASE_NAME="${TAG#v}"

BODY=$(
  cat <<'EOF' | json_escape
## v1.0.7

### ✨ Added
- **About tab in Settings**: the settings window now has a 4th tab ("About") showing the current app version number and a button that opens the GitHub repository page (https://github.com/Lv-0/plumb) in your default browser.

### ℹ️ Notes
- Requires macOS 26+.
- Self-signed (not Developer-ID-notarized); if Gatekeeper blocks first open as "damaged", run `xattr -dr com.apple.quarantine /Applications/Plumb.app` (see README FAQ).
- Accessibility / Screen Recording grants still need re-giving after each update (ad-hoc signing); stable signing is groundwork pending a Developer-ID build.
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

echo "[1/5] Create release ${TAG} on ${REPO}"
create_resp="$(api -X POST "https://api.github.com/repos/${REPO}/releases" -d "${payload}" || true)"

release_id="$(echo "${create_resp}" | jq -r '.id // empty')"

if [[ -z "${release_id}" ]]; then
  echo "Release may already exist, fetching by tag..."
  get_resp="$(api "https://api.github.com/repos/${REPO}/releases/tags/${TAG}")"
  release_id="$(echo "${get_resp}" | jq -r '.id')"
fi

if [[ -z "${release_id}" ]]; then
  echo "Failed to create or fetch release for tag: ${TAG}"
  exit 1
fi

echo "[2/5] Refresh release assets list"
assets="$(api "https://api.github.com/repos/${REPO}/releases/${release_id}/assets")"

echo "[3/5] Upload DMG asset"
upload_asset "${release_id}" "${assets}" "${DMG_PATH}" "$(basename "${DMG_PATH}")"

echo "[4/5] Upload ZIP asset (for OTA)"
upload_asset "${release_id}" "${assets}" "${ZIP_PATH}" "$(basename "${ZIP_PATH}")"

echo "[5/5] Publish appcast.json to main (so OTA picks up the new version)"
# Update appcast version/url to match this release, then commit + push.
export OTA_VERSION="${VERSION}" \
       OTA_URL="https://github.com/${REPO}/releases/download/${TAG}/$(basename "${ZIP_PATH}")" \
       OTA_SHA="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
python3 - <<'PY'
import json, os, pathlib
p = pathlib.Path("appcast.json")
m = json.loads(p.read_text())
m["version"] = os.environ["OTA_VERSION"]
m["url"] = os.environ["OTA_URL"]
m["sha256"] = os.environ["OTA_SHA"]
p.write_text(json.dumps(m, indent=2, ensure_ascii=False) + "\n")
PY

if [[ -n "$(git status --porcelain appcast.json)" ]]; then
  git add appcast.json
  git commit -m "chore(release): appcast.json for ${TAG}" >/dev/null
  git push origin main >/dev/null 2>&1 || echo "  (git push skipped — push manually if needed)"
fi

echo "Release published: ${TAG} (assets: $(basename "${DMG_PATH}"), $(basename "${ZIP_PATH}"))"
