> Law doc for Janitor process supervision, present-tense, no narrated history — git is the changelog. Amend Decisions and Boundary only with human confirmation; dated working memory lives outside this file.

## Bar

Janitor supervision is shippable when teardown drains the live owned process
set without risking a signal to an unrelated process.

## Dimensions

- Ownership proof and PID-reuse safety.
- Complete, bounded drain behavior and direct-child status fidelity.
- Diagnostic honesty when native discovery cannot prove a target.
- Native-platform verification of the promised behavior.

## Floors

- Process-tree unit tests prove PPID closure, unrelated-process exclusion,
  identity mismatch/PID reuse rejection, and bounded-resweep anchoring.
- Compiled-binary e2e tests prove that default teardown drains a live `setsid()`
  descendant, while `--pgroup-only` preserves the process-group-only escape
  hatch; fixtures clean up every process on failure.
- Native-platform verification proves the documented identity and individual
  signaling path on every advertised descendant-drain platform. An unsupported
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

- Never signal a process whose captured identity no longer matches; PID reuse
  and unrelated-process signaling are hard failures.
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
- Linux uses pidfds; macOS/BSD use the strongest available start identity and
  immediate revalidation, with claims calibrated to actual enforcement.
- Lifetime ownership is excluded: processes already reparented before the
  snapshot, continuous fork tracking, cgroups, and registries remain out of
  scope.

## Boundary

- Publishing, pushing, opening a pull request, merging, tagging, releasing,
  deploying, and live-system mutation remain human-only.
- Live secrets, biometric approval, unsupported native semantics, and any
  decision to weaken signal-safety floors require human direction.
