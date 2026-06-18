#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Plumb"
DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"

: "${DEVELOPER_ID_APP:?请设置 DEVELOPER_ID_APP，例如 Developer ID Application: Your Name (TEAMID)}"
: "${NOTARY_PROFILE:?请设置 NOTARY_PROFILE（xcrun notarytool store-credentials 保存的 profile 名称）}"

if [[ ! -d "${APP_DIR}" ]]; then
  echo "未找到 ${APP_DIR}，请先运行 scripts/build_app.sh"
  exit 1
fi

if [[ ! -f "${DMG_PATH}" ]]; then
  echo "未找到 ${DMG_PATH}，请先运行 scripts/create_dmg.sh"
  exit 1
fi

echo "[1/6] 对 .app 签名（Hardened Runtime + 时间戳）"
codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --sign "${DEVELOPER_ID_APP}" \
  "${APP_DIR}"

echo "[2/6] 校验 .app 签名"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
spctl --assess --type execute --verbose=4 "${APP_DIR}"

echo "[3/6] 对 .dmg 签名"
codesign \
  --force \
  --timestamp \
  --sign "${DEVELOPER_ID_APP}" \
  "${DMG_PATH}"

echo "[4/6] 提交 notarization"
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait

echo "[5/6] stapler 回填票据"
xcrun stapler staple "${APP_DIR}"
xcrun stapler staple "${DMG_PATH}"

echo "[6/6] 最终 Gatekeeper 验证"
spctl --assess --type open --context context:primary-signature --verbose=4 "${DMG_PATH}"
echo "签名 + 公证完成: ${DMG_PATH}"
