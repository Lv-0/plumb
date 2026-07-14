#!/usr/bin/env bash
set -euo pipefail

# Publish a GitHub Release and upload dist/Plumb.dmg + dist/Plumb-{VERSION}.zip,
# then commit appcast.json so in-app OTA sees the new version.
#
# Usage:
#   GITHUB_TOKEN=... VERSION=1.0.10 scripts/publish_release.sh v1.0.10
#
# Notes:
# - Does not embed tokens anywhere; relies on $GITHUB_TOKEN from the environment.
# - VERSION must match the tag's numeric version (used for the zip asset name).

TAG="${1:-}"
if [[ -z "${TAG}" ]]; then
  echo "Usage: GITHUB_TOKEN=... VERSION=1.0.10 $0 <tag>  (e.g. v1.0.10)"
  exit 1
fi

VERSION="${VERSION:-${TAG#v}}"   # strip leading 'v' from tag as a fallback
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must use X.Y.Z format, got: ${VERSION}" >&2
  exit 2
fi
if [[ "$TAG" != "v${VERSION}" ]]; then
  echo "Tag/version mismatch: TAG=${TAG}, expected v${VERSION}" >&2
  exit 2
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "Missing env var: GITHUB_TOKEN"
  exit 1
fi

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
  curl --fail-with-body -sS \
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

