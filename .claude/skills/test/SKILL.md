---
name: test
description: Use after implementing any code or config change in a project, before claiming the work complete. Especially for projects with no documented test setup — no test script in package.json/Makefile/pyproject.toml/Cargo.toml, no testing section in README/CONTRIBUTING/AGENTS.md. Symptoms — about to claim work complete without running anything, about to commit code that hasn't been exercised, project has no apparent test command. Skip for pure documentation/comment edits.
---

# Testing Implementations

## Overview

Every code or config change must be **exercised against reality** before being declared complete. If the project has a test setup, use it. If not, improvise a real exercise that proves the change works. Fixes that fail tests are not done — keep iterating until they pass, unless the situation is genuinely impossible.

**Core principle:** A change you haven't run is a change that doesn't work yet.

**Report provenance in one line, not a paragraph.** State what you exercised and what you observed — "verified X by doing Y, saw Z" — then stop. No diff recap, no multi-sentence summary; if the user's style is terse, the receipts are one sentence.

## Procedure

### Step 1 — Discover what the project already provides

Check in order, stop at first hit:

| Location                                      | What to look for                                                     |
| --------------------------------------------- | -------------------------------------------------------------------- |
| `package.json`                                | `scripts.test`, `scripts.build`, `scripts.lint`, `scripts.typecheck` |
| `pyproject.toml` / `setup.py` / `tox.ini`     | `pytest`, `nox`, `tox` configuration                                 |
| `Cargo.toml`                                  | implies `cargo test`, `cargo check`, `cargo clippy`                  |
| `go.mod`                                      | implies `go test ./...`, `go vet`                                    |
| `Makefile` / `justfile` / `Taskfile.yml`      | named targets like `test`, `check`, `ci`                             |
| `.github/workflows/*.yml`                     | CI commands are authoritative for "what tests should pass"           |
| `CONTRIBUTING.md` / `AGENTS.md` / `README.md` | hand-written test instructions, manual QA steps                      |

Run whatever you find. CI workflow commands are the gold standard — if CI runs `npm run typecheck && npm test && npm run lint`, run all three locally.

### Step 2 — If nothing exists, improvise

Pick the pattern matching the project type. Always run a **real** exercise, not just `--help` or a syntax check.

| Project type                                     | Improvised exercise                                                                                                                                                                                                                                                           |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **HTTP service / API**                           | Start the dev server in the background (Claude Code: `run_in_background: true`; otherwise `cmd &` or a separate pane). Wait for it to be ready (loop curl or check the port). Hit affected endpoints; assert status + body shape. Tail logs for errors.                       |
| **CLI tool**                                     | Build if needed. Run with realistic inputs covering the change. Check exit code, stdout, stderr. If your change added a flag, exercise it directly.                                                                                                                           |
| **Library (npm/pip/cargo)**                      | `mktemp -d`, install the local package (`npm install <path>`, `pip install -e <path>`, `cargo add --path <path>`). Write a minimal consumer that exercises the new API. Run it.                                                                                               |
| **Frontend component / page**                    | Start the dev server. Drive a browser (Claude Code: `playwright` MCP tool; otherwise headless Playwright/Puppeteer or manual) — navigate, snapshot the DOM, click the affected element, screenshot. Check browser console messages for errors.                                |
| **Config (tmux, nvim, yabai, hammerspoon, zsh)** | Reload the config (`tmux source-file`, `yabai --restart-service`, `:source $MYVIMRC`, etc.). Trigger the behavior the change affects. Inspect logs (`tail ~/.hammerspoon/console.log`, etc.).                                                                                 |
| **Shell script / dotfile**                       | Source it in a subshell to catch syntax errors. Invoke the affected function/alias with realistic input.                                                                                                                                                                      |
| **Database migration**                           | Apply to a dev/local DB. Query to confirm schema. Reverse if reversible to confirm symmetry.                                                                                                                                                                                  |
| **Pure logic / algorithm**                       | Write 3–5 assertion lines in a tmp file, run them. Cover happy path + at least one edge case (empty input, boundary value). If you already wrote a reproducer for this exact code while grounding a claim about it (see `ground`), that run counts — don't redo it. |

If the change touches a UI, also run a build/typecheck — visual verification doesn't catch type errors.

### Step 2.5 — Establish the baseline if you didn't write the test setup

