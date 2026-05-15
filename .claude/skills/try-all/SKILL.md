---
name: try-all
description: Use when about to ask the user to choose between 2+ substantive implementation approaches — architecture, algorithm, data structure, library, or design pattern choices where the answer benefits from a side-by-side comparison of real implementations — OR when undecided between competing hypotheses, interpretations of an ambiguous request, or research directions where pursuing each branch would settle which is right. Symptoms include drafting a message like "Option A or Option B — which do you prefer?", listing trade-offs in the abstract, recommending a path while uncertain whether an alternative would be cleaner, or picking the likelier of two explanations and moving on. Do NOT use for trivial choices (variable names, formatting, single-line refactors, choices the user already specified). For non-code forks (competing explanations, interpretations, research directions), the comparison happens via investigation rather than worktrees — see `dig`.
---

# Trying Everything

## Overview

Instead of asking the user to pick between approaches in the abstract, implement each approach in its own git worktree using a faithful copy of the current working tree, then report results so the user can compare real diffs. Multiple worktrees, parallel subagents, real code, real test runs.

**Core principle:** Comparison beats discussion. A working diff is worth a thousand bullet-point trade-offs.

**REQUIRED SUB-SKILL:** Use `superpowers:using-git-worktrees` for worktree creation.
**REQUIRED SUB-SKILL:** Use `superpowers:dispatching-parallel-agents` for the parallel implementation step.
**RELATED:** When a worktree has no test command, each subagent improvises an exercise per `confirm` — a comparison is only meaningful if both sides actually ran.
**RELATED:** This skill is for competing *code implementations*. When the fork is between competing explanations, interpretations, or research directions — not code — pursue every branch by investigation, not worktrees: `dig`.

## When to Use

**Use when:**

- You identified 2–4 meaningfully different implementation approaches.
- Each approach would touch real code (not just a rename).
- The user hasn't pre-committed to one approach.
- The approaches can be validated quickly — a test command, a build, or an improvisable real exercise (per `confirm`). If you genuinely can't exercise _any_ of them, fall back to a single quick prototype + one round-trip with the user instead of N un-exercised worktrees.

**Do NOT use when:**

- The user named the approach in their prompt — just do it.
- The "choice" is cosmetic (naming, formatting, file location).
- One approach is obviously wrong — discard it, don't worktree it.
- You'd produce more than 4 worktrees — cap at 4. (Beyond ~4 parallel implementations the review burden and context/cost outweigh the benefit; the user can't meaningfully compare 6 diffs at once anyway.) Pick the 4 most distinct, say which you cut and why.

## Procedure

1. **Announce, then proceed — but match the audience.** State the approaches you'll try in 1 line each. If the user is interactive, proceed unless they interject in the same turn. If the session is async (they're not there to interject) **or** the scope is large (4 worktrees, long-running implementations), state the plan and wait for a go-ahead — spawning several worktrees + parallel subagents isn't free and worktrees linger until manually removed.

2. **Snapshot the working tree without touching it.** Original branch's working tree must remain unchanged.

   ```bash
   SCRATCH="${CLAUDE_JOB_DIR:-$(mktemp -d)}"            # stable across the steps below
   STASH=$(git stash create)                            # builds stash commit, working tree untouched
   git ls-files --others --exclude-standard > "$SCRATCH/untracked.list"
   ```

   Capture `$SCRATCH`, `$STASH`, and the list path **once** and pass them explicitly to later steps / subagents — don't re-derive a path with `$$` (each subagent runs in a different shell with a different PID, so `$$` won't match). If `$STASH` is empty there are no tracked changes to copy — that's fine, skip the apply step below.

3. **Create one worktree per approach** via `superpowers:using-git-worktrees`. Name as `<repo>-try-<slug>` where slug is short kebab-case (e.g. `myapp-try-token-bucket`, `myapp-try-leaky-bucket`).

4. **Restore working state into each worktree:**

   ```bash
   cd <worktree>
   [ -n "$STASH" ] && git stash apply "$STASH"
   rsync -a --files-from="$SCRATCH/untracked.list" <repo-root>/ <worktree>/
   ```

   (On Linux/GNU coreutils, `xargs -I{} cp --parents {} <worktree>/ < "$SCRATCH/untracked.list"` also works — but `cp --parents` is unavailable on macOS, so `rsync` is the portable default.)