# Release assets are immutable once a name exists. A retry may reuse the remote asset only
# after downloading it and proving its SHA-256 is byte-for-byte identical to the local file.
# A mismatch is never repaired in place: publish a new version/tag instead.
upload_asset() {
  local release_id="$1"
  local assets="$2"
  local path="$3"
  local name="$4"

  local existing_count
  existing_count="$(echo "${assets}" | jq -r --arg name "$name" '[.[] | select(.name == $name)] | length')"
  if [[ "$existing_count" != "0" && "$existing_count" != "1" ]]; then
    echo "Expected at most one immutable asset named ${name}, found ${existing_count}" >&2
    exit 1
  fi

  if [[ "$existing_count" == "1" ]]; then
    local remote_url remote_state local_sha remote_sha
    remote_url="$(echo "${assets}" | jq -r --arg name "$name" '.[] | select(.name == $name) | .browser_download_url')"
    remote_state="$(echo "${assets}" | jq -r --arg name "$name" '.[] | select(.name == $name) | .state')"
    [[ "$remote_url" == https://* ]] || { echo "Existing asset ${name} has invalid download URL" >&2; exit 1; }
    [[ "$remote_state" == "uploaded" ]] || { echo "Existing asset ${name} state is ${remote_state}, not uploaded" >&2; exit 1; }

    local_sha="$(shasum -a 256 "$path" | awk '{print $1}')"
    if ! remote_sha="$(curl --fail-with-body -sSL "$remote_url" | shasum -a 256 | awk '{print $1}')"; then
      echo "Failed to download existing asset ${name} for immutable SHA verification" >&2
      exit 1
    fi
    if [[ "$remote_sha" != "$local_sha" ]]; then
      echo "Immutable asset mismatch for ${name}: remote SHA-256=${remote_sha}, local SHA-256=${local_sha}" >&2
      echo "Refusing to delete or replace a published asset; release a new version/tag." >&2
      exit 1
    fi
    echo "  reusing immutable ${name} (SHA-256 ${local_sha})"
    return
  fi

  local upload_url
  upload_url="$(api "https://api.github.com/repos/${REPO}/releases/${release_id}" | jq -r '.upload_url' | sed 's/{?name,label}//')"
  [[ "$upload_url" == https://* ]] || { echo "Invalid upload URL for release ${release_id}" >&2; exit 1; }
  echo "  uploading ${name}..."
  local upload_response local_size
  local_size="$(wc -c < "$path" | tr -d '[:space:]')"
  upload_response="$(curl --fail-with-body -sS \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"${path}" \
    "${upload_url}?name=${name}")"
  echo "$upload_response" | jq -e \
    --arg name "$name" \
    --argjson size "$local_size" \
    '.name == $name and .size == $size and .state == "uploaded" and (.id | type == "number")' \
    >/dev/null || {
      echo "GitHub did not confirm uploaded asset ${name} (${local_size} bytes)" >&2
      exit 1
    }
}

validate_uploaded_assets() {
  local release_id="$1"
  local assets path name local_size count remote_size state url
  assets="$(api "https://api.github.com/repos/${REPO}/releases/${release_id}/assets")"
  echo "$assets" | jq -e 'type == "array"' >/dev/null || {
    echo "Invalid assets response for release ${release_id}" >&2
    exit 1
  }
  for path in "$DMG_PATH" "$ZIP_PATH"; do
    name="$(basename "$path")"
    local_size="$(wc -c < "$path" | tr -d '[:space:]')"
    count="$(echo "$assets" | jq --arg name "$name" '[.[] | select(.name == $name)] | length')"
    [[ "$count" == "1" ]] || { echo "Expected exactly one uploaded asset named ${name}, found ${count}" >&2; exit 1; }
    remote_size="$(echo "$assets" | jq -r --arg name "$name" '.[] | select(.name == $name) | .size')"
    state="$(echo "$assets" | jq -r --arg name "$name" '.[] | select(.name == $name) | .state')"
    url="$(echo "$assets" | jq -r --arg name "$name" '.[] | select(.name == $name) | .browser_download_url')"
    [[ "$remote_size" == "$local_size" ]] || { echo "Asset size mismatch for ${name}: remote=${remote_size} local=${local_size}" >&2; exit 1; }
    [[ "$state" == "uploaded" ]] || { echo "Asset ${name} state is ${state}, not uploaded" >&2; exit 1; }
    [[ "$url" == https://* ]] || { echo "Asset ${name} has invalid download URL" >&2; exit 1; }
  done
}

RELEASE_NAME="${TAG#v}"

# Release notes are read from a file to avoid a macOS bash 3.2 heredoc-parsing
# quirk that bites when the body contains backticks + apostrophes on the same line.
# Prefer a file-based body: set RELEASE_NOTES_FILE to a path, otherwise use the
# built-in default below.
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-}"
if [[ -z "${RELEASE_NOTES_FILE}" ]]; then
  RELEASE_NOTES_FILE="$(mktemp)"
  trap 'rm -f "${RELEASE_NOTES_FILE}"' EXIT
  cat > "${RELEASE_NOTES_FILE}" <<'NOTES_EOF'
## What's new

### Silent updates with no permission re-grants
- **Dual-path installer.** When the app bundle is owned by you (e.g. installed by dragging from the DMG), updates now replace it silently with no password prompt, mirroring Sparkle's no-password heuristic. Only apps owned by root still ask for your password once.
- **Permissions now survive updates.** Plumb is now signed with a stable local certificate (Plumb Local Signer) instead of ad-hoc. Because macOS TCC keys on the signing identity (not the per-build cdhash), your Accessibility / Screen Recording grants are preserved across updates after the first stable-signed version. This is a build/signing fix with no app behavior change.
- **Reliable auto-relaunch.** The installer now relaunches the new version via the same detached-process mechanism already proven in the update coordinator, so the app restarts itself after an update instead of sometimes needing to be opened manually.

### Fixed
- **Root cause of TCC reset every update:** the self-signed signing certificate was generated without the codeSigning extended key usage, so codesign silently refused to use it and every build fell back to ad-hoc. make_signing_cert.sh now emits a proper code-signing certificate.

### Tests
- 98 unit tests pass (7 new: dual-path installer feasibility detection across admin-owned / root-owned / missing-target cases, plus the unprivileged replace semantics).

### Notes
- Requires macOS 26+.
- Self-signed (not Developer-ID-notarized); if Gatekeeper blocks first open as "damaged", run xattr -dr com.apple.quarantine /Applications/Plumb.app (see README FAQ).
- To enable permission preservation on a machine, run scripts/make_signing_cert.sh once (requires one admin password entry to trust the cert), then all subsequent builds use the stable identity automatically.
NOTES_EOF
fi
BODY="$(json_escape < "${RELEASE_NOTES_FILE}")"

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
set +e
create_resp="$(api -X POST "https://api.github.com/repos/${REPO}/releases" -d "${payload}")"
create_rc=$?
set -e

release_id=""
if [[ $create_rc -eq 0 ]]; then
  release_id="$(echo "${create_resp}" | jq -r '.id // empty')"
fi

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

echo "      Verify both uploaded assets before publishing OTA metadata"
validate_uploaded_assets "${release_id}"

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
  git push origin main >/dev/null
fi

echo "Release published: ${TAG} (assets: $(basename "${DMG_PATH}"), $(basename "${ZIP_PATH}"))"
