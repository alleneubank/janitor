#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage: scripts/cli-e2e.sh [options]

Run the janitor Claude Code plugin through a real `claude` CLI session and
check what the Bash tool actually executed. Three cases run in throwaway git
repositories under a private sandbox:

  control   plain session         -> the command runs under janitor
  isolated  after EnterWorktree   -> the command runs unwrapped (REQ-PLUGIN-008)
  exited    EnterWorktree, Exit   -> the command runs under janitor again

Each session uses `claude -p --restricted`, so user, project, and local
settings (plugins, hooks) are ignored; the plugin under test is the only
customization, loaded from ./plugin via --plugin-dir. Authentication comes
from the default Claude Code config, so `claude` must already be logged in.
Every case spends a few model turns.

Options:
  --janitor PATH     janitor binary to put first on PATH (default: zig-out/bin/janitor).
  --model MODEL      Model for the sessions (default: haiku).
  --expect-refusal   Expect the isolated case to be refused by Claude Code's
                     worktree guard instead of passing through. Run it against
                     a pre-0.3.1 janitor to prove the guard is still live.
  --case NAME        Run only this case (control, isolated, exited); repeatable.
  --keep             Keep the sandbox and its stream logs for inspection.
  -h, --help         Show this help.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

project_root=$(cd "$(dirname "$0")/.." && pwd)
janitor="$project_root/zig-out/bin/janitor"
model=haiku
expect_refusal=0
keep=0
cases=""

while [ $# -gt 0 ]; do
  case $1 in
    --janitor) [ $# -ge 2 ] || die "--janitor needs a path"; janitor=$2; shift 2 ;;
    --model) [ $# -ge 2 ] || die "--model needs a value"; model=$2; shift 2 ;;
    --case) [ $# -ge 2 ] || die "--case needs a name"; cases="$cases $2"; shift 2 ;;
    --expect-refusal) expect_refusal=1; shift ;;
    --keep) keep=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

command -v claude >/dev/null 2>&1 || die "claude CLI not found on PATH"
command -v git >/dev/null 2>&1 || die "git not found on PATH"
[ -x "$janitor" ] || die "janitor binary not executable: $janitor (run: zig build)"
janitor=$(cd "$(dirname "$janitor")" && pwd -P)/$(basename "$janitor")
bindir=$(dirname "$janitor")
plugin_dir="$project_root/plugin"
[ -f "$plugin_dir/hooks/hooks.json" ] || die "plugin hooks not found under $plugin_dir"

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/janitor-cli-e2e.XXXXXX")
sandbox=$(cd "$sandbox" && pwd -P)
# Claude Code stores each session transcript under a slug of the working
# directory; every sandbox repository slugs to this prefix.
transcript_slug=$(printf '%s' "$sandbox" | sed 's#[/.]#-#g')
projects_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"

cleanup() {
  if [ "$keep" -eq 1 ]; then
    echo "sandbox kept at $sandbox"
    return
  fi
  rm -rf "$sandbox"
  case $transcript_slug in
    -*) rm -rf "$projects_dir/$transcript_slug"* ;;
  esac
}
trap cleanup EXIT

# The command reports the Bash tool's parent process (janitor when wrapped)
# and leaves a marker so a refused command is distinguishable from a silent one.
probe_command='ps -o comm= -p $PPID | sed "s/^/PARENT=/" && printf done > marker.txt'
probe_reply='Run it in the foreground, not in the background. Then reply with the Bash tool output verbatim. Do not run any other commands.'

failures=0

fail() {
  echo "FAIL [$1] $2" >&2
  failures=$((failures + 1))
  # Show what the model actually ran and what the tool returned.
  grep -o '"name":"[A-Za-z]*","input":{[^}]*}' "$sandbox/$1.stream.jsonl" | sed 's/^/  tool_use   /' >&2 || true
  grep -o '"type":"tool_result","content":"[^"]\{0,250\}' "$sandbox/$1.stream.jsonl" | sed 's/^/  tool_result /' >&2 || true
}

# run_case LABEL MODE
run_case() {
  label=$1
  mode=$2
  repo="$sandbox/repo-$label"
  runtime_dir="$sandbox/tmp-$label"
  stream="$sandbox/$label.stream.jsonl"

  mkdir -p "$repo" "$runtime_dir"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.name=cli-e2e -c user.email=cli-e2e@example.invalid \
    commit -q --allow-empty -m init

  case $mode in
    control)
      prompt="Use the Bash tool to run exactly this command, unchanged: $probe_command
