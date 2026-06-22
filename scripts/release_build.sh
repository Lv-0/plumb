#!/usr/bin/env bash
set -euo pipefail

echo "[1/7] Build app bundle"
scripts/build_app.sh

echo "[2/7] Sign app before packaging dmg"
: "${DEVELOPER_ID_APP:?请设置 DEVELOPER_ID_APP，例如 Developer ID Application: Your Name (TEAMID)}"
codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --sign "${DEVELOPER_ID_APP}" \
  dist/Plumb.app
codesign --verify --deep --strict --verbose=2 dist/Plumb.app
spctl --assess --type execute --verbose=4 dist/Plumb.app

echo "[3/7] Verify app signing identity"
scripts/verify_signing_identity.sh dist/Plumb.app

echo "[4/7] Create installer dmg"
scripts/create_dmg.sh

echo "[5/7] Sign + notarize release artifact"
scripts/sign_and_notarize.sh

echo "[6/7] Create OTA zip from the final signed app"
scripts/create_zip.sh

echo "[7/7] Verify notarized dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 dist/Plumb.dmg

echo "Release artifacts ready: dist/Plumb.dmg and dist/Plumb-${VERSION:-1.0.0}.zip"
