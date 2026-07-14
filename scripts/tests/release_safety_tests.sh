#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "release-safety: FAIL — $*" >&2
  exit 1
}

bash -n scripts/release.sh scripts/publish_release.sh scripts/sign_and_notarize.sh scripts/tests/release_safety_tests.sh

# The Developer ID flow must sign the app before creating the DMG, notarize that DMG,
# and create the OTA ZIP only after stapling. Lock the real orchestration order.
sign_line="$(grep -n 'sign_and_notarize.sh --sign-app' scripts/release.sh | head -1 | cut -d: -f1)"
dmg_line="$(grep -n 'create_dmg.sh（来自 Developer ID app）' scripts/release.sh | head -1 | cut -d: -f1)"
notary_line="$(grep -n 'sign_and_notarize.sh --notarize-dmg' scripts/release.sh | head -1 | cut -d: -f1)"
zip_line="$(grep -n 'create_zip.sh（来自最终 stapled app）' scripts/release.sh | head -1 | cut -d: -f1)"
[[ -n "$sign_line" && -n "$dmg_line" && -n "$notary_line" && -n "$zip_line" ]] \
  || fail "Developer ID orchestration markers are missing"
(( sign_line < dmg_line && dmg_line < notary_line && notary_line < zip_line )) \
  || fail "Developer ID artifact order is unsafe"

grep -Fq 'git fetch --prune --tags origin' scripts/release.sh \
  || fail "release preflight does not refresh origin"
grep -Fq 'origin/main...HEAD' scripts/release.sh \
  || fail "release preflight does not compute behind/ahead"
grep -Fq 'curl --fail-with-body' scripts/publish_release.sh \
  || fail "GitHub HTTP calls are not fail-closed"
grep -Fq 'validate_uploaded_assets' scripts/publish_release.sh \
  || fail "uploaded assets are not verified before appcast publication"
verify_assets_line="$(grep -n '^validate_uploaded_assets "${release_id}"' scripts/publish_release.sh | cut -d: -f1)"
appcast_line="$(grep -n '^export OTA_VERSION=' scripts/publish_release.sh | cut -d: -f1)"
[[ -n "$verify_assets_line" && -n "$appcast_line" && "$verify_assets_line" -lt "$appcast_line" ]] \
  || fail "appcast can be changed before remote assets are verified"

sign_app_body="$(sed -n '/^sign_app() {/,/^}/p' scripts/sign_and_notarize.sh)"
[[ "$sign_app_body" != *"spctl"* ]] \
  || fail "Gatekeeper assessment runs before the app has a notarization ticket"
notarize_body="$(sed -n '/^notarize_dmg() {/,/^}/p' scripts/sign_and_notarize.sh)"
[[ "$notarize_body" == *"stapler validate"* && "$notarize_body" == *"spctl --assess"* ]] \
  || fail "notarized artifacts lack final ticket/Gatekeeper validation"

# Developer ID publication must stop before print_plan/preflight/build/network while the local-signer
# bridge and staged migration path do not exist.
set +e
developer_block_output="$(bash scripts/release.sh 9.9.9 --sign developer-id 2>&1)"
developer_block_rc=$?
set -e
[[ $developer_block_rc -ne 0 ]] || fail "Developer ID release was not hard-blocked"
[[ "$developer_block_output" == *"bridge signer allowlist"* ]] \
  || fail "Developer ID block does not explain the bridge prerequisite"

# The standalone publisher must reject mismatched tag/version inputs before assets or network matter.
set +e
tag_mismatch_output="$(GITHUB_TOKEN=test-token VERSION=9.9.9 \
  bash scripts/publish_release.sh v9.9.8 2>&1)"
tag_mismatch_rc=$?
set -e
[[ $tag_mismatch_rc -ne 0 ]] || fail "publish script accepted TAG != vVERSION"
[[ "$tag_mismatch_output" == *"Tag/version mismatch"* ]] \
  || fail "tag/version mismatch did not return the expected diagnostic"

