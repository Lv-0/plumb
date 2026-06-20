#!/usr/bin/env bash
# Release gate: ensure dist/Plumb.app has a stable designated requirement
# (NOT cdhash). An ad-hoc signature's DR is "cdhash ...", which makes every
# rebuild look like a brand-new app to TCC and invalidates Accessibility /
# Screen Recording grants. Fail loudly so an ad-hoc build can't ship.
set -euo pipefail

APP_DIR="${1:-dist/Plumb.app}"

if [[ ! -d "${APP_DIR}" ]]; then
  echo "❌ 未找到 app 包: ${APP_DIR}"
  exit 1
fi

DR="$(codesign -d -r- "${APP_DIR}" 2>&1)"
if echo "${DR}" | grep -q "cdhash"; then
  echo "❌ 签名为 ad-hoc（DR=cdhash），TCC 权限无法跨更新保留："
  echo "${DR}" | grep "designated"
  echo ""
  echo "修复：运行 scripts/make_signing_cert.sh 生成稳定签名身份后重新构建。"
  exit 1
fi

echo "✅ 签名为稳定身份要求（TCC 权限可跨更新保留）："
echo "${DR}" | grep "designated"
