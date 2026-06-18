#!/usr/bin/env bash
set -euo pipefail

echo "[1/4] Build app bundle"
scripts/build_app.sh

echo "[2/4] Create installer dmg"
scripts/create_dmg.sh

echo "[3/4] Sign + notarize release artifact"
scripts/sign_and_notarize.sh

echo "[4/4] Verify notarized dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 dist/Plumb.dmg

echo "Release artifact ready: dist/Plumb.dmg"
