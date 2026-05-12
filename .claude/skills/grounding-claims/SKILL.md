---
name: grounding-claims
description: Use before stating ANY factual claim, technical answer, advice, recommendation, or code in a final answer — code task or plain Q&A, including side-questions in a multi-part message. Symptoms — about to answer "does X support Y / which version / how does Z behave" from memory, give advice resting on an unchecked fact, recommend code you haven't run, cite a library option or signature from memory, claim/deny a config key or flag exists without seeing the schema/docs, describe what a function does without Reading it, state a "latest" version or release date, hedge ("where did you see that?") instead of looking it up, or think "I already verified something this turn". Skip for clearly-framed speculation ("I think... let me check") or universally stable surface (basic git, POSIX, long-stable built-ins).
---

# Grounding Claims

## Overview

Any factual claim, technical answer, advice, recommendation, or code you put in a final answer must be **doubly verified**: against a primary source (reference check) AND, where something is runnable, by actually running it (empirical check). This applies to plain Q&A and advice, not just code changes — "does Vite 5 need Node 18?", "is this flag still supported?", "which approach is faster?" are all in scope. Memory does not count as a source. Documentation can be wrong or out of date — when there's something to run, only execution closes the loop.

**Core principle:** If you haven't run it, you don't know if it works.

**Grounding is per-claim, not per-turn.** Verifying one thing earlier in a response does NOT cover a _different_ claim later in the same response. Each verifiable assertion gets its own check — including the side-question buried as item (b) in a multi-part user message. The "main" task getting rigor is not a substitute for the throwaway sub-question getting it too.

**Hedging is not a substitute for verification.** "I don't recognize that — where did you see it?" / "I'm pretty sure X, but..." / labeling something "inferred" — none of these discharge the grounding obligation when a primary source is one `WebFetch` away. Hedge _after_ the lookup comes back inconclusive, never _instead of_ it. A confident-sounding hedge wrapped around a false claim is still a false claim shipped to the user.

## The Two Checks

| Check         | What it catches                                                                           | How                                                                                                 |
| ------------- | ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| **Reference** | Confidently wrong API surface from training-data memory                                   | `WebFetch` official docs, `Read`/`Grep` actual source, `npm view`/`pip show` for installed versions |
| **Empirical** | Docs that are wrong, version-skew between docs and installed code, edge cases not in docs | Minimal reproducer in `mktemp -d`, install deps, execute, observe output                            |

Both required. Reference alone gets fooled by stale docs. Empirical alone gets fooled by "it worked by accident with wrong assumptions."

## Procedure

1. **Identify the verifiable claim.** Examples: "Zod's `.strict()` rejects unknown keys", "tmux 3.4 supports option X", "this codebase's `auth.ts` exports `verifyToken`". Vague claims like "this is a clean approach" aren't verifiable — phrase them as recommendations, not facts.

2. **Reference check first** (cheapest):
   - Library/API → `WebFetch <official-docs-url> "<specific question>"`
   - Installed version → `npm view <pkg> version`, `pip show <pkg>`, `<binary> --version`
   - Source claims → `Read` the file or `Grep` for the symbol
   - General facts (dates, releases, people) → `WebFetch` or `WebSearch`
   - Knowledge cutoff is Jan 2026 — anything "latest" demands a fresh lookup.

3. **Empirical check** (the part that closes the loop):

   ```bash
   WORK=$(mktemp -d -t claude-verify-XXXXXX) && cd "$WORK"
   # Set up the smallest possible environment that can run the claim
   npm init -y >/dev/null && npm install <pkg>   # or pip install, cargo add, go mod init, etc.
   # Write a minimal reproducer
   cat > example.ts <<'EOF'
   // smallest possible code that demonstrates the claim
   EOF
   # Run it and observe
   npx tsx example.ts   # or node, python, bun, deno, cargo run, etc.
   ```

   If output matches the claim → claim verified, cite the workspace path and observed output in your answer.
   If output contradicts the claim → claim is wrong. Adjust the claim or retract it. Never present an unverified claim as fact.

4. **Report with provenance.** In your final answer, state what was verified and how. Example: "Confirmed against the [Zod v3.23 docs](url) and verified locally — `.strict().parse({extra: 1})` throws `ZodError`. Workspace: `/tmp/claude-verify-XXXXXX/`."

## When to Skip

- Speculation framed clearly as such: "I think this works, but let me check before recommending."
- Universally stable surface: `cd`, `ls`, `git status`, `Array.prototype.map`, basic SQL `SELECT`. If it hasn't changed in 10+ years, no verification.
- The user already stated the claim as a premise in their prompt.
- Pure judgment calls ("this naming is clearer") — no fact to verify.

