---
name: defacto
description: Use when about to recommend "the standard / idiomatic / canonical / de facto way" or "best practice" for a tool, library, framework, or workflow — OR when user invokes /defacto — OR when auditing the user's setup (workflow, Dockerfile, config) against industry convention. Triggers: "standard way to X", "how do most teams configure Y", "is my setup best practice", "audit my use of Z", "idiomatic structure for X", "set up X in CI". Symptoms: about to say "industry standard..." / "everyone does..." / "the convention is..." without checking the tool's docs this session; attributing community patterns to the vendor; recommending from memory; claiming "the standard" with no source; recommending a pattern deprecated in the current major; fusing multi-part questions into one answer; flattening a multi-way community split; inventing community-de-facto from demo forks. Skip ONLY when user cited a source, wants subjective preference over convention, or topic is universally stable (POSIX, git, ECMAScript) with no drift.
---

# Researching De Facto Standard Use of a Tool

## Overview

When someone asks "how should I use tool X" — or asks you to audit their setup against best practice — you must check **multiple distinct sources** and **never conflate them**:

- **Vendor-official (current)**: what the project's own maintainers say in their current README/docs/`action.yml`/official tutorials, scoped to the version the user actually targets.
- **Vendor-official (legacy)**: what the vendor previously recommended but has since deprecated. Most third-party blog content trails by 12–24 months, so legacy patterns persist in the wild.
- **Vendor-dogfooded**: what the maintainer's own production code does. Often differs from the docs because their threat model, scale, or workflow needs differ from a typical user's. Strongest signal for *correct invocation mechanics*, but not always for *user-facing convention*.
- **Vendor-saturated**: when all findable adopters are forks of the vendor's own demo apps — common for tools <3 years old. The "community" hasn't differentiated yet.
- **Community-de-facto**: independent adopter convergence — 2+ unrelated production projects following the same pattern.
- **Anti-pattern-but-common**: when the de facto choice contradicts a naive reading of vendor guidance but is universally followed anyway (singleton stateless workloads → Deployment with replicas=1, not StatefulSet).
- **Inferred**: synthesized from parts when no single source pre-publishes the answer. Confidence anchored to corroboration count: **high** = 3+ independent corroborating sources, **medium** = 1–2, **low** = pure analogy.

**The central failure mode this skill prevents:** flattening these tiers into "the standard." Each tier answers a different question. The user's choice depends on which question they're asking.

**Core principle:** Name your source. Every claim is labeled with one of the tiers above. No claim escapes labeling.

## Skill composition

`defacto` orchestrates other skills; it does not re-implement them.

**REQUIRED SUB-SKILL: `[[ground]]`** — every claim must be primary-source-grounded. No memory-only quotes, no Stack Overflow as primary source, no hedging in place of fetching.

**REQUIRED SUB-SKILL (conditional): `[[superpowers:dispatching-parallel-agents]]`** — dispatch sub-agents *only when each source needs reasoning* (reading + summarizing many files, traversing a docs tree). For 3 single `gh api` calls of ~1 second each, **parallel Bash calls in one tool block are cheaper and faster** than dispatching agents. Rule of thumb: file-or-page fetch → parallel Bash; "read this repo and tell me what they do" → sub-agent.

**RELATED: `[[dig]]`** — when neither vendor docs nor adopter examples have a pre-published answer to a *sub-question* (partial coverage is normal), invoke `dig` for that sub-question only. Label the reconstruction `Inferred:` with named parts and confidence.

**RELATED: `[[test]]`** — when the question is "does this tool actually work this way" rather than "how do people use it", `test` is the right tool.

**NOT RELATED (do not invoke): `[[try-all]]`** — `try-all` is for implementing 2+ competing code approaches in worktrees. `defacto` is research-only.

## When to Use