5. **Bring in gitignored runtime deps the tests need.** `git ls-files --others --exclude-standard` deliberately _excludes_ gitignored files, and `git worktree add` never copies them — so a fresh worktree has no `.env`, no `node_modules`, no `.venv`, no build cache. If the test command needs any of these, the subagent's run will fail for a reason that has nothing to do with the approach. Before dispatching, give each worktree what it needs:

   ```bash
   cd <worktree>
   ln -s <repo-root>/node_modules node_modules        # symlink heavy dep dirs (node_modules, .venv, vendor/)
   cp <repo-root>/.env .env                            # copy small secret/config files
   # ...or run the project's bootstrap (npm ci, poetry install) if a symlink would be wrong
   ```

   If you can't reconstruct the runtime env in a worktree, say so in the report — a comparison whose tests couldn't run is still useful (you have the diffs) but flag it as un-exercised.

6. **Dispatch one subagent per worktree** via `superpowers:dispatching-parallel-agents`. Each agent receives:
   - Its worktree path
   - **Only its assigned approach** (never the alternative list — prevents cross-contamination)
   - Instruction to implement; then **verify it** — run the project's test command if one exists, otherwise improvise a real exercise per `confirm` (a "comparison" where neither side was actually run is just two untested diffs); then return: files changed, test/exercise result, one-line trade-off note
   - Instruction that **"this approach turns out to be infeasible / its tests fail and I can't fix them" is a valid result to return** — report it, don't silently drop the row, don't retry forever, don't fake green. An approach that doesn't work is a finding the user wants.

7. **Collect and report.** Markdown table — keep every row, including failed/infeasible ones (mark the result cell ❌ or "infeasible" and one line on why):

   | Approach     | Worktree                    | Result                                                             | Files | Trade-off                        |
   | ------------ | --------------------------- | ------------------------------------------------------------------ | ----- | -------------------------------- |
   | token-bucket | `../myapp-try-token-bucket` | ✅                                                                 | 3     | smoother under burst, more state |
   | leaky-bucket | `../myapp-try-leaky-bucket` | ❌ tests fail — needs a monotonic clock the runtime doesn't expose | 2     | —                                |

   If a worktree couldn't run its tests for environment reasons (missing gitignored dep you couldn't reconstruct), say "diff only, un-exercised" rather than ✅.

8. **Stop.** Do not merge. The user picks. If they choose one, merge from that worktree; if not, the worktree paths give them everything they need to keep exploring.

## Red Flags — STOP and invoke this skill instead

- About to write: "Should we use A or B?"
- About to write: "There are a few ways we could do this..."
- About to recommend an approach with a "but you might prefer..." hedge
- Drafting a comparison table of approaches in chat instead of in code

All of these mean: pick the top 2–4 approaches, worktree them.

## Cleanup

Worktrees are NOT auto-removed — the user inspects them on their own clock. When done, the user runs `git worktree remove ../<name>` per worktree, or uses `commit-commands:clean_gone` if a worktree's branch has been merged and pruned.

## Common Mistakes

| Mistake                                                            | Fix                                                                                                                                      |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Using `git stash push` instead of `git stash create`               | `push` empties your working tree until `pop`. `create` returns a hash and never touches it.                                              |
| Forgetting untracked files                                         | `git stash` (any variant) by default ignores them. The `git ls-files --others --exclude-standard` step is mandatory.                     |
| Telling each agent about all approaches                            | Agents cross-contaminate. Each agent gets only its own approach.                                                                         |
| Worktree's tests fail because `.env` / `node_modules` aren't there | Those are gitignored — `git worktree add` and the untracked-files copy both skip them. Symlink/copy them in before dispatching (step 5). |
| Dropping or hiding an approach that didn't work                    | "Approach X is infeasible" is a result. Keep the row, mark it ❌, one line on why.                                                       |
| Trying every variable name in a worktree                           | Cosmetic choices are out of scope. One round-trip with the user is faster.                                                               |
| Merging the "winner" without asking                                | The user picks. This skill stops at the report.                                                                                          |

## Example

User: "Implement debounce for the search input. Closure-based or class-based?"

Without this skill: Claude asks "which would you prefer?" → user has to imagine both → suboptimal choice based on hunch.

With this skill: Claude announces "Trying both: `closure` worktree and `class` worktree." → snapshots working tree → spawns two worktrees → dispatches two subagents → reports a table showing closure variant is 8 lines vs class variant 23 lines, both pass tests. User picks closure in seconds based on the actual diffs.
