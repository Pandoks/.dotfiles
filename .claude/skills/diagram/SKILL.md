---
name: diagram
description: Use when the user wants an INTERACTIVE SYSTEM DIAGRAM — a pannable/zoomable canvas of labelled boxes (parts of a system) connected by numbered flow arrows, with tabs at the top for different scenarios/views and a collapsible step-by-step panel. Works for ANY system with parts + flows + multiple scenarios, tech or not: software architectures, request/auth flows, data pipelines, supply chains, org charts, biological processes, legal/approval workflows, manufacturing lines, how-a-bill-becomes-law, cellular respiration, an ER patient journey. Triggers: "diagram this", "show how X flows through Y", "make an interactive diagram/architecture/topology/flow", "visualize the system", "walk me through the steps of X across different scenarios". OUTRANKS the `html` skill when the artifact is fundamentally a node-and-flow diagram with scenarios. Skip for a single static picture with no scenarios/steps (a plain SVG via `html` is lighter), or non-visual answers.
---

# Interactive System Diagram

## Overview

This skill produces a **single self-contained HTML file**: a pan/zoom canvas of boxes ("nodes") grouped into optional zones, connected by **numbered flow arrows**, with **tabs at the top** to switch between scenarios (different views of the same system) and a **collapsible bottom-left panel** listing the numbered steps. Clicking a step **isolates** it (focus mode). Labels are **drag-repositionable**.

It is the same engine every time — you NEVER write the rendering/interaction code. You ship a fixed `template.html` and inject ONLY a data block describing the diagram's content. This guarantees every diagram has byte-identical behaviour and look.

**Core principle (inherited from `html`):** the artifact IS the explanation. The chat reply is one line (path + that it opened) plus must-see warnings only. No recap of the diagram's contents in chat.

## When this skill OUTRANKS `html`

Use `diagram` (not `html`) when the thing being explained is **a system of parts with flows between them, viewed across 2+ scenarios**. Examples: "how does a request authenticate", "trace an order through the warehouse", "how a bill becomes a law", "show the data pipeline in batch vs streaming mode". Use plain `html` for prose explainers, comparison grids, single static SVGs, or editors.

## File Handling (same rules as `html`)

1. **Path**: `./.claude/artifacts/YYYY-MM-DD-<kebab-slug>.html` in the current repo. If not in a repo, `$TMPDIR/claude-artifacts/YYYY-MM-DD-<slug>.html`.
2. **Gitignore**: ensure `.claude/artifacts/` is in `.gitignore` on first use.
3. **Self-contained**: the template already inlines everything (no CDN). Keep it that way.
4. **Open it**: after writing, run `open <path>` (macOS). Don't wait for confirmation.
5. **Slug** describes content (`order-fulfillment-flow`, `bill-to-law`, `cellular-respiration`), not the request.

## The Workflow — do exactly this

1. **Locate the template**: it sits next to this SKILL.md at `<skill-dir>/template.html`. Find the skill dir from the path printed when this skill loaded (the "Base directory for this skill" line). Read it ONCE if you want to confirm structure — but you do NOT edit the engine.

2. **Design the DATA** (this is your whole job — see "Data Contract" below). Decide:
   - the **nodes** (boxes): what are the distinct parts of the system?
   - the **zones** (optional groupings): are some nodes "inside" something and others "outside"? (cluster/internet · warehouse/retail · nucleus/cytoplasm · company/external)
   - the **scenarios** (tabs): what are the 2–6 distinct views/flows worth showing? Each is a named tab.
   - for each scenario, the **grid** (where each node sits), the **flow** (numbered arrows), and the **steps** (the numbered list).

3. **Write the file**: read `template.html`, replace the FOUR placeholders, write to the artifact path:
   - `/*__NODES__*/` → your `const NODES = { … };`
   - `/*__SCENARIOS__*/` → your `const SC = { … };`
   - `__TITLE__` → the `<title>` text (e.g. `Order Fulfillment`)
   - `__BRAND__` → the top-left brand line (e.g. `📦 order fulfillment · flow map`)
   Use the Read tool to get the template, then Write the filled result. (Or `cp` + Edit the placeholders — either way, the engine code is copied verbatim, never retyped.)

