#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Plumb"
BUNDLE_ID="${BUNDLE_ID:-com.comet.plumb}"
VERSION="${VERSION:-1.0.0}"
BUILD_DIR=".build/release"
DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
BINARY_PATH="${BUILD_DIR}/Plumb"
ICON_BUILD_DIR=".build/icons"
APP_ICON="${ICON_BUILD_DIR}/AppIcon.icns"
STATUS_ICON="${ICON_BUILD_DIR}/StatusIconTemplate.png"

echo "[1/4] 生成应用图标与状态栏图标"
scripts/generate_icons.sh

echo "[2/4] 构建 Release 二进制"
swift build -c release

echo "[3/4] 组装 .app Bundle"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

if [[ ! -f "${BINARY_PATH}" ]]; then
  echo "未找到可执行文件 ${BINARY_PATH}"
  exit 1
fi

cp "${BINARY_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "${APP_ICON}" "${APP_DIR}/Contents/Resources/AppIcon.icns"
cp "${STATUS_ICON}" "${APP_DIR}/Contents/Resources/StatusIconTemplate.png"

cat > "${APP_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © $(date +%Y)</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh</string>
    <string>en</string>
    <string>es</string>
    <string>fr</string>
    <string>ja</string>
  </array>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
</dict>
</plist>
EOF

echo "APPL????" > "${APP_DIR}/Contents/PkgInfo"

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

echo "[4/4] 完成: ${APP_DIR}"
