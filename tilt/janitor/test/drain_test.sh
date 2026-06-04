#!/bin/sh
set -eu

die() {
  echo "error: $*" >&2
  if [ -n "${tilt_log:-}" ] && [ -f "$tilt_log" ]; then
    echo "--- tilt log ---" >&2
    sed -n '1,160p' "$tilt_log" >&2
  fi
  exit 1
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "required command not found: $1"
  fi
}

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
repo_root="$(CDPATH= cd "$script_dir/../../.." && pwd)"

case "$(uname -s)" in
  Darwin | Linux | *BSD) ;;
  *) echo "skip: janitor Tilt drain test requires a POSIX process-group platform" >&2; exit 0 ;;
esac

need tilt

if [ -n "${JANITOR_BIN:-}" ]; then
  janitor_bin="$JANITOR_BIN"
elif command -v janitor >/dev/null 2>&1; then
  janitor_bin="$(command -v janitor)"
elif [ -x "$repo_root/zig-out/bin/janitor" ]; then
  janitor_bin="$repo_root/zig-out/bin/janitor"
else
  need zig
  (cd "$repo_root" && zig build)
  janitor_bin="$repo_root/zig-out/bin/janitor"
fi

[ -x "$janitor_bin" ] || die "janitor binary is not executable: $janitor_bin"

tmp_dir=""
tilt_pid=""
pgid=""

cleanup() {
  status=$?
  trap - EXIT INT TERM HUP

  if [ -n "$tilt_pid" ] && kill -0 "$tilt_pid" 2>/dev/null; then
    kill -TERM "$tilt_pid" 2>/dev/null || true
    wait "$tilt_pid" 2>/dev/null || true
  fi

  if [ -n "$pgid" ] && kill -0 "-$pgid" 2>/dev/null; then
    # The test sleeper ignores TERM by design; use KILL as the last cleanup
    # line so a failed assertion does not leave a dev process group behind.
    kill -TERM "-$pgid" 2>/dev/null || true
    sleep 1
    kill -KILL "-$pgid" 2>/dev/null || true
  fi

  if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
    (cd "$tmp_dir" && tilt down >/dev/null 2>&1) || true
    rm -rf "$tmp_dir"
  fi

  exit "$status"
}
trap cleanup EXIT INT TERM HUP

tmp_dir="$(mktemp -d "$script_dir/.drain-test.XXXXXX")"
pid_file="$tmp_dir/sleeper.pid"
tilt_log="$tmp_dir/tilt.log"

cat >"$tmp_dir/Tiltfile" <<EOF
# -*- mode: Python -*-
load('../../Tiltfile', 'janitor_local_resource')

# serve_cmd is a list so the Starlark string needs no double-escaping: the
# single-quoted argument carries literal $$ (the leader sh's PID) and double
# quotes. List form also means one sh is spawned and it IS the process-group
# leader janitor creates, so the PID it records equals the group's pgid.
janitor_local_resource(
    'janitor-drain-sleeper',
    serve_cmd=['sh', '-c', 'trap "" TERM; echo \$\$ > "$pid_file"; while :; do sleep 1; done'],
    grace_ms=1000,
    watch_path='$tmp_dir',
)
EOF

# exec so tilt_pid is tilt itself, not a wrapping subshell. janitor's parent is
# this tilt process; killing a subshell instead would leave tilt (and thus
# janitor's parent) alive, so the group would never drain.
(
  cd "$tmp_dir"
  exec env JANITOR_BIN="$janitor_bin" tilt up --stream --port 0 >"$tilt_log" 2>&1
) &
tilt_pid=$!

i=0
while [ "$i" -lt 30 ]; do
  if [ -s "$pid_file" ]; then
    sleeper_pid="$(sed -n '1p' "$pid_file")"
    pgid="$(ps -o pgid= -p "$sleeper_pid" 2>/dev/null | tr -d ' ')"
    if [ -n "$pgid" ] && kill -0 "-$pgid" 2>/dev/null; then
      break
    fi
  fi
  if ! kill -0 "$tilt_pid" 2>/dev/null; then
    wait "$tilt_pid" 2>/dev/null || true
    die "tilt exited before the sleeper process group became observable"
  fi
  i=$((i + 1))
  sleep 1
done

[ -n "$pgid" ] || die "timed out waiting for sleeper process group"

kill -9 "$tilt_pid" 2>/dev/null || true
wait "$tilt_pid" 2>/dev/null || true
tilt_pid=""

i=0
while [ "$i" -lt 8 ]; do
  if ! kill -0 "-$pgid" 2>/dev/null; then
    echo "ok: sleeper process group $pgid drained after tilt kill -9"
    pgid=""
    exit 0
  fi
  i=$((i + 1))
  sleep 1
done

die "sleeper process group $pgid still alive after tilt kill -9"
