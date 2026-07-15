#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd "$(dirname "$0")" && pwd)"
project_root="$(CDPATH='' cd "$script_dir/.." && pwd)"
release_script="$project_root/scripts/release-macos.sh"
workflow="$project_root/.github/workflows/release.yml"

fail() {
  echo "release automation check failed: $*" >&2
  exit 1
}

assert_contains() {
  haystack="$1"
  needle="$2"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "missing expected text: $needle" ;;
  esac
}

forbidden_pattern='notarytool|MACOS_CERTIFICATE|APPLE_ID|APPLE_TEAM_ID|APPLE_APP_SPECIFIC_PASSWORD|CODESIGN_IDENTITY|--timestamp|--options runtime'
if grep -E "$forbidden_pattern" "$release_script" "$workflow" >/dev/null; then
  fail "release automation still depends on Developer ID or notarization"
fi

dry_run="$($release_script --dry-run --target aarch64-macos)"
assert_contains "$dry_run" "codesign --force --sign -"
assert_contains "$dry_run" "ditto -c -k --keepParent"
assert_contains "$dry_run" "ditto -x -k"
assert_contains "$dry_run" "codesign --verify --strict"
assert_contains "$dry_run" "export SDKROOT=\$(xcrun --sdk macosx --show-sdk-path)"

if RELEASE_TAG=v0.0.0 "$release_script" --dry-run --target aarch64-macos >/dev/null 2>&1; then
  fail "mismatched release tag unexpectedly passed"
fi

workflow_text="$(sed -n '1,260p' "$workflow")"
assert_contains "$workflow_text" "nix develop -c scripts/release-macos.sh"
assert_contains "$workflow_text" "if-no-files-found: error"
assert_contains "$workflow_text" "--draft"

ci_workflow_text="$(sed -n '1,220p' "$project_root/.github/workflows/ci.yml")"
assert_contains "$ci_workflow_text" "runs-on: macos-latest"
assert_contains "$ci_workflow_text" "nix develop -c scripts/release-macos.sh"

echo "release automation contract: ok"