4. **VERIFY — mandatory, not optional.** Run the harness on the file you just wrote:
   ```
   node <skill-dir>/verify.mjs <your-output-file>
   ```
   (`<skill-dir>` is where this SKILL.md + `template.html` live — the "Base directory for this skill" printed when the skill loaded.) It checks node overlaps, arrows passing through boxes, label collisions, flow/steps parity, AND opens the file in a headless browser to catch runtime crashes that silently drop arrows. **If it reports ANY problem, FIX the data (grids/bows/step-counts/malformed arrows) and re-run — loop until it prints `ALL CHECKS PASSED`. Do NOT proceed to step 5 until it passes.** (If it prints "render check skipped — Playwright not installed", the static checks still ran; that's fine, just be extra careful to eyeball the result.)

5. **Open it** with `open <path>`, then reply with one line.

## Data Contract

Two JavaScript objects. Coordinates and rendering are handled FOR you; you only describe content + a coarse grid.

### Layout grid (how positioning works — you don't compute pixels)

Nodes are placed on a **column × row grid**, per scenario. You give each node `[col, row]`; the engine converts that to non-overlapping pixel positions and auto-fits. Columns increase left→right, rows top→bottom. Keep the natural flow left-to-right: sources in low columns, sinks in high columns. Put a node on its OWN row to give arrows a clear lane (a classic trick: an intermediary like a gateway goes on row 0, above the main row, so a return arrow has a clear straight path).

### `NODES` — every box in the system

```js
const NODES = {
  // id: { w, h, zone, kind, icon, title, sub, lines:[[label,value], …] }
  warehouse:{ w:520, h:200, zone:'company', kind:'core', icon:'🏭', title:'Warehouse', sub:'fulfillment center',
    lines:[['holds','SKUs · inventory'],['picks','robotic + manual']] },
  customer:{ w:480, h:170, zone:'external', kind:'actor', icon:'🧑', title:'Customer', sub:'web / app',
    lines:[['places','orders'],['receives','tracking']] },
  // …
};
```

- `w`,`h`: box size in canvas units. Use ~480–560 wide. Height ~150 (2 lines) to ~300 (5 lines).
- `zone`: optional grouping key (free string). Nodes sharing a zone get wrapped in a labelled rounded box. Two zones is typical (inside/outside). Omit (use `''`) for ungrouped. **Zone display labels** come from `ZONE_LABELS` (below).
- `kind`: drives the accent colour. Use one of: `edge` (blue — gateways/entrypoints), `core` (green — the central service/actor), `store` (gold — databases/inventory/records), `backend` (orange — downstream services/processors), `external`/`actor` (neutral — outside actors). Pick by role, not by literal tech.
- `icon`: one emoji.
- `title`/`sub`: name + one-line role.
- `lines`: 1–4 `[label, value]` rows of detail shown inside the box. `label` is bolded; pass `''` for a continuation line.

Right after `NODES`, also define the zone display labels (the engine reads `ZONE_LABELS`):

```js
const ZONE_LABELS = { company:'Acme Logistics · internal', external:'Public / customers' };
```

(If you use no zones, set `const ZONE_LABELS = {};`.)

### `SC` — the scenarios (tabs)

```js
const SC = {
 placeOrder:{ btn:'Place order', title:'Customer places an order',
   desc:'How an order enters the system and is confirmed.',
   grid:{ customer:[0,1], gateway:[1,0], warehouse:[2,1], inventory:[3,0], ledger:[3,2] },
   flow:[
     ['customer:r:0.4','gateway:l:0.6',1,{net:'HTTPS',ep:'POST /orders',bow:-26}],
     ['gateway:r:0.6','warehouse:l:0.3',2,{net:'queue',ep:'enqueue order',bow:-26}],
     ['warehouse:r:0.2','inventory:l:0.6',3,{net:'query',ep:'reserve stock',bow:-26}],
     ['warehouse','warehouse',4,{net:'compute',ep:'allocate pick list (no I/O)'}],
     ['warehouse:r:0.8','ledger:l:0.4',5,{net:'write',ep:'record order',bow:26}],
     ['warehouse:l:0.7','customer:r:0.7',6,{ret:1,net:'HTTPS',ep:'201 order confirmed',bow:55}],
   ],
   steps:[
     ['Customer → gateway: <code>POST /orders</code>',0],
     ['Gateway → warehouse: enqueue the order',0],
     ['Warehouse → inventory: reserve the stock',0],
     ['Warehouse (local): build the pick list — no external call',0],
     ['Warehouse → ledger: record the order',0],
     ['Warehouse → customer: <code>201 order confirmed</code>',1],
   ],
   note:['','Reservations are atomic — a stock-out fails at step 3 before anything is recorded.'] },

 // … more scenarios …
};
```

**Each scenario field:**
- `btn`: short tab label (top bar).
- `title`: scenario heading (shown in the panel + hint bar).
- `desc`: one or two sentences under the title.
- `grid`: `{ nodeId: [col, row] }` — ONLY the nodes this scenario uses are placed and drawn. Different scenarios can use different subsets and different positions.
- `flow`: array of arrows, in step order. Each arrow:
  `['<from>', '<to>', <n>, { net, ep, bow, ret, compute }]`
  - `from`/`to`: `'<nodeId>:<side>:<frac>'` — side is `l`/`r`/`t`/`b` (left/right/top/bottom edge), frac is 0–1 along that edge. The `<n>` (3rd element) is ignored for display — the number is auto-derived from array position, ALWAYS sequential 1,2,3… Just keep it readable.
  - `net`: the **channel label** shown on the arrow — FREE TEXT, your domain's vocabulary: `HTTP`/`gRPC`/`SQL` for tech, or `truck`/`rail`/`email`/`approval`/`signal`/`diffusion` for anything else. Drives a colour bucket (http→blue, grpc→orange, pg/sql→gold, resp/cache→green, others→gold; pick what reads best — exact colour is cosmetic).
  - `ep`: the detail line under the channel label (the actual message/action, e.g. `POST /orders`, `reserve stock`, `mitosis begins`).
  - `bow`: curve amount (signed int). 0 = straight; ±20–60 = gentle; larger swings the arrow further to avoid crossing a node. Tune so no arrow passes THROUGH a third box (see "Avoiding crossings").
  - `ret:1`: marks a RETURN/response arrow (drawn dashed green). Use for replies/results.
  - `net:'compute'`: a **local action** ON a node (no network) — set `from`==`to`==the node id (no `:side`), omit `bow`. Draws a dashed badge tethered to that node. Use for in-place work: "verify password", "build pick list", "fold protein".
- `steps`: array of `[htmlText, isReturn]`, ONE PER FLOW ENTRY, in the same order. `isReturn` (0/1) should match the arrow's `ret`. Wrap code/identifiers in `<code>…</code>`, emphasis in `<b>…</b>`.
- `note`: `[severity, html]`. severity `''` (accent) or `'warn'` (orange). One key insight or caveat.

## Avoiding crossings (the one thing to get right)

The engine auto-spaces LABELS so they never overlap, but it does NOT reroute arrows — YOU place nodes and set `bow` so no arrow line passes through a third node's box. Rules of thumb:
- Keep each arrow between grid-ADJACENT nodes where possible (one column apart). Adjacent hops need tiny bows (±26).
- If an intermediary node sits between two others on the same row, put the intermediary on a DIFFERENT row (e.g. row 0) so the direct arrow has a clear lane.
- Long arrows that must span the whole width (e.g. client → far backend with stuff in between): route them along the TOP or BOTTOM with a large `bow` so they arc clear of the middle row.
- Return arrows from the far side back to a source: give them a larger `bow` than the forward arrow so the two don't overlap.

If you're unsure, prefer MORE columns/rows and SHORTER hops — spread the nodes out. It's better to have a wide, sparse diagram than crossings.

## Quality bar

- **2–6 scenarios.** One scenario isn't worth the tabs (use `html` + a static SVG instead). More than ~6 is overwhelming.
- **Every scenario's `flow` and `steps` arrays are the SAME length**, in the same order, with matching `ret` flags. (The engine numbers them by position — mismatched lengths desync the arrows from the steps.)
- **Every node in a scenario's `grid` is touched by at least one arrow.** No orphan boxes.
- **Numbers are sequential** — never hand-number with gaps; the engine renumbers by array order, so just keep entries in the order the steps happen.
- **Channel labels are consistent** within a domain (don't mix `HTTP` and `https` and `REST` for the same hop type).
- **Correctness counts.** If you draw a flow, draw the steps it MUST actually perform — don't skip the storage read, the validation, the return. A diagram that omits a required step is wrong, not just incomplete.

## Verifying your output

This is **step 4 of the workflow and is mandatory** — `node <skill-dir>/verify.mjs <your-file>` must print `ALL CHECKS PASSED` before you finish. It reads your file, extracts `NODES`/`SC`, replays the grid math (no node-overlaps, no arrow through a node, no label collisions, `flow.length === steps.length`, no orphan nodes), and — if Playwright is available — opens the file headless and clicks every tab to catch runtime crashes that silently drop arrows. Fix-and-re-run until clean. A passing verify proves the diagram is well-formed and renders; it does NOT prove the *content* is correct — so still glance at the opened diagram.

## Common Mistakes

| Mistake | Fix |
|---|---|
| Editing/retyping the engine JS | Never. Copy the template verbatim; only fill the 4 placeholders. |
| `flow` and `steps` different lengths | Make them 1:1, same order. The engine pairs them by index. |
| Hand-numbering with gaps (1,3,4…) | Don't — the engine renumbers by position. Keep array order = step order. |
| Arrow passes through a third box | Move that box to another row, or increase `bow` to arc around it. |
| One giant scenario, no tabs | If there's only one view, use `html` + a static SVG instead. |
| Tech vocab leaking into a non-tech diagram | `net`/`kind`/`zone` are free text — use the domain's words (truck, approval, nucleus). |
| Recapping the diagram in chat | Chat = one line (path + opened) + must-see warnings only. |
| Skipping a required step to keep it short | A flow that omits a step it must perform is wrong. Draw the real sequence. |
| In-place / self-step using a channel name instead of `compute` | For a step ON one node (`from`==`to`, e.g. `['atmosphere','atmosphere',…]`), `net` MUST be `'compute'` — NOT a channel word like `'condensation'`. A same-node arrow with any other `net` is a degenerate zero-length arrow. (The engine now renders any same-node ref as a badge, but always set `net:'compute'` so the label reads right.) |
| Trusting `verify.mjs` passed without opening the file | The harness now also runs a headless RENDER check (it will fail on a runtime crash). But still glance at the opened diagram — verify checks structure + render, not whether the *content* is correct. |

## Chat reply

After `open`, reply with ONE line: the path and that it opened, e.g.
`Wrote and opened ./.claude/artifacts/2026-06-15-bill-to-law.html — 4 scenarios (introduce, committee, floor vote, veto override).`
Plus any must-see warning. Nothing else.
