#!/usr/bin/env bash
# One-time setup: create a trusted self-signed code-signing identity so that
# Plumb's TCC permissions (Accessibility / Screen Recording) survive updates.
#
# Idempotent: if a TRUSTED identity named PLUMB_SIGNING_IDENTITY already exists,
# exits 0. If an untrusted cert of that name exists (e.g. from a previous failed
# trust step), it is removed first to avoid duplicates.
#
# IMPORTANT: the trust step writes to the admin (system-wide) trust domain, which
# requires `sudo` with an interactive password prompt. This script MUST be run in
# an interactive Terminal (not piped / not in a non-TTY shell) — otherwise the
# sudo step fails and the script will exit with an error rather than fake success.
set -euo pipefail

CERT_NAME="${PLUMB_SIGNING_IDENTITY:-Plumb Local Signer}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# 1) Idempotency: check for a TRUSTED identity (find-identity -v lists valid only).
#    If one exists, we're done. If only an UNTRUSTED cert exists, delete it first
#    (a previous trust step failed and left a stray cert) to avoid duplicates.
if security find-identity -v | grep -q "\"${CERT_NAME}\""; then
  echo "已存在受信任的签名身份: \"${CERT_NAME}\"（跳过创建）"
  exit 0
fi

# Remove any untrusted leftover certs of the same name (by hash, unambiguous).
# find-identity WITHOUT -v lists matching identities even if untrusted.
# NOTE: `|| true` — grep returns non-zero when there's no match, which under
# `set -e -o pipefail` would abort the script here; we want empty (no leftovers)
# to be a normal case.
existing_hashes="$(security find-identity 2>/dev/null | grep "\"${CERT_NAME}\"" | awk '{print $2}' || true)"
if [[ -n "${existing_hashes}" ]]; then
  echo "检测到未受信任的旧证书，先清理（避免重复）…"
  while IFS= read -r h; do
    [[ -n "${h}" ]] && security delete-certificate -Z "${h}" >/dev/null 2>&1 || true
  done <<< "${existing_hashes}"
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

# 5) Trust it as a code-signing root in the ADMIN (system-wide) domain.
#    This is REQUIRED: only admin-domain trust makes codesign accept a self-signed
#    cert as a valid signing identity (per-user trust does not satisfy the
#    codesigning policy). Requires `sudo` with an interactive password prompt —
#    run this script in a real Terminal, not a non-interactive shell.
echo "将证书设为受信任的代码签名根（admin 域，需要管理员密码）…"
echo "  → 如果这一步没有弹出系统密码框，请确认你在交互式 Terminal 里运行此脚本。"
if ! sudo security add-trusted-cert -d -r trustRoot -k "$LOGIN_KC" -p codeSign "$WORKDIR/cert.pem"; then
  echo ""
  echo "❌ 信任步骤失败（sudo 未能交互式授权）。"
  echo "   请在一个真正的交互式 Terminal 里重新运行此脚本（不要通过管道/非交互 shell）。"
  echo "   sudo 需要终端读取密码。已导入的未信任证书已清理，下次运行会重新生成。"
  # Clean up the untrusted cert we just imported, so a re-run starts clean.
  new_hashes="$(security find-identity 2>/dev/null | grep "\"${CERT_NAME}\"" | awk '{print $2}')"
  while IFS= read -r h; do
    [[ -n "${h}" ]] && security delete-certificate -Z "${h}" >/dev/null 2>&1 || true
  done <<< "${new_hashes}"
  exit 1
fi

# 6) VERIFY the trust actually took effect: find-identity -v must now list it.
#    This catches the previous failure mode where sudo returned 0 but trust didn't apply.
if ! security find-identity -v | grep -q "\"${CERT_NAME}\""; then
  echo ""
  echo "❌ 证书已导入但信任未生效（find-identity -v 未列出该身份）。"
  echo "   这通常意味着 sudo 那步没有真正写入 admin 域信任。"
  echo "   请在「钥匙串访问」App 中手动信任该证书（双击 → 信任 → 始终信任），"
  echo "   或在交互式 Terminal 重跑此脚本。"
  exit 1
fi

echo "✅ 签名身份已就绪: \"${CERT_NAME}\""
echo "   之后每次 scripts/build_app.sh 将自动使用该身份签名，TCC 权限可跨更新保留。"
