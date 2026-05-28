---
name: dive
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
| `.claude/context/conventions.md`  | **Lint-enforceable surface AND non-trivial code style** — see expansion below. Cite real examples with `path:line`.                             |
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
- **Code-style evidence** (mandatory): name 3–5 real source files the agent Read in full, and for each note one concrete observation about function shape, error-handling style, comment density, or repetition-vs-reuse with `path:line`. This is raw material for step 6's code-style pass — the synthesis happens later, the agent's job is to surface examples.
- Instruction to actually `Read` files, not just `Glob` them — they need real understanding
- Cap on report length (~500 words per agent) so synthesis stays manageable

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

## 6. Code-style pass (REQUIRED — do NOT skip even if a linter exists)

A linter enforces formatting; it cannot tell future Claude how this team writes code. This step is
about the abstract, sentimental, taste-driven style that survives `prettier --check` and still
makes a PR feel wrong. **Do this before writing conventions.md, not after.**

Open 6–10 real source files spanning the languages in the repo (handlers, library helpers, components,
shell, infra modules). Read them top-to-bottom. Then characterize each axis below with at least one
`path:line` citation and a one-line claim. If a claim has counter-examples, note them — don't lie.

Required axes:

1. **Naming**
   - Variable / function / type / constant cases for each language. Not just "camelCase" — also:
     when do SCREAMING_SNAKE constants appear (sentinel? config? table name?). Are booleans
     `is*`/`has*`-prefixed? Do module-scope singletons get a different convention from locals?
   - Handler / route / public-export naming (`<noun>Handler`? `*Service`? `use*`?).
   - String-literal discriminated unions (`snake_case` vs `kebab-case` vs `PascalCase` enum values).

2. **Function shape**
   - Default to arrow functions or named `function` declarations? Does it depend on
     exported-vs-internal?
   - Are public functions annotated with return types when inference would work?
   - Average function length — short single-purpose, or longer procedural?
   - Where do guards/early-returns happen, and what shape do they take?

3. **Module layout**
   - Conventional section order inside a file (imports → constants → helpers → exports? something
     else?). Find at least 2 examples that match.
   - Import ordering (alphabetical? framework-first? grouped by depth?).
   - Where do types live — inline, sibling `types.ts`, or co-located with the function that returns
     them?

4. **Comments**
   - **Comment density** — count comments in a typical 100-line file. Zero? Sparse? Every section?
   - **What kinds of comments exist?** Prefixed (`NOTE:`, `WARNING:`, `TODO:`)? JSDoc/docstrings?
     Inline? File headers?
   - **What WHY's get captured?** Footguns, invariants, historical context, intentional crashes,
     workarounds. Cite the strongest example.
   - What's notably absent (e.g., "no descriptive comments restating the code" is a real finding).

5. **Repetition vs reuse**
   - When the same shape appears 2–3 times, does the author extract a helper or inline-duplicate?
     Read a real example each way and cite both.
   - Are there "almost-but-not-quite" duplicates that suggest the author values clarity over DRY?
     (e.g., two nearly-identical AWS SDK call sites kept separate because their parameter lists
     differ in 1 field).
   - Single-use constants — do they live in the consuming file or get extracted to a shared
     module? (This often contradicts what a linter would push for.)

6. **Error handling**
   - Specific exception types, string matching, or generic catch-all?
   - Throw-to-retry vs explicit try/catch with recovery — pick the dominant pattern with a citation.
   - Return shape for HTTP-style handlers (`Response` object? plain object? framework helper?).
   - Logging style: structured? `console.error`? observability lib? What does the team consider
     "enough" context in a log line?

7. **Domain-specific patterns** (cover whichever applies)
   - For UI code: variant systems (`tailwind-variants`, `cva`), slot vs snippet, prop spreading,
     where state lives (component-local vs context vs store).
   - For infra/IaC: stage gating patterns, secret-naming conventions, when resources are
     conditionally created.
   - For CLI scripts: dispatcher pattern, help-by-default vs run-all, argument validation, status
     output, ANSI/color usage, confirmation prompts for destructive ops.
   - For library code: builder/fluent APIs, factory functions, plugin contracts.

8. **What the linter cannot enforce but the team clearly cares about**
   - Look for the strongest signal: a recent `fix(convention)` / `cleanup(style)` commit, a NOTE
     comment scolding a prior PR, a wrapper around a stdlib call that has no functional purpose.
     These reveal the "taste" rules.

Output of this step lives in `conventions.md` under a dedicated **"Code style — \<lang>"** section
per language with sub-headings for the axes above. Cite `path:line` ruthlessly. Don't paraphrase what
a linter could check — describe what a senior engineer on this team would catch in code review.

If a style guide exists at `style/*`, `docs/style*`, `CONTRIBUTING.md`, or `AGENTS.md`, Read it and
treat it as **prescribed style** — then verify against real code whether the prescription is
actually followed and note any drift.

## 7. Write the six files

Style for all files:

- Technical density. No fluff, no marketing voice.
- Use `path:line` for every code reference so the user can jump.
- Prefer tables and short bullets over paragraphs.
- Each file: ~300–800 words; `conventions.md` may run longer (~1500–2500) because the code-style
  pass produces dense, citation-heavy content. Sparse sections are fine — write "(none observed)"
  rather than padding.
- `index.md` includes a one-line summary per other file and a `Last generated: <date>` footer.
- `conventions.md` MUST contain the code-style pass output from step 6 — not just lint rules.

Create `.claude/` and `.claude/context/` directories if they don't exist. Use `Write` for each file (these are new artifacts — no need to Read first unless overwriting).

## 8. Report

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
- Use the `ground` skill's discipline — every claim about the project should be backed by a file you actually Read (or a command you actually ran). Don't speculate.
