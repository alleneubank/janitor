#!/bin/sh
set -eu

repo_url="${JANITOR_REPO_URL:-https://github.com/alleneubank/janitor.git}"
prefix="${PREFIX:-$HOME/.local}"
optimize="${OPTIMIZE:-ReleaseSafe}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

script_dir() {
  case "$0" in
    */*) dirname "$0" ;;
    *) pwd ;;
  esac
}

need zig

tmp_dir=""
cleanup() {
  if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT INT TERM

if [ -f "./build.zig" ] && [ -f "./build.zig.zon" ]; then
  src_dir="$(pwd)"
elif [ -f "$(script_dir)/build.zig" ] && [ -f "$(script_dir)/build.zig.zon" ]; then
  src_dir="$(cd "$(script_dir)" && pwd)"
else
  need git
  tmp_dir="$(mktemp -d)"
  git clone --depth 1 "$repo_url" "$tmp_dir/janitor"
  src_dir="$tmp_dir/janitor"
fi

echo "building janitor from $src_dir"
echo "install prefix: $prefix"

cd "$src_dir"
zig build -Doptimize="$optimize" --prefix "$prefix"

echo "installed: $prefix/bin/janitor"
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "note: add $prefix/bin to PATH to run janitor directly" ;;
esac
