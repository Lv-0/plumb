#!/usr/bin/env bash
# Check the signing identity of dist/Plumb.app.
#
# A stable (non-cdhash) designated requirement means TCC permissions (Accessibility /
# Screen Recording) survive updates. An ad-hoc signature's DR is "cdhash ...", which
# makes every rebuild look like a brand-new app to TCC and invalidates grants.
#
# Behavior:
#   - stable identity → print ✅, exit 0
#   - ad-hoc (cdhash) → print ⚠️  WARNING (NOT a hard fail), exit 0
#       (ad-hoc is a valid release path when no trusted signing identity is available;
#        the OTA feature works regardless, only permission-persistence is affected.)
#   - To make ad-hoc a hard failure (e.g. CI enforcing stable signing), set
#     PLUMB_STRICT_SIGNING=1 — then ad-hoc exits 1.
set -euo pipefail

APP_DIR="${1:-dist/Plumb.app}"

if [[ ! -d "${APP_DIR}" ]]; then
  echo "❌ 未找到 app 包: ${APP_DIR}"
  exit 1
fi

DR="$(codesign -d -r- "${APP_DIR}" 2>&1)"
if echo "${DR}" | grep -q "cdhash"; then
  echo "⚠️  签名为 ad-hoc（DR=cdhash）：TCC 权限将无法跨更新保留。"
  echo "    （这是允许的发版路径，OTA 自动更新功能不受影响；仅权限保留需稳定签名身份。）"
  echo "    若将来有可信签名身份，运行 scripts/make_signing_cert.sh 后重新构建即可。"
  if [[ "${PLUMB_STRICT_SIGNING:-0}" == "1" ]]; then
    echo "    PLUMB_STRICT_SIGNING=1 已设置 → 视为硬失败。"
    exit 1
  fi
  exit 0
fi

echo "✅ 签名为稳定身份要求（TCC 权限可跨更新保留）："
echo "${DR}" | grep "designated"
