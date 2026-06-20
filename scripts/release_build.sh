#!/usr/bin/env bash
set -euo pipefail

echo "[1/5] Build app bundle"
scripts/build_app.sh

echo "[2/5] Verify stable signing identity (reject ad-hoc)"
scripts/verify_signing_identity.sh dist/Plumb.app

echo "[3/5] Create installer dmg"
scripts/create_dmg.sh

echo "[4/5] Sign + notarize release artifact"
scripts/sign_and_notarize.sh

echo "[5/5] Verify notarized dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 dist/Plumb.dmg

echo "Release artifact ready: dist/Plumb.dmg"
