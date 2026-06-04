#!/bin/sh
# Regression test for janitor binary resolution precedence (REQ-TILT-005/006).
#
# Reproduces the reviewer's isolation setup: no janitor on PATH, an empty
# HOME/PREFIX so $PREFIX/bin/janitor is absent, and a fake `curl` that records
# whether the auto-installer ran. Asserts:
#   A) an explicit janitor_bin override resolves WITHOUT auto-installing, even
#      with auto-install enabled (the default) -- offline/vendored usage;
#   B) with janitor absent and JANITOR_AUTO_INSTALL=0, evaluation fails fast
#      with the actionable install message and never calls curl.
#
# Run manually (like drain_test.sh); it is not part of the hermetic load test.
set -eu

case "$(uname -s)" in
  Darwin | Linux | *BSD) ;;
  *) echo "skip: resolution test requires a POSIX platform" >&2; exit 0 ;;
esac

command -v tilt >/dev/null 2>&1 || { echo "skip: tilt not found" >&2; exit 0; }

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
ext_tiltfile="$script_dir/../Tiltfile"

# Build an isolated PATH that can run tilt + a POSIX shell but contains NO
# janitor. Excluding ~/.local/bin (the usual install prefix) is the point.
dir_of() { d="$(command -v "$1" 2>/dev/null)" && dirname "$d"; }
tilt_dir="$(dir_of tilt)"
git_dir="$(dir_of git || true)"
fake_bin=""

work="$(mktemp -d)"
cleanup() { [ -n "$work" ] && rm -rf "$work"; }
trap cleanup EXIT INT TERM HUP

fake_bin="$work/bin"
mkdir -p "$fake_bin"
curl_marker="$work/curl-was-called"
# A fake curl that records invocation; the auto-installer pipes `curl ... | sh`,
# so any install attempt leaves this marker behind.
cat >"$fake_bin/curl" <<EOF
#!/bin/sh
: >"$curl_marker"
exit 0
EOF
chmod +x "$fake_bin/curl"

iso_path="$fake_bin:$tilt_dir:${git_dir:-$tilt_dir}:/usr/bin:/bin:/usr/sbin:/sbin"
iso_home="$work/home"
mkdir -p "$iso_home"

# Common env for an isolated evaluation: restricted PATH, empty HOME/PREFIX, and
# JANITOR_BIN explicitly cleared so the host environment can't leak an override.
eval_tiltfile() { # $1 = tiltfile path; remaining args = extra VAR=VALUE env
  tf="$1"; shift
  env PATH="$iso_path" HOME="$iso_home" PREFIX="$iso_home/.local" JANITOR_BIN= \
    "$@" tilt alpha tiltfile-result -f "$tf"
}

# --- Case A: explicit janitor_bin must not auto-install ---------------------
cat >"$work/a.Tiltfile" <<EOF
load('$ext_tiltfile', 'janitor_local_resource')
janitor_local_resource('probe', serve_cmd='true', janitor_bin='/usr/bin/true')
EOF
rm -f "$curl_marker"
if ! eval_tiltfile "$work/a.Tiltfile" >/dev/null 2>"$work/a.err"; then
  echo "FAIL case A: evaluation with explicit janitor_bin errored:" >&2
  cat "$work/a.err" >&2
  exit 1
fi
[ ! -f "$curl_marker" ] || { echo "FAIL case A: auto-install ran despite explicit janitor_bin" >&2; exit 1; }
echo "ok case A: explicit janitor_bin resolved without auto-install"

# --- Case B: absent janitor + auto-install off fails fast -------------------
cat >"$work/b.Tiltfile" <<EOF
load('$ext_tiltfile', 'janitor_local_resource')
janitor_local_resource('probe', serve_cmd='true')
EOF
rm -f "$curl_marker"
if eval_tiltfile "$work/b.Tiltfile" JANITOR_AUTO_INSTALL=0 >/dev/null 2>"$work/b.err"; then
  echo "FAIL case B: expected failure when janitor absent and auto-install disabled" >&2
  exit 1
fi
grep -q "binary not found" "$work/b.err" || {
  echo "FAIL case B: missing actionable install message:" >&2
  cat "$work/b.err" >&2
  exit 1
}
[ ! -f "$curl_marker" ] || { echo "FAIL case B: curl ran despite JANITOR_AUTO_INSTALL=0" >&2; exit 1; }
echo "ok case B: absent janitor + auto-install off fails fast with guidance"

echo "PASS: resolution precedence regression"
