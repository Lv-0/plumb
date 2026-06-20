#!/usr/bin/env bash
# Package the signed dist/Plumb.app into dist/Plumb-{VERSION}.zip for OTA.
# The zip mirrors build_app.sh's VERSION and the same signed .app the DMG ships.
set -euo pipefail

APP_DIR="dist/Plumb.app"
VERSION="${VERSION:-1.0.0}"
ZIP_PATH="dist/Plumb-${VERSION}.zip"

if [[ ! -d "${APP_DIR}" ]]; then
  echo "未找到 ${APP_DIR}，请先运行 scripts/build_app.sh"
  exit 1
fi

rm -f "${ZIP_PATH}"
# ditto preserves resource forks / extended attrs / code signature for .app bundles
# (unlike `zip -r`, which can strip the seal and break codesign verification).
ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

echo "已生成: ${ZIP_PATH}"
echo "sha256: $(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
