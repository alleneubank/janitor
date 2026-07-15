#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: scripts/release-macos.sh [options]

Build, ad-hoc sign, package, extract, and verify a macOS janitor release archive.

Options:
  --target TARGET           Zig target, defaulting to the current macOS arch.
  --dist-dir DIR            Output directory. Defaults to ./dist.
  --dry-run                 Print commands without executing them.
  -h, --help                Show this help.

The ad-hoc signature is credential-free. This script never needs an Apple
identity, certificate, notarization profile, password, private key, or secret.
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

script_dir="$(CDPATH='' cd "$(dirname "$0")" && pwd)"
project_root="$(CDPATH='' cd "$script_dir/.." && pwd)"
version="$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' "$project_root/build.zig.zon" | sed -n '1p')"

[ -n "$version" ] || die "could not read package version from build.zig.zon"

target="${TARGET:-}"
dist_dir="${DIST_DIR:-dist}"
dry_run=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      [ "$#" -ge 2 ] || die "--target requires a value"
      target="$2"
      shift 2
      ;;
    --dist-dir)
      [ "$#" -ge 2 ] || die "--dist-dir requires a value"
      dist_dir="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
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

if [ -n "${RELEASE_TAG:-}" ] && [ "$RELEASE_TAG" != "v$version" ]; then
  die "release tag $RELEASE_TAG does not match package version v$version"
fi

[ -n "$target" ] || target="$(default_target)"

case "$dist_dir" in
  /*) ;;
  *) dist_dir="$project_root/$dist_dir" ;;
esac

archive_base="janitor-$version-$(artifact_target "$target")"
stage_dir="$dist_dir/$archive_base"
verify_dir="$dist_dir/.verify-$archive_base"
zip_path="$dist_dir/$archive_base.zip"
checksum_path="$zip_path.sha256"
binary_path="$project_root/zig-out/bin/janitor"
verified_binary="$verify_dir/$archive_base/janitor"

case "$stage_dir:$verify_dir" in
  "$dist_dir"/janitor-*:"$dist_dir"/.verify-janitor-*) ;;
  *) die "refusing unsafe staging directories" ;;
esac

cleanup() {
  if [ "$dry_run" -eq 0 ]; then
    rm -rf "$verify_dir"
  fi
}
trap cleanup EXIT HUP INT TERM

if [ "$dry_run" -eq 0 ]; then
  [ "$(uname -s)" = "Darwin" ] || die "macOS release packaging must run on macOS"
  need zig
  need codesign
  need ditto
  need cmp
  need shasum
fi

# A release-provided sha wins so CI does not depend on git inside the Nix shell.
if [ -n "${RELEASE_GIT_SHA:-}" ]; then
  run zig build -Doptimize=ReleaseSafe -Dtarget="$target" -Dgit_sha="$RELEASE_GIT_SHA"
else
  run zig build -Doptimize=ReleaseSafe -Dtarget="$target"
fi

run codesign --force --sign - "$binary_path"
run codesign --verify --strict --verbose=2 "$binary_path"

run mkdir -p "$dist_dir"
run rm -rf "$stage_dir" "$verify_dir" "$zip_path" "$checksum_path"
run mkdir -p "$stage_dir"
run cp "$binary_path" "$stage_dir/janitor"
run cmp "$binary_path" "$stage_dir/janitor"
run cp "$project_root/README.md" "$stage_dir/README.md"
run cp "$project_root/LICENSE" "$stage_dir/LICENSE"
run ditto -c -k --keepParent "$stage_dir" "$zip_path"

# Verify what consumers will receive, not merely the pre-archive build output.
run mkdir -p "$verify_dir"
run ditto -x -k "$zip_path" "$verify_dir"
run cmp "$binary_path" "$verified_binary"
run codesign --verify --strict --verbose=2 "$verified_binary"

run shasum -a 256 "$zip_path"
write_checksum

echo "archive: $zip_path"
echo "checksum: $checksum_path"
