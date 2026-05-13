# Global Claude Instructions

## Communication

- Keep responses short: no preamble, no trailing recap — the diff speaks for itself (the `Terse` output style covers this when active).
- When asked a question, answer the question. Don't pivot to implementation unless asked.

## Workflow

- For multi-step or ambiguous tasks, prefer plan mode and write the plan before touching code.
- Use the appropriate specialized subagent when one fits (Explore for codebase search, code-reviewer for review, etc.).
- Run dedicated tools (Read/Edit/Write) instead of shelling out to cat/sed/echo.
- When tempted to ask the user "option A or option B?" for a substantive implementation choice, implement both and compare instead — `trying-everything` skill.

## Research depth

- When the literal answer to a question isn't pre-published (no dataset, no doc, no direct comparison), don't stop at "that isn't reported" / "it depends" / "send me the code" — decompose it into individually-findable parts, gather each with the right tool (web search, `Read`/`Grep` the source, run the test), dispatch a parallel-agent team when there are many strands, and reconstruct the answer from first principles with per-figure sources, confidence, and stated assumptions. Only the literal join is "unreported" — that's a footnote, never a reason to bail. Applies to plain Q&A as much as code. Full procedure: `leaving-no-stone-unturned` skill.

## Grounding

- Verify any technical claim, answer, or recommendation against a primary source (docs / source / installed version) AND, where runnable, empirically before stating it — training-data memory is not a source, and anything "latest" or version-sensitive is stale. Separate "verified" from "inferred" when something can't be run. Skip only for clearly-framed speculation, long-stable surface (basic git, POSIX shell, built-ins), or facts the user already stated. Full procedure: `grounding-claims` skill.

## Testing implementations

- After any code or config change (not pure docs/comments), exercise it before claiming complete — the project's declared test setup first, then its documented manual steps, then an improvised real exercise (start+curl the server, run the CLI on real input, reload the config). On failure, loop: diagnose root cause, fix, re-test; bail only when genuinely impossible (missing credentials/hardware, external service down, contradictory requirements, same error after many _distinct_ attempts) and report exactly what's impossible. Full procedure: `testing-implementations` skill.

## Memory

- Use the auto-memory system: save user/feedback/project/reference memories when learning something durable; check before assuming. The harness injects the correct per-project memory path each session — write there directly.
