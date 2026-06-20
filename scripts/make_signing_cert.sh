#!/usr/bin/env bash
# One-time setup: create a trusted self-signed code-signing identity so that
# Plumb's TCC permissions (Accessibility / Screen Recording) survive updates.
#
# Idempotent: if an identity named PLUMB_SIGNING_IDENTITY already exists, exits 0.
# Requires one administrator authorization (to set the trust setting).
set -euo pipefail

CERT_NAME="${PLUMB_SIGNING_IDENTITY:-Plumb Local Signer}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# 1) Idempotent: skip if the identity already exists in any keychain on the search list.
if security find-identity -v | grep -q "\"${CERT_NAME}\""; then
  echo "签名身份已存在: \"${CERT_NAME}\"（跳过创建）"
  exit 0
fi

# 2) Generate a self-signed cert (10-year validity covers many release cycles).
echo "生成自签名证书: ${CERT_NAME}"
openssl req -x509 -newkey rsa:2048 \
  -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
  -days 3650 -nodes -subj "/CN=${CERT_NAME}" >/dev/null 2>&1

# 3) Export as p12 with legacy encryption (OpenSSL 3.x default is unreadable by
#    the macOS `security` tool — import fails with "MAC verification failed").
PW="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy \
  -in "$WORKDIR/cert.pem" -inkey "$WORKDIR/key.pem" \
  -out "$WORKDIR/signer.p12" -password pass:"$PW" >/dev/null 2>&1

# 4) Import into the user's login keychain and authorize codesign to use it.
LOGIN_KC="$(security login-keychain | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
security import "$WORKDIR/signer.p12" -k "$LOGIN_KC" -P "$PW" -T /usr/bin/codesign

# 5) Trust it as a code-signing root (requires one admin authorization).
#    Without this step the cert is CSSMERR_TP_NOT_TRUSTED and codesign reports
#    "no identities are available".
echo "将证书设为受信任的代码签名根（需要一次管理员授权）…"
sudo security add-trusted-cert -d -r trustRoot -k "$LOGIN_KC" -p codeSign "$WORKDIR/cert.pem"

echo "✅ 签名身份已就绪: \"${CERT_NAME}\""
echo "   之后每次 scripts/build_app.sh 将自动使用该身份签名，TCC 权限可跨更新保留。"