**NOT valid skip reasons** (these are the traps): "it's only one of three sub-answers", "the conversation has momentum", "I already did my grounding for this turn", "I'll just ask the user where they saw it", "I'll label it as inferred so it's fine", "the user probably typo'd it / it's probably not a real thing", "this is just a quick question, not a code task" (the skill is not code-only — a wrong fact in casual advice is still a wrong fact the user will act on). If there's a verifiable claim and a reachable source, the claim gets checked — full stop.

## Red Flags — STOP and verify

- About to type a function signature from memory
- About to write "the latest version supports..."
- About to claim a config option exists without having seen it in a schema or docs page
- About to describe what an internal file does without having Read it
- About to produce a code block that you haven't run
- About to say a config key / flag / option "isn't a real thing" or "doesn't exist" without having opened the schema or docs page
- A verifiable claim is buried in a multi-part answer and you're tempted to skim past it because the "main" task is done
- About to hedge ("where'd you see that?", "I don't recognize it") instead of doing the 30-second lookup that would settle it
- "It's just a quick question / casual advice, not a coding task" → grounding is not code-only. A wrong fact in a one-line answer is still wrong.
- "I already verified something this turn" → that was a different claim. This one needs its own check.
- "I'm pretty sure..." → not sure enough. Verify.

## Common Mistakes

| Mistake                                                      | Fix                                                                                                           |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| Reference check but skip empirical                           | Docs lie. Run it.                                                                                             |
| Empirical check but using wrong version                      | `npm view <pkg> version` first; pin in the workspace.                                                         |
| Reproducer too complex (full project setup)                  | Strip to the smallest snippet that triggers the claim. 5 lines beats 50.                                      |
| Verifying in the user's project directory                    | Use `mktemp -d`. Never pollute the real codebase with verification artifacts.                                 |
| Verifying then ignoring conflicting output                   | If the run contradicts the claim, the claim is wrong. Don't rationalize.                                      |
| Presenting unverifiable inference as verified fact           | Separate "verified: X" from "inferred: Y" explicitly.                                                         |
| Treating one verification as covering the whole turn         | Each claim gets its own check. Per-claim, not per-turn.                                                       |
| Hedging on a config/API claim instead of fetching the docs   | A reachable primary source means you check it, then state the fact. Hedge only if the source is inconclusive. |
| Skimming past a verifiable sub-question because it's "minor" | "Minor" claims get repeated by the user and become wrong facts. Check it.                                     |

## Example

User: _"How do I make Zod reject unknown keys?"_

**Wrong** (memory-only):

> Use `z.object({...}).strict()`.

**Right** (verified):

```bash
$ WORK=$(mktemp -d -t claude-verify-XXXXXX) && cd "$WORK"
$ npm init -y >/dev/null && npm install zod tsx
$ npm view zod version   # → 3.23.8
$ cat > example.ts <<'EOF'
import { z } from "zod";
const schema = z.object({ name: z.string() }).strict();
console.log(schema.safeParse({ name: "ok", extra: 1 }));
EOF
$ npx tsx example.ts
# → { success: false, error: ZodError: [ { code: 'unrecognized_keys', keys: ['extra'], ... } ] }
```

Then in the answer: _"On Zod v3.23.8 (verified at `/tmp/claude-verify-XXXXXX`), `z.object({...}).strict()` makes `safeParse` return `{ success: false }` with `code: 'unrecognized_keys'` when extra keys are present."_

The user gets the answer + the receipts. No room for hallucination.

## Example — plain advice, no code change

User (casual, not editing anything): _"does Vite 5 still run on Node 16, or do I need to bump our CI image?"_

**Wrong** (memory-only): _"Vite 5 needs Node 18+, so yeah, bump it."_ — probably right, but you didn't check, and "probably" isn't an answer the user should reconfigure CI on.

**Right**: `WebFetch https://v5.vite.dev/guide/migration "minimum Node version"` → confirms 18/20+ required; then `npm view vite@5 engines` → `{ node: '^18.0.0 || >=20.0.0' }`. Answer: _"Vite 5 requires Node 18+ (`engines: ^18.0.0 || >=20.0.0`, per the v5 migration guide — Node 16 is dropped). So yes, bump the CI image to 18 or 20."_ — a question, answered, with receipts. The fact that no file was being edited didn't change the obligation.

## Cleanup

`/tmp` is auto-cleaned by macOS periodically. No manual cleanup needed. Reference the workspace path in your answer so the user can inspect if they want, but assume it's ephemeral.
