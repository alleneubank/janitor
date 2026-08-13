/**
 * janitor pi-hooks extension.
 *
 * Maps the janitor claude/codex PreToolUse + SessionEnd hooks onto pi events.
 * It never re-implements janitor policy: it execs the canonical `janitor
 * cc-hook` binary with the same JSON contract the Claude hook feeds it, so pi
 * and Claude/Codex wrap the same way.
 *
 *   hooks.json PreToolUse (Bash) -> tool_call (bash): decide wrap/passthrough
 *     and, on wrap, rewrite the command via the hook's updatedInput.command
 *     (pi's tool_call event.input.command is mutable — the updatedInput
 *     analogue).
 *   hooks.json SessionEnd        -> session_shutdown: janitor session cleanup.
 *
 * Fail-open by design (mirrors the `|| true` in hooks.json): a missing binary,
 * timeout, or malformed stdout never blocks a tool call or shutdown.
 */
import { isToolCallEventType, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";

const HOOK_TIMEOUT_MS = 5_000;
const MAX_STDOUT_BYTES = 64 * 1024;

/** Run `janitor cc-hook <sub>` with JSON on stdin; fail-open. */
function runCcHook(
  sub: string,
  payload: object,
): Promise<{ stdout: string; code: number; timedOut: boolean }> {
  return new Promise((resolve) => {
    const child = spawn("janitor", ["cc-hook", sub], {
      stdio: ["pipe", "pipe", "ignore"],
    });
    let stdout = "";
    let settled = false;
    const timer = setTimeout(() => {
      settled = true;
      child.kill("SIGKILL");
      resolve({ stdout, code: -1, timedOut: true });
    }, HOOK_TIMEOUT_MS);
    child.stdout.on("data", (chunk: Buffer) => {
      if (stdout.length < MAX_STDOUT_BYTES) {
        stdout += chunk.toString("utf8").slice(0, MAX_STDOUT_BYTES - stdout.length);
      }
    });
    child.on("error", () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ stdout, code: -1, timedOut: false });
    });
    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ stdout, code: code ?? -1, timedOut: false });
    });
    child.stdin.write(JSON.stringify(payload));
    child.stdin.end();
  });
}

/** Parse janitor's PreToolUse updatedInput.command out of stdout. */
function parseWrappedCommand(stdout: string): string | null {
  const text = stdout.trim();
  if (text === "") return null;
  const start = text.indexOf("{");
  if (start < 0) return null;
  try {
    const parsed = JSON.parse(text.slice(start)) as {
      hookSpecificOutput?: { updatedInput?: { command?: string } };
    };
    return parsed.hookSpecificOutput?.updatedInput?.command ?? null;
  } catch {
    return null;
  }
}

export default function janitorPiHooks(pi: ExtensionAPI): void {
  // PreToolUse (Bash) -> rewrite the command when janitor wraps it.
  pi.on("tool_call", async (event, ctx) => {
    if (!isToolCallEventType("bash", event)) return;
    const command = event.input.command ?? "";
    const payload = {
      session_id: ctx.sessionManager.getSessionId?.() ?? "",
      tool_name: "Bash",
      tool_input: { command },
    };
    const { stdout, timedOut, code } = await runCcHook("pretooluse", payload);
    if (timedOut || code !== 0) return; // fail open
    const wrapped = parseWrappedCommand(stdout);
    if (wrapped) {
      event.input.command = wrapped;
    }
  });

  // SessionEnd -> janitor session cleanup.
  pi.on("session_shutdown", async (_event, ctx) => {
    try {
      await runCcHook("session-end", {
        session_id: ctx.sessionManager.getSessionId?.() ?? "",
      });
    } catch {
      // fail open
    }
  });
}
