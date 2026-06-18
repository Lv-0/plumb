#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Plumb"
DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
STAGE_DIR="$(mktemp -d "${DIST_DIR}/.dmg-stage.XXXXXX")"

cleanup() {
  rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT

if [[ ! -d "${APP_DIR}" ]]; then
  echo "未找到 ${APP_DIR}，请先运行 scripts/build_app.sh"
  exit 1
fi

rm -f "${DMG_PATH}"

# Build a standard installer layout: app bundle + Applications shortcut.
cp -R "${APP_DIR}" "${STAGE_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGE_DIR}/Applications"

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

echo "已生成: ${DMG_PATH}"
