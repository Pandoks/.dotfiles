---
name: dig
description: Use when about to tell the user something "isn't reported" / "no data exists" / "I couldn't find a direct comparison" / "it depends, I can't say without more info" — or about to hand back a thin answer to a question whose answer could be reconstructed from findable parts, or stop investigating before running the tests, reading the source, or searching the web. Symptoms — declaring something unknown without having decomposed it, bailing on a niche cross-cut question because nobody pre-published the exact join, recommending against a path you never actually tried, asking the user to supply something a `WebSearch`/`Read`/test run would get you, prefacing a non-answer with "the honest answer is I can't". Skip only when the question genuinely has no decomposable answer, or the user explicitly asked for a quick off-the-cuff take.
---

# Leaving No Stone Unturned

## Overview

The absence of a pre-packaged answer is not the absence of an answer. Niche cross-cut questions ("complication rates AND prices for SMILE surgery across Korea, Taiwan, and the Bay Area") are almost never co-reported as a single dataset — but the _parts_ are: per-region complication studies exist, clinic price lists exist. Your job is to decompose, gather the parts, and reconstruct the answer from first principles — stating assumptions and per-figure confidence. Only the _literal join_ is "unreported"; that's a footnote in your answer, never a reason to stop.

**Core principle:** "I couldn't find it pre-made" → go make it. A reachable source — a web search, a file to `Read`, a test to run — means you reach it, then answer. The bailout ("isn't tracked anywhere", "it depends", "send me the code") is the failure, even when it sounds honest.

This applies to plain Q&A and advice exactly as much as to code tasks. A wrong-because-lazy non-answer in casual conversation is still the user not getting the answer they could have had.

**RELATED:** Verify each piece you gather per `verify`. Exercise code claims per `confirm`. Scale up per `superpowers:dispatching-parallel-agents`. For competing _code implementations_ specifically, `try-all` (worktrees).

## When to Use

- About to say a number/comparison/fact "isn't reported" or "isn't tracked".
- About to answer "it depends — I can't say without more info" when the info is reachable (a file, a docs page, a test, a search).
- About to give a hand-wavy estimate where decomposing into estimable factors would give a real one.
- About to recommend for/against an approach you haven't actually tried.
- The question spans regions / products / timeframes / subsystems that aren't co-reported but are individually findable.

**When to skip:**

- The question genuinely has no decomposable answer (a single proprietary number that exists nowhere and can't be derived).
- The user explicitly wants a quick take, not research.
- The only "source" is the user themselves (they're asking about _their_ preference/intent).

## Procedure

1. **Decompose.** Break the question into sub-facts that _are_ individually findable. "X across A, B, C" → "X in A", "X in B", "X in C". "How does our code do X" → "what does `foo.ts` do", "what does `bar.ts` do". "How big is X" → estimable factors whose product is X.

2. **Gather each part with the right tool.** Facts/prices/stats → `WebSearch` / `WebFetch` (multiple sources per figure). Codebase behavior → `Read` / `Grep` the actual files; for runtime behavior, _run it_ (`confirm`). Versions → `npm view` / `pip show` / `--version`.

3. **Scale up when the search is large.** Many independent strands (several regions, several subsystems, several sources to chase) → dispatch a team, one agent per strand, per `superpowers:dispatching-parallel-agents`. For strands that won't finish in one turn, use `TaskCreate` so they survive across turns. You synthesize their findings — don't just relay them.

4. **When forked between answers, pursue every branch.** Two plausible explanations for a bug? Two readings of an ambiguous question? Two candidate root causes? Don't pick the likelier one and move on — pursue each far enough to tell which is right, then report the comparison. (Competing code _implementations_ → `try-all`.)

5. **Synthesize and report with provenance.** Reconstruct the answer the user asked for. Every figure gets a source and a confidence; label clearly what's _measured_ vs. _estimated_ vs. _genuinely unknown_. State your assumptions. Say "the literal co-reported dataset doesn't exist — here it is reconstructed", not "this isn't reported, sorry".

## Red Flags — STOP, you're bailing

- About to type "that specific figure isn't tracked / reported anywhere" and stop.
- About to type "it depends" / "I can't say without more info" when the info is one `Read` or `WebSearch` away.
- About to ask the user to hand you the code / the docs / the data instead of going to get it.
- About to recommend against a path with "but I haven't actually tried it".
- About to give a deliberately vague answer because the question feels "too niche to bother".
- Prefacing a non-answer with "the honest answer is I can't" — honesty about a gap is not a substitute for closing it.
- Thinking "the comparison they want just doesn't exist as a dataset" — right, so build it.
- Thinking "this isn't really a research task" — the skill is not code-only; a lazy answer in chat is still lazy.

All of these mean: decompose, gather, synthesize. Then answer.

## Common Rationalizations

| Rationalization                                                  | Reality                                                                                                   |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| "No published dataset has this exact comparison"                 | Almost no niche cross-cut is pre-joined. The parts are published. Join them.                              |
| "It varies too much to give a number"                            | Then give a range, derived from the factors that make it vary. A bounded estimate beats "it varies".      |
| "I'd just be guessing"                                           | A decomposed estimate with stated assumptions is not a guess — it's a model. Show the model.              |
| "Send me the code/data and I'll tell you"                        | The code/data is reachable. Go get it. Asking the user to fetch what you can fetch is the bailout.        |
| "This isn't really a research task / it's just a quick question" | Lazy answers in casual conversation are still lazy. The user acts on them anyway.                         |
| "I haven't tried that approach"                                  | Then try it. "I haven't tried it" is a reason to try it, not a reason to dismiss it.                      |
| "Being honest about the gap is the responsible answer"           | Honesty about a gap is step zero, not the answer. Close the gap, then report what's still genuinely open. |
| "The studies are single-clinic, not national"                    | So pool them and say what they collectively imply. Imperfect data, synthesized, beats no answer.          |
| "It'd take a while / many sources"                               | That's what a parallel-agent team is for. Dispatch one.                                                   |

## Example

User: _"Compare SMILE eye-surgery complication rates and prices across South Korea, Taiwan, and the SF Bay Area — actual numbers, not caveats."_

**Wrong (the bailout):** _"There's no published country-level complication-rate dataset that lets you say Korea X%, Taiwan Y%, Bay Area Z% — these come from single-clinic series, not registries. So I can't give you that comparison."_ — true, and useless. The user can't act on it.

**Right:** Decompose into six strands (complication rate × 3 regions, price × 3 regions). Dispatch agents / `WebSearch` each: per-region SMILE complication studies (pool the single-clinic series, note they're platform-driven so roughly region-independent), clinic price lists + medical-tourism aggregators per region. Synthesize: a price table (Korea ~$2–3.3k / Taiwan ~$3.1–3.5k / Bay Area ~$6–7k, each cell sourced), a complication table (pooled global rates, applied per-region with the caveat that surgeon volume dominates, not country), each figure tagged measured/estimated, assumptions stated. Close with: _"The literal three-way co-reported dataset doesn't exist — this is it reconstructed; here's what's still genuinely uncertain (the per-region surgeon-quality distribution)."_ The user gets the comparison **and** the receipts.
