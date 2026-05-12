---
description: Deep-dive the current project and write durable context files for future Claude sessions
allowed-tools: Bash, Read, Glob, Grep, Write, Edit, Agent, WebFetch, Skill, TodoWrite
---

Perform a comprehensive deep-dive on the current project. The user has explicitly invoked this — burn the tokens, take the time, capture every minute detail. Future Claude sessions will Read the artifacts you produce.

# Goal

Write durable context files into `<project>/.claude/context/`. Do **not** touch the project's `CLAUDE.md` or the user's global `CLAUDE.md`. After you finish, tell the user the single line they can add to their project `CLAUDE.md` if they want the context auto-loaded: `@.claude/context/index.md`.

# Output files (write all six for a non-trivial project, even if some sections are sparse)

For a genuinely tiny project (a single-file script, a config-only repo), don't pad six files — collapse to just `index.md` + `workflows.md` and say so in the report. "All six" is the default for anything with real structure, not a hard floor.

| Path                              | Contents                                                                                                                                        |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `.claude/context/index.md`        | One-paragraph project summary + table of contents linking to the other five files. ~150 words.                                                  |
| `.claude/context/architecture.md` | System layering, data flow, key abstractions, module boundaries, where state lives, how external services are integrated.                       |
| `.claude/context/conventions.md`  | Naming, file structure, idioms, lint rules, formatting, recurring patterns. Cite real examples with `path:line`.                                |
| `.claude/context/gotchas.md`      | Surprises, footguns, "looks wrong but is right" cases, known sharp edges. Mine from comments, commit messages, code that contradicts intuition. |
| `.claude/context/workflows.md`    | Exact commands for: install, build, dev, test, lint, typecheck, deploy. Mirror CI exactly. Note required env vars / credentials.                |
| `.claude/context/entry-points.md` | Where execution starts. Main/index/cli/server files. Route registrations. Background workers. Cron jobs. With `path:line` references.           |

# Procedure

## 1. Survey (do this first, single-threaded)

```bash
pwd                                       # confirm project root
ls -la                                    # top-level
git rev-parse --show-toplevel 2>/dev/null # confirm git repo
git log --oneline -30 2>/dev/null         # recent activity
```

Then `Read` the root-level config files that exist: `package.json`, `pnpm-workspace.yaml`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Gemfile`, `composer.json`, `Makefile`, `justfile`, `Taskfile.yml`, `tsconfig.json`, `.editorconfig`, `.eslintrc*`, `.prettierrc*`, `ruff.toml`, `biome.json`, `.github/workflows/*.yml`, existing `CLAUDE.md`, existing `README.md`, existing `CONTRIBUTING.md`, existing `AGENTS.md`. Skip what doesn't exist.

Glob top-level directories: `Glob "*/"`.

This is enough to identify project type, build/test commands, and area boundaries.

## 2. Dispatch parallel Explore agents (this is the expensive step — do it in parallel)

Use the `superpowers:dispatching-parallel-agents` skill. Dispatch ONE Explore agent per major area discovered in step 1. Common areas:

- Frontend (src/, app/, components/, pages/)
- Backend / API (api/, server/, routes/, handlers/)
- Database / migrations (db/, migrations/, prisma/, alembic/)
- Tests (test/, tests/, **tests**/, spec/, e2e/)
- Build / tooling (scripts/, build/, .github/, deploy/)
- Documentation (docs/, .github/ISSUE_TEMPLATE/, etc.)
- Configuration (config/, env/, infra/)

Each agent prompt should include:

- The specific directory it owns
- The deliverable: a concise report with — purpose of each subdirectory, the 5–10 most important files (with `path:line` references to key symbols), recurring patterns observed, conventions specific to this area, any surprises
- Instruction to actually `Read` files, not just `Glob` them — they need real understanding
- Cap on report length (~400 words per agent) so synthesis stays manageable

For small projects (one or two top-level dirs), skip parallelization and do it serially.

## 3. Trace at least one critical end-to-end path

After agent reports come back, pick the single most important user-facing flow (e.g., for a web app: HTTP request → route → handler → DB → response; for a CLI: argv parse → command → business logic → output; for a library: public API → core → side effects). Trace it file-by-file. Note layering, error handling style, where transactions/locks happen, where logging happens. This goes into `architecture.md`.

## 4. Read CI (the authoritative "what passes")

If `.github/workflows/`, `.gitlab-ci.yml`, `circle.yml`, or similar exists, read the actual CI commands. They are the gold standard for `workflows.md` — match them exactly.

## 5. Mine for gotchas

Run `Grep` for these patterns to surface non-obvious things:

```bash
rg -n "TODO|FIXME|HACK|XXX|WORKAROUND|NOTE:" -g '*.{ts,tsx,js,jsx,py,go,rs,rb,php,java,kt,swift}' .
git log --oneline -100 --grep='fix\|bug\|hotfix\|revert' -i
```

(Use `rg` — `grep -r --include="*.{a,b}"` does not expand brace globs on BSD/macOS grep and would silently match nothing. `rg` is in the Brewfile; if a project is somehow without it, fall back to multiple `grep --include=` flags or `find -name`.)

Recent reverts and "fix" commits often point at subtle issues worth recording.

## 6. Write the six files

Style for all files:

- Technical density. No fluff, no marketing voice.
- Use `path:line` for every code reference so the user can jump.
- Prefer tables and short bullets over paragraphs.
- Each file: ~300–800 words. Sparse sections are fine — write "(none observed)" rather than padding.
- `index.md` includes a one-line summary per other file and a `Last generated: <date>` footer.

Create `.claude/` and `.claude/context/` directories if they don't exist. Use `Write` for each file (these are new artifacts — no need to Read first unless overwriting).

## 7. Report

After all writes complete, print to chat:

- A 5-line top-level summary of what this project IS (the kind of summary a senior engineer would give in a hallway).
- The list of files written with absolute paths.
- The exact line to add to project `CLAUDE.md` if the user wants auto-loading: `@.claude/context/index.md`.
- Any open questions you couldn't resolve (e.g., "couldn't determine deploy command — no CI workflow found, no docs mention it").

# Important constraints

- Do **not** edit the project's `CLAUDE.md` or any global Claude config file.
- Do **not** commit the new files — let the user decide whether to track them in git.
- If `.claude/context/` already contains files, ask the user whether to overwrite before proceeding.
- If the project is huge (>5000 files), narrow scope to the top-level source directories by default and tell the user what you skipped.
- Use the `grounding-claims` skill's discipline — every claim about the project should be backed by a file you actually Read (or a command you actually ran). Don't speculate.
