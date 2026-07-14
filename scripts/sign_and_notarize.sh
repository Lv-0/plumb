#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Plumb"
DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
MODE="${1:---all}"

: "${DEVELOPER_ID_APP:?请设置 DEVELOPER_ID_APP，例如 Developer ID Application: Your Name (TEAMID)}"
: "${NOTARY_PROFILE:?请设置 NOTARY_PROFILE（xcrun notarytool store-credentials 保存的 profile 名称）}"

expected_team_id() {
  if [[ -n "${DEVELOPER_TEAM_ID:-}" ]]; then
    printf '%s' "${DEVELOPER_TEAM_ID}"
    return
  fi
  if [[ "${DEVELOPER_ID_APP}" =~ \(([A-Z0-9]{10})\)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi
  echo "无法从 DEVELOPER_ID_APP 提取 Team ID；请设置 DEVELOPER_TEAM_ID" >&2
  exit 1
}

EXPECTED_TEAM_ID="$(expected_team_id)"

signature_field() {
  local path="$1" field="$2"
  /usr/bin/codesign -dv --verbose=4 "$path" 2>&1 \
    | /usr/bin/awk -F= -v key="$field" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

verify_exact_identity() {
  local path="$1"
  local authority team
  authority="$(signature_field "$path" Authority)"
  team="$(signature_field "$path" TeamIdentifier)"
  [[ "$authority" == "$DEVELOPER_ID_APP" ]] || {
    echo "签名 Authority 不匹配: actual='${authority}' expected='${DEVELOPER_ID_APP}'" >&2
    exit 1
  }
  [[ "$team" == "$EXPECTED_TEAM_ID" ]] || {
    echo "签名 TeamIdentifier 不匹配: actual='${team}' expected='${EXPECTED_TEAM_ID}'" >&2
    exit 1
  }
}

sign_app() {
  [[ -d "$APP_DIR" ]] || { echo "未找到 ${APP_DIR}，请先运行 scripts/build_app.sh" >&2; exit 1; }

  echo "[sign-app 1/2] Developer ID 签名 .app（Hardened Runtime + timestamp）"
  /usr/bin/codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "${DEVELOPER_ID_APP}" \
    "${APP_DIR}"

  echo "[sign-app 2/2] 校验签名完整性并精确匹配 Authority + Team ID"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
  verify_exact_identity "${APP_DIR}"
}

notarize_dmg() {
  [[ -d "$APP_DIR" ]] || { echo "未找到 ${APP_DIR}" >&2; exit 1; }
  [[ -f "$DMG_PATH" ]] || { echo "未找到 ${DMG_PATH}，请先从已签 app 创建 DMG" >&2; exit 1; }
  verify_exact_identity "${APP_DIR}"

  echo "[notarize 1/6] Developer ID 签名 DMG"
  /usr/bin/codesign \
    --force \
    --timestamp \
    --sign "${DEVELOPER_ID_APP}" \
    "${DMG_PATH}"
  /usr/bin/codesign --verify --strict --verbose=2 "${DMG_PATH}"
  verify_exact_identity "${DMG_PATH}"

  echo "[notarize 2/6] 提交 notarization"
  /usr/bin/xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait

  echo "[notarize 3/6] stapler 回填票据"
  /usr/bin/xcrun stapler staple "${APP_DIR}"
  /usr/bin/xcrun stapler staple "${DMG_PATH}"

  echo "[notarize 4/6] 验证票据"
  /usr/bin/xcrun stapler validate "${APP_DIR}"
  /usr/bin/xcrun stapler validate "${DMG_PATH}"

  echo "[notarize 5/6] 最终签名身份与 Gatekeeper 校验"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
  verify_exact_identity "${APP_DIR}"
  verify_exact_identity "${DMG_PATH}"
  /usr/sbin/spctl --assess --type execute --verbose=4 "${APP_DIR}"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "${DMG_PATH}"

  echo "[notarize 6/6] 完成: ${DMG_PATH}"
}

case "$MODE" in
  --sign-app)
    sign_app
    ;;
  --notarize-dmg)
    notarize_dmg
    ;;
  --all)
    sign_app
    # Always recreate the DMG after signing so it cannot contain the earlier local-signed app.
    scripts/create_dmg.sh
    notarize_dmg
    if [[ -n "${VERSION:-}" ]]; then
      VERSION="$VERSION" scripts/create_zip.sh
    fi
    ;;
  *)
    echo "用法: $0 [--all|--sign-app|--notarize-dmg]" >&2
    exit 2
    ;;
esac
