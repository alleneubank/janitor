> Law doc for Janitor process supervision, present-tense, no narrated history — git is the changelog. Amend Decisions and Boundary only with human confirmation; dated working memory lives outside this file.

## Bar

Janitor supervision is shippable when teardown signals only its original child
process group or descendants that pass the strongest platform identity
verification: Linux binds the ancestry-proving process-table record to the
stable handle used for liveness and signaling, while Darwin (macOS) immediately
revalidates `(pid, start_time)` before `kill(pid, signal)` with the residual
validation-to-`kill` race explicitly acknowledged. The retained kqueue BSDs
(FreeBSD, OpenBSD, NetBSD, DragonFly) are group-only and say so.

## Dimensions

- Ownership proof and PID-reuse safety.
- Complete, bounded drain behavior and direct-child status fidelity.
- Diagnostic honesty when native discovery cannot prove a target.
- Native-platform verification of the promised behavior.

## Floors

- Process-tree unit tests prove PPID closure, unrelated-process exclusion,
  identity mismatch/PID reuse rejection, and bounded-resweep anchoring. They
  include the Linux acquisition race: an old descendant record, a recycled
  unrelated PID, and a stable handle to that replacement must never enter the
  drain set.
- Compiled-binary e2e tests prove that default teardown drains a live `setsid()`
  descendant, while `--pgroup-only` preserves the process-group-only escape
  hatch; fixtures clean up every process on failure.
- Native-platform verification proves the documented identity and individual
  signaling path on every advertised descendant-drain platform: Linux acquires
  a stable process reference before reading the PPID, start-time, and PGID
  record that establishes ancestry, then uses that reference or a pidfd proven
  bound to the same record for liveness and signaling. A later `pidfd_open` of
  an unbound numeric snapshot cannot satisfy this floor. Darwin (macOS)
  captures start time and immediately re-reads `(pid, start_time)` before
  `kill(pid, signal)`; its validation-to-`kill` TOCTOU is documented as a
  native limit, not claimed away. The retained kqueue BSDs perform group-only
  teardown and never claim individual descendant signaling. An unsupported
  path is a fail-closed documentation or implementation block, not a silent
  fallback.
- Diagnostics tests prove incomplete discovery still drains the original group,
  reports the limitation, and never broadens individual signal targets.

## Oracle

The compiled-binary harness exercises the production Janitor executable and
its native process semantics, so test-only behavior cannot satisfy it. A fresh
rl review independently judges the resulting diff against this law; neither
oracle is the implementing agent's self-assessment.

## Never

- Never knowingly signal an individual target whose required platform identity
  verification is mismatched, unavailable, or stale. On Linux, a stable handle
  acquired after an unbound numeric process-table record is insufficient: the
  handle must be linked to the exact record that proved ancestry, and a
  replacement after PID recycling is rejected. Darwin (macOS) must immediately
  re-read `(pid, start_time)` before `kill(pid, signal)` and must document the
  unavoidable validation-to-`kill` TOCTOU. The retained kqueue BSDs never
  signal individual descendants at all.
- Never signal a process group other than the original group Janitor created.
- Never let incomplete discovery block original-group cleanup, silently claim
  complete coverage, or broaden the signal set by guesswork.
- Never let an escaped descendant's cleanup replace the direct child's exit
  status contract.

## Decisions

- Signal safety outranks cleanup breadth; an unverifiable descendant is skipped
  and diagnosed.
- Janitor snapshots the live PPID-linked closure before the first TERM; only the
  original child group is signaled wholesale.
- Descendant drain is the default. `--pgroup-only` is the explicit escape hatch.
- Linux uses pidfds as stable individual signal handles. Darwin (macOS)
  captures start time and immediately re-reads `(pid, start_time)` before each
  `kill(pid, signal)`; that validation narrows but cannot atomically eliminate
  the validation-to-`kill` TOCTOU. The retained kqueue BSDs are group-only.
- Lifetime ownership is excluded: processes already reparented before the
  snapshot, continuous fork tracking, cgroups, and registries remain out of
  scope.
- Adversarial evasion is excluded (ratified 2026-07-17): a supervised process
  that actively re-enters the zombie-led original group via `setpgid` after an
  empty membership observation and forks inside the teardown window is outside
  the threat model; Janitor supervises cooperative-but-messy processes.

## Boundary

- Publishing, pushing, opening a pull request, merging, tagging, releasing,
  deploying, and live-system mutation remain human-only.
- Live secrets, biometric approval, unsupported native semantics, and any
  decision to weaken signal-safety floors require human direction.