# Exercise fresh-upload failure plus immutable-asset retry behavior against the real publish script.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/plumb-release-safety.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
url=""
method="GET"
upload_path=""
previous=""
for arg in "$@"; do
  [[ "$arg" == https://* ]] && url="$arg"
  [[ "$previous" == "-X" ]] && method="$arg"
  [[ "$previous" == "--data-binary" ]] && upload_path="${arg#@}"
  previous="$arg"
done
printf '%s %s\n' "$method" "$url" >> "$CALL_LOG"

if [[ "$method" == "DELETE" ]]; then
  echo '{"message":"immutable assets must never be deleted"}'
  exit 97
fi

if [[ -n "$upload_path" ]]; then
  printf 'UPLOAD %s\n' "$url" >> "$CALL_LOG"
  if [[ "$SCENARIO" == "fresh-failure" ]]; then
    echo '{"message":"injected asset upload failure"}'
    exit 22
  fi
  echo '{"message":"unexpected upload for existing immutable asset"}'
  exit 96
fi

case "$method $url" in
  "POST https://api.github.com/repos/Lv-0/plumb/releases")
    echo '{"id":42}'
    ;;
  "GET https://api.github.com/repos/Lv-0/plumb/releases/42/assets")
    if [[ "$SCENARIO" == "fresh-failure" ]]; then
      echo '[]'
    else
      echo '[{"id":1,"name":"Plumb.dmg","size":3,"state":"uploaded","browser_download_url":"https://downloads.test/Plumb.dmg"},{"id":2,"name":"Plumb-9.9.9.zip","size":3,"state":"uploaded","browser_download_url":"https://downloads.test/Plumb-9.9.9.zip"}]'
    fi
    ;;
  "GET https://api.github.com/repos/Lv-0/plumb/releases/42")
    echo '{"upload_url":"https://uploads.github.test/releases/42/assets{?name,label}"}'
    ;;
  "GET https://downloads.test/Plumb.dmg")
    printf 'dmg'
    ;;
  "GET https://downloads.test/Plumb-9.9.9.zip")
    if [[ "$SCENARIO" == "reuse-mismatch" ]]; then printf 'bad'; else printf 'zip'; fi
    ;;
  *)
    echo "{\"message\":\"unexpected test request: ${method} ${url}\"}"
    exit 22
    ;;
esac
STUB
chmod +x "$tmp/bin/curl"

cat > "$tmp/bin/git" <<'STUB'
#!/usr/bin/env bash
# Successful reuse writes the same appcast values; model a clean git worktree so no commit/push runs.
if [[ "${1:-}" == "status" ]]; then exit 0; fi
echo "unexpected git command: $*" >&2
exit 95
STUB
chmod +x "$tmp/bin/git"

make_worktree() {
  local name="$1"
  local work="$tmp/$name"
  mkdir -p "$work/dist"
  cp scripts/publish_release.sh "$work/publish_release.sh"
  printf 'dmg' > "$work/dist/Plumb.dmg"
  printf 'zip' > "$work/dist/Plumb-9.9.9.zip"
  printf '{"version":"1.0.0","url":"old","sha256":"old"}\n' > "$work/appcast.json"
  cp "$work/appcast.json" "$work/appcast.before.json"
  printf '%s' "$work"
}

# A fresh release upload failure must stop before appcast mutation.
fresh_work="$(make_worktree fresh)"
fresh_log="$tmp/fresh.calls"
set +e
(
  cd "$fresh_work"
  CALL_LOG="$fresh_log" SCENARIO="fresh-failure" PATH="$tmp/bin:$PATH" \
    GITHUB_TOKEN="test-token" VERSION="9.9.9" \
    bash ./publish_release.sh v9.9.9 >/dev/null 2>&1
)
publish_rc=$?
set -e
[[ $publish_rc -ne 0 ]] || fail "publish script accepted an asset upload HTTP failure"
cmp -s "$fresh_work/appcast.before.json" "$fresh_work/appcast.json" \
  || fail "publish script changed appcast after an asset upload failure"

# Existing byte-identical assets are downloaded, SHA-verified, and reused without upload/delete.
matching_work="$(make_worktree matching)"
matching_log="$tmp/matching.calls"
(
  cd "$matching_work"
  CALL_LOG="$matching_log" SCENARIO="reuse-match" PATH="$tmp/bin:$PATH" \
    GITHUB_TOKEN="test-token" VERSION="9.9.9" \
    bash ./publish_release.sh v9.9.9 >/dev/null 2>&1
) || fail "publish script failed to reuse byte-identical immutable assets"
grep -Fq 'GET https://downloads.test/Plumb.dmg' "$matching_log" \
  || fail "existing DMG was not downloaded for SHA verification"
grep -Fq 'GET https://downloads.test/Plumb-9.9.9.zip' "$matching_log" \
  || fail "existing ZIP was not downloaded for SHA verification"
if grep -Eq '(^DELETE |^UPLOAD )' "$matching_log"; then
  fail "byte-identical immutable assets were mutated"
fi

# Same-size but different-content remote ZIP must fail without DELETE/upload/appcast mutation.
mismatch_work="$(make_worktree mismatch)"
mismatch_log="$tmp/mismatch.calls"
set +e
(
  cd "$mismatch_work"
  CALL_LOG="$mismatch_log" SCENARIO="reuse-mismatch" PATH="$tmp/bin:$PATH" \
    GITHUB_TOKEN="test-token" VERSION="9.9.9" \
    bash ./publish_release.sh v9.9.9 >"$tmp/mismatch.out" 2>&1
)
mismatch_rc=$?
set -e
[[ $mismatch_rc -ne 0 ]] || fail "publish script accepted a mismatched immutable asset"
grep -Fq 'Immutable asset mismatch' "$tmp/mismatch.out" \
  || fail "immutable mismatch did not return the expected diagnostic"
cmp -s "$mismatch_work/appcast.before.json" "$mismatch_work/appcast.json" \
  || fail "publish script changed appcast after immutable asset mismatch"
if grep -Eq '(^DELETE |^UPLOAD )' "$mismatch_log"; then
  fail "mismatched immutable asset was deleted or replaced"
fi

echo "release-safety: PASS"