Before treating a failing project test as _your_ bug: run it (or check CI) on the unmodified tree first. If it was already red for an unrelated reason, that's a pre-existing failure — don't chase it, don't "fix" it to force green, and don't let it block reporting your change. Note it to the user ("`npm test` is red, but on a pre-existing `mul.js` assertion unrelated to this change") and move on. Only failures your change introduced or touches are yours to fix in this turn.

### Step 3 — On failure, loop

Failure is part of the workflow, not the end of it. Diagnose root cause, fix, re-test. Keep going.

**Don't:**

- Stop after one failure and ask the user
- Retry the same failing test without changing anything (definition of insanity)
- Mark something `xfail` / skip the test to make red go green
- Add a try/except around the test to swallow the error
- Claim "tests pass" when only _some_ tests pass

**Do:**

- Read the actual error output carefully — what does it say
- Form a specific hypothesis about root cause before each fix
- After every fix, re-run the full relevant test set
- If many _genuinely distinct_ fix attempts (not five trivial variations) all hit the same failure, suspect an environmental root cause you can't resolve alone (see "Impossible" below) — but be honest about whether the attempts were actually distinct

## Impossible vs. fixable

The only valid exit before tests pass is "genuinely impossible." Be honest with yourself — most "impossible" cases are actually "I haven't tried hard enough yet."

| Signal                                                                                                                                         | Verdict                                                                                                                       |
| ---------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Test needs `STRIPE_LIVE_KEY` not in env, user wouldn't want it set                                                                             | Impossible — report to user                                                                                                   |
| Test requires connected USB device, hardware not present                                                                                       | Impossible — report                                                                                                           |
| External API confirmed unreachable (try twice with network diagnostics)                                                                        | Impossible if your change isn't supposed to be offline-tolerant                                                               |
| Same exact error after several genuinely-different fix attempts, root cause is a package-version conflict you can't resolve without user input | Impossible — report with full diagnostic                                                                                      |
| Compile error → still compile error                                                                                                            | Fixable. Read the error, fix the code.                                                                                        |
| Test passes locally but fails on a flaky timing assertion                                                                                      | Fixable. Find the race condition, use `condition-based-waiting` patterns.                                                     |
| Test asserts wrong thing                                                                                                                       | Fixable. Either the code is wrong (fix code) or the test is wrong (fix test, but verify with the user if it's existing test). |
| "I don't know how to fix this"                                                                                                                 | Not impossible. Read more code, check git blame, search for similar fixes in commit history, look up the error.               |

**When stopping for genuinely impossible:** report in this shape — what you tried (list of fix attempts), what the persistent error is, what you believe the root cause is, what the user needs to do (install X, grant Y permission, provide Z credential). Never silently abandon.

## Red Flags — STOP and run a real test

- About to write "the change should now..." without having executed it
- About to commit code that has only been read, not run
- About to claim "tests pass" but only ran `npm install`
- Saw a test fail and added `.skip()` instead of fixing
- "It compiles" → not the same as "it works"
- About to mark task complete because the diff looks reasonable

## Common Mistakes

| Mistake                                                          | Fix                                                                                        |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Running `--help` and calling it a test                           | `--help` exits early without exercising any logic. Run real inputs.                        |
| Mock-testing instead of integration-testing                      | Mocks confirm your model of the world, not the world itself. Test against real (dev) deps. |
| Skipping improvisation because "this project doesn't have tests" | That's exactly when improvisation is required.                                             |
| Bailing on first failure                                         | Failures are diagnostic info, not stopping conditions.                                     |
| Hand-waving "looks good to me" as verification                   | Not verification. Run it.                                                                  |
| Silently giving up after many failures                           | Always report impossible explicitly — never just stop.                                     |

## Example

**Scenario:** You added a `--dry-run` flag to a CLI tool in a project with no `npm test` script and no testing docs.

**Wrong:** "I've added `--dry-run`. Should be working now." (Untested.)

**Right:**

```bash
# Step 1: discover test setup
cat package.json | jq '.scripts'   # → only "start" and "build", no test
# Step 2: improvise
npm run build
./dist/cli.js process input.txt --dry-run
# → confirms output starts with "[dry-run]" and no files were modified
./dist/cli.js process input.txt
# → confirms files ARE modified in the non-dry-run path (regression check)
./dist/cli.js process --dry-run    # missing required arg
# → confirms error handling still works
```

Then report it in **one line**, not a paragraph (respect the user's terseness preferences): _"Added `--dry-run` — verified: prefixes output `[dry-run]` and writes no files; normal path still writes; bad-args still errors; build passes. No test suite; improvised 3 real invocations."_

The user gets the change + the receipts, not a recap of the diff.