$probe_reply" ;;
    isolated)
      prompt="First call the EnterWorktree tool with name \"e2e\". After it succeeds, use the Bash tool to run exactly this command, unchanged: $probe_command
$probe_reply" ;;
    exited)
      prompt="First call the EnterWorktree tool with name \"e2e\". Then call the ExitWorktree tool to leave it (keep the worktree). After that, use the Bash tool to run exactly this command, unchanged: $probe_command
$probe_reply" ;;
  esac

  # XDG_RUNTIME_DIR and JANITOR_CC_* are dropped so the hook's lock directory
  # and configuration cannot leak in from the caller's environment.
  (
    cd "$repo"
    env -u XDG_RUNTIME_DIR -u JANITOR_CC_ENABLED -u JANITOR_CC_WRAP_MODE \
      -u JANITOR_CC_SKIP_PATTERNS -u JANITOR_CC_DENY_PATTERNS -u JANITOR_CC_SHELL \
      -u JANITOR_CC_GRACE_MS \
      TMPDIR="$runtime_dir" PATH="$bindir:$PATH" \
      claude -p "$prompt" --model "$model" --plugin-dir "$plugin_dir" \
        --restricted --tools "Bash,EnterWorktree,ExitWorktree" \
        --allowedTools "Bash,EnterWorktree,ExitWorktree" --max-turns 8 \
        --output-format stream-json --verbose < /dev/null > "$stream" 2> "$sandbox/$label.stderr"
  ) || fail "$label" "claude exited non-zero (see $sandbox/$label.stderr)"

  grep -q '"name":"janitor-bash-drain"' "$stream" || fail "$label" "plugin janitor-bash-drain did not load"
  if grep -q '"plugins":\[{[^]]*},{' "$stream"; then
    fail "$label" "more than one plugin loaded; session is not hermetic"
  fi
  if ! grep -q '"name":"Bash"' "$stream"; then
    fail "$label" "the Bash tool was never called"
  fi

  # Read the parent name from the tool_result record itself; the tool input
  # and the model's prose also mention PARENT= and would be false matches.
  parent=$(grep -o '"type":"tool_result","content":"PARENT=[^"\\]*' "$stream" | head -1 | sed 's/.*"content":"//' || true)
  refused=0
  grep -q 'Refusing to run it' "$stream" && refused=1
  markers=$(find "$repo" -name marker.txt | sed "s#^$repo/##")
  echo "[$label] parent='${parent#PARENT=}' refused=$refused marker='${markers:-none}'"

  case $mode:$expect_refusal in
    isolated:1)
      [ "$refused" -eq 1 ] || fail "$label" "expected the worktree guard to refuse the wrapped command"
      [ -z "$markers" ] || fail "$label" "refused command still ran"
      ;;
    isolated:0)
      [ "$refused" -eq 0 ] || fail "$label" "worktree guard refused the command"
      case $parent in
        *janitor*) fail "$label" "command was wrapped inside a worktree-isolated session" ;;
        PARENT=*) ;;
        *) fail "$label" "no PARENT line in the tool result" ;;
      esac
      case $markers in
        .claude/worktrees/*/marker.txt) ;;
        *) fail "$label" "marker missing from the worktree (got: ${markers:-none})" ;;
      esac
      ;;
    *)
      [ "$refused" -eq 0 ] || fail "$label" "worktree guard refused the command"
      case $parent in
        *janitor*) ;;
        *) fail "$label" "command did not run under janitor (parent: ${parent#PARENT=})" ;;
      esac
      [ "$markers" = marker.txt ] || fail "$label" "marker missing from the repository root (got: ${markers:-none})"
      ;;
  esac
}

echo "janitor: $janitor ($("$janitor" --version))"
echo "claude:  $(claude --version 2>/dev/null | head -1)"
[ -n "$cases" ] || cases="control isolated exited"
for case_name in $cases; do
  case $case_name in
    control|isolated|exited) run_case "$case_name" "$case_name" ;;
    *) die "unknown case: $case_name" ;;
  esac
done

if [ "$failures" -ne 0 ]; then
  echo "cli-e2e: $failures failure(s)" >&2
  exit 1
fi
echo "cli-e2e: all cases passed"
