#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: scripts/release-macos.sh [options]

Build, sign, package, and optionally notarize a macOS janitor release archive.

Options:
  --target TARGET           Zig target, defaulting to the current macOS arch.
  --identity NAME           Developer ID Application identity for codesign.
  --notary-profile NAME     notarytool keychain profile name.
  --dist-dir DIR            Output directory. Defaults to ./dist.
  --skip-sign               Build and package without codesign.
  --skip-notarize           Do not submit the archive to Apple's notary service.
  --assess                  Run spctl assessment after notarization.
  --dry-run                 Print commands without executing them.
  -h, --help                Show this help.

Secrets are intentionally not accepted. Create the notary profile with:
  xcrun notarytool store-credentials janitor-notary --apple-id EMAIL --team-id TEAMID
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "required command not found: $1"
  fi
}

run() {
  printf '+'
  for arg do
    printf ' %s' "$arg"
  done
  printf '\n'

  if [ "$dry_run" -eq 0 ]; then
    "$@"
  fi
}

write_checksum() {
  if [ "$dry_run" -eq 1 ]; then
    printf '+ shasum -a 256 %s > %s\n' "$zip_path" "$checksum_path"
  else
    shasum -a 256 "$zip_path" >"$checksum_path"
  fi
}

default_target() {
  case "$(uname -m)" in
    arm64 | aarch64) echo "aarch64-macos" ;;
    x86_64) echo "x86_64-macos" ;;
    *) die "unsupported macOS architecture: $(uname -m)" ;;
  esac
}

artifact_target() {
  case "$1" in
    aarch64-macos) echo "macos-arm64" ;;
    x86_64-macos) echo "macos-x86_64" ;;
    *) die "unsupported release target: $1" ;;
  esac
}

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
project_root="$(CDPATH= cd "$script_dir/.." && pwd)"
version="$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' "$project_root/build.zig.zon" | sed -n '1p')"

[ -n "$version" ] || die "could not read package version from build.zig.zon"

target="${TARGET:-}"
identity="${CODESIGN_IDENTITY:-Developer ID Application: Allen Eubank (H93YRR23HH)}"
notary_profile="${NOTARY_PROFILE:-janitor-notary}"
dist_dir="${DIST_DIR:-dist}"
dry_run=0
skip_sign=0
skip_notarize=0
run_assess=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      [ "$#" -ge 2 ] || die "--target requires a value"
      target="$2"
      shift 2
      ;;
    --identity)
      [ "$#" -ge 2 ] || die "--identity requires a value"
      identity="$2"
      shift 2
      ;;
    --notary-profile)
      [ "$#" -ge 2 ] || die "--notary-profile requires a value"
      notary_profile="$2"
      shift 2
      ;;
    --dist-dir)
      [ "$#" -ge 2 ] || die "--dist-dir requires a value"
      dist_dir="$2"
      shift 2
      ;;
    --skip-sign)
      skip_sign=1
      shift
      ;;
    --skip-notarize)
      skip_notarize=1
      shift
      ;;
    --assess)
      run_assess=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --password | --apple-password | --app-specific-password | --cert-password)
      die "$1 is forbidden; use keychain profiles or secure prompts instead"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[ -n "$target" ] || target="$(default_target)"

case "$dist_dir" in
  /*) ;;
  *) dist_dir="$project_root/$dist_dir" ;;
esac

archive_base="janitor-$version-$(artifact_target "$target")"
stage_dir="$dist_dir/$archive_base"
zip_path="$dist_dir/$archive_base.zip"
checksum_path="$zip_path.sha256"
binary_path="$project_root/zig-out/bin/janitor"

case "$stage_dir" in
  "$dist_dir"/janitor-*) ;;
  *) die "refusing unsafe staging directory: $stage_dir" ;;
esac

if [ "$dry_run" -eq 0 ]; then
  [ "$(uname -s)" = "Darwin" ] || die "macOS release packaging must run on macOS"
  need zig
  need ditto
  need shasum
  [ "$skip_sign" -eq 1 ] || need codesign
  [ "$skip_notarize" -eq 1 ] || need xcrun
  if [ "$run_assess" -eq 1 ]; then
    need spctl
  fi
fi

# Build before staging so a failed compile cannot leave a fresh-looking archive.
run zig build -Doptimize=ReleaseSafe -Dtarget="$target"

if [ "$skip_sign" -eq 0 ]; then
  run codesign --force --timestamp --options runtime --sign "$identity" "$binary_path"
  run codesign --verify --strict --verbose=2 "$binary_path"
fi

run mkdir -p "$dist_dir"
run rm -rf "$stage_dir" "$zip_path" "$checksum_path"
run mkdir -p "$stage_dir"
run cp "$binary_path" "$stage_dir/janitor"
run cp "$project_root/README.md" "$stage_dir/README.md"
run cp "$project_root/LICENSE" "$stage_dir/LICENSE"
run ditto -c -k --keepParent "$stage_dir" "$zip_path"
run shasum -a 256 "$zip_path"
write_checksum

if [ "$skip_notarize" -eq 0 ]; then
  run xcrun notarytool submit "$zip_path" --keychain-profile "$notary_profile" --wait
  if [ "$run_assess" -eq 1 ]; then
    run spctl --assess --type execute --verbose "$binary_path"
  fi
fi

echo "archive: $zip_path"
echo "checksum: $checksum_path"