- User invokes `/defacto <tool>` or `/defacto <question>` directly.
- User asks "what's the standard way to use X / configure Y / structure Z".
- User asks to "audit" or "review" their setup against best practice.
- User asks "how do most teams handle X" / "what's the convention for Y".
- About to recommend a pattern for a tool without having checked the tool's own docs **this session**.
- About to attribute a pattern to the vendor that you only know from analogy with a different tool.
- **Intersection questions** (tool A + tool B together) — expect partial coverage from each side.

## When to Skip

- User has explicitly cited a specific source to follow ("do it the way the X docs say").
- User is asking about their own subjective preference, not the industry.
- Topic is universally stable (POSIX shell builtins, basic `git`, ECMAScript core) — no convention drift exists.
- The question is "does this work" rather than "is this conventional" — use `test` directly.

## Procedure

### Step 1 — Pin the version and decompose the question

Before any fetch:

**1a. Pin the version OR the API generation.** Two distinct triggers, both mandatory:

*Trigger A — recent major bump.* For any tool with a major SemVer bump in the last 18 months (Zod 3→4, pnpm pre/post-9.5 catalogs, React 18/19, Tailwind 3/4, Vite 5/6/7, Renovate's preset renames).

*Trigger B — documented API rename or "replaced by" notice in the changelog* even without a SemVer bump (PowerSync Sync Rules → Sync Streams, Zero `definePermissions` → mutators-and-context, Cosign `COSIGN_EXPERIMENTAL` flag removal). These are version-axis-like without being SemVer events — they cause the same wrong-major content problem.

Resolution order:
- Read the user's `package.json` / `pnpm-lock.yaml` / `go.mod` / `Cargo.toml` / lockfile to see what they actually run.
- If no codebase is provided, check the tool's changelog/release notes for the most recent rename/deprecation and default to the **current** generation, stating the scope explicitly.
- If unclear and a clarifying question is allowed, ask: "which version of X are you on?"
- **Do not fetch docs or adopter examples until the version-or-generation is pinned.** Wrong-generation content is worse than no content because it looks authoritative.
- **Monorepo caveat**: if the user's repo has version-skew (e.g., `apps/web` on Zod 4, `packages/shared` on Zod 3 via pnpm catalog drift), pin per-package and label findings per-version.

**1a.1 — Fetch budget.** If you're under a hard word/turn/budget cap that prevents per-claim fetching, do NOT silently emit findings from memory as if they were `Vendor-official:`. Silent unfetched claims labeled as vendor-grounded is the failure mode this rule prevents.

**Degraded-mode output format** (mandatory when fetch budget bites):

```
⚠️ DEGRADED MODE — no fetches performed this turn. All claims below are
   best-effort recall, downgraded to `Inferred:`. Verify before acting.

Inferred (medium): <claim 1>
Inferred (medium): <claim 2>
...
```

The "⚠️ DEGRADED MODE" banner is non-optional and must be the **first line** of the response, before any labeled findings. Burying it in a preamble note is exactly the silent-unfetched failure mode the rule exists to prevent.

**1b. Decompose compound questions.** "How should I use Tailscale in GHA" is really three sub-questions (auth method + tags + triggers). Don't try to fuse them. List the sub-questions; label findings per sub-question.

**1c. Narrow scope on bare tool names.** `/defacto k3s` with no narrowing is too broad — pick the most common framing (install / setup) and state the scope explicitly, or ask one clarifying question.

### Step 2 — Vendor-official check (parallel if multi-page)

Fetch the vendor's own primary sources. Each fetch is grounded per `[[ground]]`.

**Source selection by tool type:**

| Tool type | Primary source(s) |
|---|---|
| **GitHub Action** | `gh api repos/<o>/<r>/contents/README.md -H "Accept: application/vnd.github.raw"` + `action.yml` and `action.yaml` (try both — `trivy-action` uses `.yaml`) |
| **CLI tool** | Official docs site (`docs.<tool>.io` / `<tool>.dev`) + `<binary> --help` empirically |
| **Library** | Official docs site + the lib's own `tests/` for canonical usage + lib's CHANGELOG for version-gated features |
| **Framework / platform** | Canonical docs site (kubernetes.io, react.dev, helm.sh, argoproj.github.io) — *not* `gh api` |
| **Container image** | Image's own GitHub README + any `examples/` directory |

**Parallelize multi-page docs.** When the vendor publishes a multi-page docs site (Helm's `chart_best_practices/`, ArgoCD's `docs/operator-manual/`, K8s's `concepts/workloads/`), fan out relevant page fetches in parallel — don't sequentialize them.

**For competing-vendor questions** ("Renovate vs Dependabot", "Yarn vs pnpm"), fetch **both** vendors' positioning pages in parallel. Vendor silence about the competitor is itself a finding (`Vendor-silent:`).

**Quote with version applicability.** If a recommendation is version-gated, record `Vendor-official (since v9.5):` so the user knows the floor.

**If vendor sources contradict each other** (README shows pattern A, companion `cosign-installer` shows pattern B), report **both** with their respective source paths. The vendor's internal inconsistency is the finding.

### Step 3 — Vendor-dogfooded check

Fetch what the maintainer's own production code does:

- For CI/build/dev tools: `gh api repos/<o>/<tool>/contents/.github/workflows/` to list workflow files, then fetch the user-facing ones (skip linting/release-internal CI).
- For runtime tools: the maintainer's own tutorial repo or reference deployment, *not* their `.github/workflows/` (which is just their build pipeline).
- For libraries: the lib's own `examples/` directory or the maintainer's flagship app built on the lib (e.g., `rocicorp/mono/apps/zbugs/` for Zero).

**Important caveats:**
- **Dogfooded ≠ user's use case.** Tailscale GHA's own CI only smoke-tests itself; doesn't deploy anything. Don't elevate dogfooded patterns above adopter patterns when the maintainer doesn't exercise the user's scenario.
- **Maintainer's threat model can differ.** Sigstore tells users "keyless is default" but signs their own releases with KMS keys (long-lived signer for canonical release semantics). Report both; name the gap.
- **Framework-author conventions ≠ app-author conventions.** SvelteKit's own monorepo layout reflects how the framework is built, not how apps using it should be organized.

### Step 4 — Community-de-facto check (parallel — sources by domain)

Look at independent adopter convergence. Source list **by question domain**:

| Question domain | Primary community sources | Search recipes |
|---|---|---|
| **CI / GitHub Actions** | `actions/starter-workflows`, `github/codeql-action` workflows, 2–3 CNCF projects' deploy workflows | `gh api repos/actions/starter-workflows/contents/ci`; `gh api repos/<cncf-project>/contents/.github/workflows` |
| **Runtime / install / deploy** | Awesome-X lists, homelab writeups, GitOps reference repos (kubefirst, okami101), Terraform registry | `gh search repos "awesome-<tool>"`; `WebSearch "<tool> homelab production" site:github.com`; `WebSearch "<tool>" site:reddit.com/r/homelab`; `WebSearch "terraform-<tool>" site:registry.terraform.io` |
| **Architectural (workload kind, schema shape, multi-env)** | Canonical Helm charts (Bitnami, prometheus-community, ingress-nginx), operator manifests (Strimzi, CloudNativePG, Cilium), CNCF projects' `install/` or `config/` | `gh api repos/bitnami/charts/contents/bitnami/<app>/templates`; `gh api repos/<operator>/contents/config` |
| **Library API usage** | Official `examples/` + 2–3 major dependents (pin to same major first) | `gh api repos/<owner>/<lib>/contents/examples`; for dependents — `gh search code "<lib>" extension:json filename:package.json` then filter top results |
| **Config file structure** | 2–3 dogfooded configs of major adopters | `gh api repos/<owner>/<adopter>/contents/<config-file>` for known adopters |
| **Young SDK ecosystem (<3yrs, sparse adopters)** | Vendor's own `demos/` directory + `gh search repos <tool>` adopter sample | `gh api repos/<vendor>/<tool>/contents/demos`; `gh search repos "<tool>" --sort=stars --limit=20`. Expect `Vendor-saturated:` as a likely finding |

**Plus, when applicable: dominant-publisher house style.** When one org ships 50+ artifacts under a single style guide, their conventions become de facto by sheer mass: Bitnami for Helm, HashiCorp for Terraform modules, Strimzi for Kafka operators, Argoproj-Labs for ArgoCD extensions. Treat as a fifth source category.

**Dispatch strategy:**
- 3 single `gh api` calls → parallel Bash in one tool block.
- "Read repo X and tell me how they structure Y" → sub-agent via `[[superpowers:dispatching-parallel-agents]]`.
- Don't dispatch a sub-agent for a single file fetch.

### Step 4a — Operational fallbacks (rate limits, missing files)

- **`gh search code` rate-limits at ~2–3 queries unauthenticated.** Batch searches within one agent rather than fanning out one search per agent. If rate-limited, fall back to `WebSearch` + treat top-ranked recent blog posts/CNCF docs as the adopter set.
- **`gh api .../contents/<file>` returns 404** when the file doesn't exist. Don't assume "no data" — try listing the directory first (`gh api .../contents/.github`), then `gh search code repo:<o>/<r> <tool-name>`, then conclude *"adopter does not use the tool"* as a finding.
- **`WebFetch` on github.com URLs (raw.githubusercontent.com, /blob/) consistently 404s.** **Hard rule: github.com → `gh api`, never `WebFetch`.** Use `WebFetch` only for non-GitHub URLs (docs sites, blog posts).
- **List the target repo's `.github/workflows/` first** rather than guessing `release.yml` vs `release.yaml`, `main` vs `master`. One `gh api .../contents/.github/workflows` listing saves multiple guess-and-miss fetches.

### Step 4b — Fallback to decomposition for partial coverage

If steps 2–4 don't produce a clean answer for **any sub-question** (vendor doesn't address it, adopters diverge with no convergence, no template canonicalizes it), invoke `[[dig]]` for **that sub-question only**. Label its reconstruction `Inferred:` with named parts and confidence.

Partial coverage is the norm, not the exception. Label per-sub-question, not per-report.

### Step 5 — Label every claim

Use one of these labels. **Never invent a 7th category** — if a claim doesn't fit, it's `Inferred:` with appropriate confidence.

| Label | When to use |
|---|---|
| `Vendor-official (current):` | Current docs/README recommendation, version-pinned |
| `Vendor-official (legacy):` | Previously-recommended, now deprecated, still echoed in third-party material |
| `Vendor-dogfooded:` | What the maintainer's own code does (separate from docs) |
| `Vendor-saturated:` | All findable adopters are vendor demo forks — no independent community yet (typically ecosystems <3 years old) |
| `Vendor-silent:` | Vendor docs explicitly do not address the question; the silence itself is the finding |
| `Community-de-facto:` | **Requires ≥2 independent adopters showing convergence**, OR one canonical template (`actions/starter-workflows`, `helm create`, `cargo new`, `npm init`) — see Step 6 cross-reference. A single non-template adopter is `Inferred: (single-source, low)` |
| `Anti-pattern-but-common:` | De facto choice contradicts naive reading of vendor guidance but is universally followed (replicas=1 Deployment instead of StatefulSet for stateless singletons) |
| `Inferred (high/medium/low):` | Synthesized from parts. High = 3+ corroborating sources, Medium = 1–2, Low = pure analogy |
| `Coexistence-pattern:` | For intersection/"can I run both" questions where neither vendor endorses coexistence and no single tier-label fits — name the community-observed coexistence pattern itself (e.g., "Dependabot for security-only + Renovate for version updates, with Dependabot's `version-updates` muted"). Always pair with `Inferred:` confidence if not directly attested by adopters |

**`Community-de-facto:` sub-forms** — flag which one:
- *(a) Traceable to adopter X, copied by Y/Z* (origin attributable).
- *(b) Ambient convergence across N independent projects with no clear origin*.

### Step 6 — Name the gap (multiple gaps OK)

When tiers diverge, **name every gap explicitly** as bullets, not prose. Common gap shapes:

- **Vendor-vs-community**: vendor recommends X, community uses Y.
- **Intra-vendor**: README shows X, companion action's README shows Y, blog says Z — all vendor-official.
- **Temporal (deprecation drift)**: vendor-current recommends X, third-party tutorials still teach legacy Y. Often the most actionable finding for new code.
- **Vendor-silent, community-converged**: vendor doesn't address it, community agrees by ambient convergence.
- **Multi-modal community**: community splits 3 ways by user-segment — don't flatten. **Population estimates** should be anchored to one of: (a) GitHub topic/star counts via `gh search repos topic:<tool> --sort=stars`, (b) explicit count of adopter examples sampled ("3 of 4 sampled CNCF projects use pattern A"), (c) blog-hit ranking on first-page `WebSearch`. If no anchor is available, use ordinal language only ("more visible in homelab writeups", "predominant in cloud-IaaS samples") — never invent quantities.
- **Scope-vs-vendor-constraint**: when the user's stated scope contains a configuration the vendor explicitly disallows (k3s n=2 HA, K8s Pods without controllers in prod, Redis with `appendonly no` in HA). Name the vendor constraint, name the user's scope, name the mismatch. This is a *gap with the user*, not a gap between tiers.
- **None — ecosystem too young**: vendor and "community" align because community = vendor's demos. Label `Vendor-saturated:` and state the cause.

### Step 7 — Apply to user's context — neutrally

If the user provided their setup (workflow, Dockerfile, config), compare per-key/per-step against the labeled baselines.

**For multi-key configs** (renovate.json, Dockerfile, large workflows): produce **one labeled finding per key**. Group adjacent keys only when they share a single source citation. Don't write a single prose block summarizing 14 keys.

**Do not recommend which to follow.** Present the gaps, let the user choose. Stating "you should keep the cron" is out-of-scope unless the user explicitly asks "which should I follow?" — at which point you may recommend, citing their stated constraints.

For highly-configurable tools (Renovate, ESLint, Webpack), vendor silence on most knobs is the norm — don't belabor every `Vendor-silent:` finding for a knob the docs simply don't address.

## Output

### HTML artifact decision

After research, evaluate against `[[html]]`'s trigger criteria — **unless overridden**:

- **Explicit user length/word/format cap overrides the HTML trigger.** If the user said "under 500 words" or "respond in chat", honor that.
- Otherwise, if output would exceed ~50 lines, OR is a multi-column comparison (vendor × community × user-context), OR has 2+ sources to render side-by-side that benefit from juxtaposition → invoke `html`.
- Otherwise stay in chat.

The artifact decision is on the *labeled findings* alone — skill-meta sections (pain points, methodology) stay in chat regardless.

### In-chat output follows the active output style

- **`Terse` style** (default in this user's env): no preamble, no trailing recap, no "Summary" sections, no hedging filler. Lead with labeled findings. **The findings ARE the output**; do not append a "Conclusion."
- **Explanatory / Learning style**: include `★ Insight ─` blocks per the style's requirement, but still lead with labeled findings.
- **Multi-section explicit request** (user asked for "labeled findings AND skill feedback"): the no-recap rule yields to the explicit format request — produce both sections.

### Compact label form (for tight word budgets)

When a strict word/char cap pushes against full labels, abbreviate inline: `[V-cur]`, `[V-leg]`, `[V-dog]`, `[V-sat]`, `[V-sil]`, `[C]`, `[A]`, `[I-hi/med/lo]`. Use only when necessary; full labels are clearer.

### Minimum viable in-chat format

**Single-question case:**

```
Vendor-official (current): <recommendation> (source: <path/url>).
Vendor-dogfooded: <what maintainer actually does> (source: <repo/path>).
Community-de-facto: <convention> (sources: <adopter 1>, <adopter 2>).
Gap: <one bullet per gap shape>.
```

**Compound (multi-sub-question) case** — when Step 1b decomposed into 2+ sub-questions, use per-sub-question section headers, NOT inline splits:

```
### Sub-question 1 — <name>
Vendor-official (current): ...
Community-de-facto: ...
Gap: ...

### Sub-question 2 — <name>
Vendor-official (current): ...
...

### Cross-cutting gaps
- <gaps that span multiple sub-questions>
```

Section headers per sub-question are required, not optional — they keep the report scannable and prevent the failure mode where a multi-question answer reads as one prose blob with embedded labels.

Three lines is fine if three lines suffice for a single-question case. Long output is fine only when each additional line is load-bearing.

## Red Flags — STOP and research

- About to type "the standard way to do X is..." without having checked the tool's docs *this session*. → Fetch the docs first.
- About to type "everyone does X" / "most teams Y" without a specific adopter named. → Name the source or drop the claim.
- About to attribute a community convention to the vendor. → Re-check: does the *vendor's own README/docs* say this, or did you see it in a CodeQL template / Stack Overflow / a different tool's docs?
- About to recommend the dogfooded pattern as "the standard" without checking whether docs also recommend it. → They might not match (Renovate, Sigstore). Report both tiers and name the gap.
- About to fetch docs without pinning the version first. → For any tool with a major version in the last 18 months, version-pin before fetching.
- About to fuse multiple sub-questions into one labeled answer. → Decompose first; label per-sub-question.
- About to flatten a multi-modal community (3 install methods, 2 schema styles) into one convention. → Use multi-modal `Community-de-facto:` reporting.
- About to invent `Community-de-facto:` when all "adopters" are vendor demo forks. → That's `Vendor-saturated:`, not community.
- About to claim `Community-de-facto:` from a single adopter. → Single-source is `Inferred: (single-source, low)`.
- About to dispatch 5 sub-agents for what is 5 single-file fetches. → Use parallel Bash in one tool block instead.
- About to `WebFetch` a github.com URL. → Use `gh api` instead.
- About to recommend "which one to follow" without the user explicitly asking. → Out-of-scope. Present the gap, stop.

## Common Mistakes

| Mistake | Fix |
|---|---|
| Memory-only recommendation | Fetch the README via `gh api`; quote the exact line |
| Conflating community pattern with vendor recommendation | Label both separately with their tier labels |
| Treating "Vendor-official" as monolithic when docs ≠ dogfood ≠ blog | Split into `Vendor-official (current/legacy)`, `Vendor-dogfooded:`, report each separately |
| Skipping version-pinning before fetching | Step 1a is mandatory for any tool with a major bump in 18 months |
| Self-dogfooded CI is "strongest signal" — universally true? | No. Strong for *invocation mechanics*. Often weak for *user-facing convention* (Sigstore KMS) or when the maintainer's CI doesn't exercise the user's use case (Tailscale smoke test) |
| Treating one ecosystem's template as universal | CodeQL convention ≠ Trivy convention ≠ Snyk convention. Check the target tool's *own* ecosystem |
| Inventing `Community-de-facto:` from demo forks | Label `Vendor-saturated:` and state the cause (young ecosystem) |
| Claiming `Community-de-facto:` from one adopter | One adopter = `Inferred: (single-source, low)` |
| Sequential fetches for independent multi-page docs sites | Parallelize vendor doc-page fetches the same way community sources are parallelized |
| Dispatching sub-agents for trivial parallel fetches | Use parallel Bash in one tool block; reserve agents for reasoning-heavy sources |
| `WebFetch` on github.com URLs | Hard rule: github.com → `gh api`. `WebFetch` only for non-GitHub sources |
| Flattening multi-modal community splits | Report as multi-modal with rough population breakdown by user-segment |
| Adding a recommendation when user didn't ask "which should I follow?" | Don't. Present the gap, let them choose |
| Writing "Summary" / "Conclusion" in `Terse` style | The labeled-findings block IS the output |
| Treating `Inferred:` as equivalent to vendor or community labels | Third-tier. Anchor confidence to corroboration count (3+ = high, 1–2 = medium, analogy = low) |
| One-prose-block audit of a 14-key config | One labeled finding per key |

## Example 1 — Tool with three-tier divergence + intra-vendor inconsistency (cosign)

**User:** "What's the de facto way to sign container images with cosign — keyless OIDC or keyed?"

**Wrong** (memory-only, conflates tiers):
> "Keyless OIDC is the industry standard; cosign defaults to it."

Wrong because it (a) ignores that cosign's own release pipeline uses keyed-via-KMS, (b) treats one vendor doc surface as monolithic when multiple vendor docs conflict, and (c) attributes the "default" without naming which tier.

**Right** (multi-tier with intra-vendor gap named):

1. **Step 1**: Question pins to a recent generation (cosign v2+ removed `COSIGN_EXPERIMENTAL` and made keyless the documented default). Trigger B applies — record current generation explicitly.

2. **Step 2 — Vendor-official check** (parallel fetches of multiple vendor surfaces):
   - `gh api repos/sigstore/cosign/contents/README.md` → "Keyless signing with the Sigstore public good Fulcio certificate authority and Rekor transparency log (default)."
   - `WebFetch docs.sigstore.dev/cosign/signing/overview` → "Identity-based signing is the default because managing and distributing keys can be challenging."
   - `gh api repos/sigstore/cosign-installer/contents/README.md` → flagship workflow example uses `--key env://COSIGN_PRIVATE_KEY` (the keyed path) with `permissions: id-token: write` annotated.
   - **Intra-vendor gap**: cosign README says keyless is default; cosign-installer's lead example shows keyed.

3. **Step 3 — Vendor-dogfooded check**: `gh api repos/sigstore/cosign/contents/.github/workflows/cut-release.yml` → Sigstore signs *their own* cosign releases with a **GCP KMS key** (`_KEY_RING=release-cosign`, `_KEY_NAME=cosign`, WIF-authed GCP). The maintainers do **not** dogfood pure keyless for canonical release artifacts.

4. **Step 4 — Community-de-facto check** (parallel Bash):
   - `gh api repos/kyverno/kyverno/contents/.github/workflows/release.yaml` → `cosign sign --yes` (no `--key`) → keyless.
   - `gh api repos/falcosecurity/falco/contents/.github/workflows/reusable_publish_docker.yaml` → `COSIGN_YES: "true"`, `permissions.id-token: write`, no key → keyless.

5. **Labeled report:**

   ```
   Vendor-official (current, README): keyless OIDC (Fulcio + Rekor) is the default;
     `cosign sign $IMAGE` triggers identity-based signing
     (sigstore/cosign/README.md).
   Vendor-official (current, companion action): keyed example via `--key env://`
     in cosign-installer's flagship workflow example
     (sigstore/cosign-installer/README.md).
   Vendor-dogfooded: KMS-backed keyed signing for Sigstore's own release artifacts
     (sigstore/cosign/.github/workflows/cut-release.yml — GCP KMS via WIF).
   Community-de-facto: keyless `cosign sign --yes` with `id-token: write` —
     Kyverno's release.yaml and Falco's reusable_publish_docker.yaml both use this.
   Gap:
     - Intra-vendor: cosign README leads with keyless; cosign-installer's lead
       example shows keyed. Both vendor-official.
     - Vendor-dogfood vs vendor-docs: docs say "keyless is default"; Sigstore signs
       themselves keyed-via-KMS. Different threat models — per-build provenance vs
       canonical release-key semantics.
   ```

   No recommendation issued unless user asks "which should I follow?"

## Example 2 — Architectural question with multi-modal community (k3s install)

**User:** "What's the de facto way to install k3s for a small production cluster (1–3 nodes)?"

**Labeled findings:**

```
Vendor-official (current): bare install script `curl -sfL https://get.k3s.io | sh -`
  (docs.k3s.io/quick-start). sqlite default datastore; HA requires 3+ servers
  with embedded etcd (docs.k3s.io/datastore/ha-embedded).
Vendor-silent: vendor docs don't acknowledge k3sup, Terraform modules, or
  GitOps wrappers — those are entirely community.
Community-de-facto (multi-modal, splits ~3 ways):
  - Homelab / bare-metal: bare script + sqlite (n=1) or embedded etcd (n=3),
    often with k3sup for SSH automation (alexellis/k3sup, 7.4k stars).
  - Cloud-IaaS: Terraform modules — rancher/terraform-k3s-aws-cluster (vendor-adjacent),
    x00real/terraform-k3s, vietanhduong/terraform-k3s.
  - Reference GitOps stacks: okami101's "Beautiful GitOps Day" series, kubefirst.
Inferred (medium): GitOps layer (Argo CD / Flux) applied after bootstrap is
  near-universal in "production"-labeled writeups, regardless of install method.
Gap: vendor's "official" path is bare script; everything beyond is community
  convenience-layer convention added by the ecosystem.
```

## Example 3 — Vendor-saturated with deprecation drift (Zero / rocicorp)

**User:** "What's the de facto way to define permissions in rocicorp's Zero sync engine?"

**Right** (Trigger-B version-pinning + saturated + legacy-drift):

1. **Step 1a (Trigger B)**: Zero's `definePermissions` / RLS-style API is **deprecated** in current docs. Pin to current generation (mutators-and-context model) before fetching.

2. **Step 2 — Vendor-official check**:
   - `WebFetch zero.rocicorp.dev/docs/permissions` → "Zero does not have (or need) a first-class permission system like RLS. Instead, you implement permissions by authenticating the user in your queries and mutators endpoints."
   - `WebFetch zero.rocicorp.dev/docs/deprecated/rls-permissions` → "This API is deprecated: It will be removed in a future release of Zero."

3. **Step 3 — Vendor-dogfooded check**: `gh api repos/rocicorp/mono/contents/apps/zbugs/shared` → splits into `auth.ts` (Role type), `queries.ts` (ctx-filtered reads), `mutators.ts` (authz on writes). The file *layout* is dogfooded — not prescribed by docs.

4. **Step 4 — Community check**: `gh search repos "@rocicorp/zero"` → all hits are either schema-generation tooling (`drizzle-zero`, `prisma-generator-zero`) or intro tutorials mirroring vendor demos. No independent layout convention.

5. **Labeled report:**

   ```
   Vendor-official (current): permissions via authenticated queries + custom
     mutators with a Context object — no first-class permission API
     (zero.rocicorp.dev/docs/permissions).
   Vendor-official (legacy): `definePermissions` / `ANYONE_CAN` / ZQL-rule API
     deployed via `zero-deploy-permissions` — DEPRECATED, scheduled for removal
     (zero.rocicorp.dev/docs/deprecated/rls-permissions).
   Vendor-dogfooded: `shared/{auth,queries,mutators}.ts` file split in zbugs;
     this is the maintainer's file-layout convention, not prescribed in docs
     (rocicorp/mono/apps/zbugs/shared/).
   Vendor-saturated: no independent adopters with non-vendor schema/permissions
     conventions; third-party content is generators or tutorials.
   Gap:
     - Temporal (deprecation drift): most third-party tutorials (incl. Feb 2025
       marmelab post, prisma-generator-zero) still teach the deprecated
       `definePermissions` API. Users copying older guides will land on
       removed-soon code.
     - None at vendor-vs-community level — ecosystem too young.
   ```

## Why label every tier separately

Because **the gap is the answer the user needs**. If they're optimizing for:
- "Match exactly what the docs say" (audit-driven, regulated) → vendor-official-current.
- "Do what the maintainer actually does" (high-trust signal for mechanics) → vendor-dogfooded.
- "Use the same patterns as everyone else" (hire-from-market, onboarding) → community-de-facto.
- "Avoid landmines from deprecated patterns in old blog posts" → vendor-official-legacy is the warning label.

All four are valid optimizations; the choice depends on user context the user owns. Your job is to make the choice visible — never collapse the tiers.
