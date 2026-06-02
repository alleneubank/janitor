#!/bin/sh
set -eu

repo="${JANITOR_REPO:-alleneubank/janitor}"
repo_url="${JANITOR_REPO_URL:-https://github.com/$repo.git}"
version="${JANITOR_VERSION:-latest}"
prefix="${PREFIX:-$HOME/.local}"
optimize="${OPTIMIZE:-ReleaseSafe}"
install_from_source="${JANITOR_INSTALL_FROM_SOURCE:-0}"
dry_run="${JANITOR_INSTALL_DRY_RUN:-0}"

die() {
  echo "error: $*" >&2
  exit 1
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "required command not found: $1"
  fi
}

script_dir() {
  case "$0" in
    */*) dirname "$0" ;;
    *) pwd ;;
  esac
}

detect_artifact() {
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os:$arch" in
    Linux:x86_64 | Linux:amd64) echo "linux-x86_64:tar.gz" ;;
    Linux:aarch64 | Linux:arm64) echo "linux-aarch64:tar.gz" ;;
    Darwin:arm64 | Darwin:aarch64) echo "macos-arm64:zip" ;;
    Darwin:x86_64) echo "macos-x86_64:zip" ;;
    *) die "unsupported platform: $os $arch; set JANITOR_INSTALL_FROM_SOURCE=1 to build locally" ;;
  esac
}

latest_tag() {
  effective_url="$(curl -fsIL -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")"
  tag="${effective_url##*/}"
  [ -n "$tag" ] && [ "$tag" != "latest" ] || die "could not resolve latest stable release for $repo"
  echo "$tag"
}

sha256_file() {
  file="$1"
  case "$(uname -s)" in
    Darwin | *BSD) shasum -a 256 "$file" | awk '{print $1}' ;;
    *) sha256sum "$file" | awk '{print $1}' ;;
  esac
}

download() {
  url="$1"
  out="$2"
  if [ "$dry_run" -eq 1 ]; then
    echo "+ curl -fsSL $url -o $out"
  else
    curl -fsSL "$url" -o "$out"
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

tmp_dir=""
cleanup() {
  if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT INT TERM

install_from_release() {
  need curl

  target_and_ext="$(detect_artifact)"
  target="${target_and_ext%:*}"
  ext="${target_and_ext#*:}"

  if [ "$version" = "latest" ]; then
    if [ "$dry_run" -eq 1 ]; then
      tag="v0.0.0"
    else
      tag="$(latest_tag)"
    fi
  else
    tag="$version"
  fi

  release_version="${tag#v}"
  archive="janitor-$release_version-$target.$ext"
  base_url="https://github.com/$repo/releases/download/$tag"
  archive_url="$base_url/$archive"
  checksum_url="$archive_url.sha256"

  echo "installing janitor $tag for $target"
  echo "install prefix: $prefix"

  if [ "$dry_run" -eq 1 ]; then
    echo "archive: $archive_url"
    echo "checksum: $checksum_url"
    echo "+ install janitor to $prefix/bin/janitor"
    return
  fi

  tmp_dir="$(mktemp -d)"
  archive_path="$tmp_dir/$archive"
  checksum_path="$archive_path.sha256"
  unpack_dir="$tmp_dir/unpack"

  download "$archive_url" "$archive_path"
  download "$checksum_url" "$checksum_path"

  expected="$(awk '{print $1}' "$checksum_path" | sed -n '1p')"
  actual="$(sha256_file "$archive_path")"
  [ -n "$expected" ] || die "empty checksum file: $checksum_url"
  [ "$actual" = "$expected" ] || die "checksum mismatch for $archive"

  mkdir -p "$unpack_dir"
  case "$ext" in
    tar.gz)
      tar -C "$unpack_dir" -xzf "$archive_path"
      ;;
    zip)
      need unzip
      unzip -q "$archive_path" -d "$unpack_dir"
      ;;
    *)
      die "unsupported archive extension: $ext"
      ;;
  esac

  binary="$(find "$unpack_dir" -type f -name janitor -perm -111 | sed -n '1p')"
  [ -n "$binary" ] || die "archive did not contain an executable janitor binary"

  mkdir -p "$prefix/bin"
  cp "$binary" "$prefix/bin/janitor"
  chmod 0755 "$prefix/bin/janitor"
}

install_from_source_tree() {
  need zig

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
}

case "$install_from_source" in
  0 | false | no) install_from_release ;;
  1 | true | yes) install_from_source_tree ;;
  *) die "JANITOR_INSTALL_FROM_SOURCE must be 0 or 1" ;;
esac

echo "installed: $prefix/bin/janitor"
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "note: add $prefix/bin to PATH to run janitor directly" ;;
esac
