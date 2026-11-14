# Review lenses (per-subagent checklists)

Each lens runs as an independent subagent over the checked-out worktree and
returns findings as objects:
`{ file, line, severity, claim, proof, proposedComment, codeSuggestion? }`.
A finding is only worth returning if it has concrete PROOF in the checked-out
code — a file:line reference plus the reasoning/repro that shows it's real.

## Scope discipline (MANDATORY — especially for stacked PRs)

Report findings ONLY on files this PR actually changed. Give each lens the exact
changed-file list (`git diff <base>..HEAD --name-only`) and instruct it: you may
READ any file for context, but only REPORT issues on the changed files. Never
flag pre-existing base-branch code, generated/bundled artifacts (`*.bundled.ts`)
that merely embed something transitively, or files that are only in the worktree
because the branch is stacked on earlier parts. In synthesis, deterministically
DROP any finding whose `file` is not in the changed set. (Born from a real run
where finders scanned the whole worktree and misattributed a stale generated
bundle and a base-branch email-log issue to the PR under review.)

For a STACKED PR: diff against the PR's actual base (the previous stack part),
not the trunk — the skill already does this via `merge-base(base, head)`. When
reviewing a consumer PR, verify it RESOLVES the prior part's watchlist rather
than re-flagging the latent groundwork.

## Lens routing (by diff shape)

Not every lens fires on every PR. Routing keeps a one-file PR lean and a
cross-layer PR thorough. Classify the changed-file set into surfaces, then
dispatch. **Repo-rules compliance (formerly Lens F) is no longer a dispatched
lens** — it runs as a direct, non-subagent checklist scan in Phase 4 step 1
(see `references/pr-checklist.md`); this both cuts a full subagent and gives
its mostly-mechanical, pattern-matchable checks (SSRF, soft-delete,
pagination, client parity, migrations…) a cheaper, more reliable pass than an LLM
finder re-deriving them from rule excerpts every time.

**Dispatch grouping** — two pairs of lenses that already overlap in practice
share ONE subagent call each, to cut the fan-out without dropping any
checklist content:
- **A+B** ("Correctness & bugs") — dispatched together always. They already
  blur into one read: A's own doc says to flag subtle-bug material rather
  than assume B will catch it.
- **G+H** ("Operability & scale") — dispatched together whenever either's
  surface matches. Their trigger surfaces already overlap almost entirely
  (backend service source, loops, list endpoints), and both are "will this
  hurt in production" concerns.

C, D, E, and S stay solo dispatches — D's mutation mindset, E's downstream-
consumer tracing, and S's exploit-or-nothing bar each deserve undivided
attention (S in particular: never dilute it by pairing, per the strongest-
verification rule below).

**Always run** (any code change):
- Lens A+B (one subagent) — Functional/technical correctness & subtle bugs
- Lens D — Test adequacy

**Routed** (dispatch when the diff touches the surface):

`pr-context.sh profile` tags the `ux`, `contract` and `ops` surfaces by path
regex; the defaults guess common layouts, and `$PRH/config.sh` can set
`UX_PATHS_RE` / `CONTRACT_PATHS_RE` / `OPS_PATHS_RE` to match your codebase.

| Surface in the diff | Lens |
|---|---|
| user-facing frontend / copy (UI components, `*.mdx`, catalog copy, tool descriptions, user-facing error strings) | C — UX |
| public routes and API schemas, shared packages, OpenAPI, a published CLI/SDK, `migrations/`, generated types, socket / tool / event schemas, analytics events | E — Contract & compat |
| backend service source; any new external call or failure path | G+H (one subagent) — Operability & scale |
| repositories / query builders, list endpoints, `migrations/` (indexes), loops over network calls, frontend lists and data hooks | G+H (one subagent) — Operability & scale |
| routes, auth, external fetch of a user/agent URL, secrets/tokens, raw SQL, file upload/handling, webhooks | S — Security (solo, never paired) |

ALWAYS run the **Completeness critic** (below): its gap pass goes out with the
finders, its refute pass follows the non-mutation lenses.

When in doubt, run the lens: a routed lens that finds nothing costs one subagent;
a skipped lens that would have found a Blocker costs a prod incident. The learned
false-positive suppression happens in Phase 5 synthesis, never by skipping a lens.
This routing discipline is the cost lever now, not lens count — at `high` this
brings worst case down from ~10 subagent calls to ~6 (AB, D, C, E, GH, S) + the critic's two passes.
Above 1,500 code lines `pr-context.sh profile` returns up to 3 `shards` and A+B
runs once per shard (worst case ~8); no other lens is split.

## Lens A+B — Correctness & subtle bugs (one subagent, always dispatched)
Give this subagent both checklists below in one prompt — it's a single read of
the diff through two lenses, not two passes.

**A — Functional & technical correctness**
- Does the code do what the PR title/description claims?
- Logic errors, wrong conditionals, off-by-one, inverted booleans.
- Data flow: values threaded correctly; no dropped/renamed fields.
- Feature completeness: is the change wired across every layer it needs, or are
  there half-done stubs / dead ends? For a new integration/endpoint, confirm each
  wiring point is present and the slug/name is byte-identical across all of them.
- Deep-dives are split into dedicated lenses now — tests → D, API/contract → E,
  queries/scale → G+H, security/tenant → S — but still flag anything obvious you
  see in those areas rather than assuming another lens will.

**B — Subtle bugs**
- Edge cases: empty/null/undefined, large inputs, boundaries.
- Error handling: swallowed errors, silent failures, missing `await`, and wrong
  error CLASSIFICATION — a branch keyed on an error type/status that never matches
  the shape actually thrown (dead branch → wrong fallback).
- Concurrency/races; `no-await-in-loop`; `Promise.all` misuse; cache/token races
  (a rejected value cached; a stale value served past a margin edge).
- Type holes: `any`/`unknown`/`!`/`@ts-ignore`, and blind `as T` casts on wire/
  parsed data that isn't validated.

## Lens C — UX (only if the PR touches user-facing FE/copy)
- Product terminology as the repo defines it (AGENTS.md, a UX-writing guide,
  a glossary) — the same concept never named two ways.
- Loading / empty / error states present and correct.
- Copy self-consistency: the same thing described two ways across surfaces (form
  vs catalog vs docs) — check which copy the user actually sees at each step.
- Accessibility basics; truncation for overflow-prone text.

## Lens D — Test adequacy (mutation mindset)
**Budget:** about 25 tool calls, scoped test runs only, its own worktree if it
mutates; report partial-but-honest results if cut short. It never gates the
critic's refute pass.

The question is not "are there tests" but "would these tests FAIL if the code
regressed?" Green CI is the most over-trusted signal in a review.
- Vacuous assertions: an `expect` that compares two test literals, asserts a
  constant, or never invokes the production function under test. (Real catch: a
  TTL test asserting `expect(expectedTtlMs).toBeLessThanOrEqual(expiresIn*1000)`
  — two literals — while never calling `resolveTokenTtlMs`.)
- Non-discriminating fixtures: input arranged so a correct impl and a naive/buggy
  one both pass (e.g. pre-sorted data that can't tell a date-max reduce from
  `.at(-1)`). Ask: what one-line regression would still pass this test?
- Coverage of the CHANGED behavior specifically, not just the happy path: error
  branches, empty/404, quota/429, boundary inputs, the exact bug a helper exists
  to prevent.
- Claims vs reality: does a test named for behavior X actually exercise X? Do
  mocks match production shapes (mock a 401 as the real thrown type, not a
  hand-rolled stand-in that would pass while prod behaves differently)?
- An author's claim about tests is not evidence — verify the test exists and is
  non-vacuous in the checked-out code (an author once cited a "7/7 suite" that
  turned out to be local-only probes, never committed).
- When suggesting more coverage, prefer extracting a pure predicate to unit-test
  over a heavier behavioral test, and never demand a test that would reintroduce
  flakiness the PR removes.

## Lens E — Contract & downstream compatibility
**Budget:** about 25 tool calls; stop tracing a consumer once a grep for it comes
back empty, and report what was checked so "no finding" is credible.

Who breaks if this ships? Trace every consumer of a changed contract.
- Public API surface: request/response schema changes, added/removed fields,
  enum growth (strict `enum` vs `x-extensible-enum`), status codes. Would it
  trip a breaking-change gate (oasdiff or similar) — and should it?
- Client parity: when the repo ships a CLI or SDK that mirrors the API, a new
  or changed public route needs the matching client change (and its version
  bump) in the same change. A public endpoint the client can't reach is
  incomplete.
- Shared-type ripple: shared-package changes that need a rebuild and ripple
  into consumers; a generated-types regeneration that must live on the same
  branch as its migration.
- Migration ↔ code split: migration released separately from dependent code;
  an online index build (`CONCURRENTLY`) for an index on an existing table; a
  reversible `down`.
- Wire/event contracts: socket events, tool schemas, analytics event names,
  persisted enums and identifiers.
- Old-client compat: a published client (a CLI, an SDK, a cached frontend
  bundle) that pins the prior shape and will reject or mishandle the new one.

## Lens F — Repo-rules compliance (retired as a subagent — now a direct checklist)
Formerly a dispatched finder; its checks were mostly mechanical/pattern-matchable
(SSRF, soft-delete, banned types, pagination…), so an LLM
subagent re-deriving them from rule excerpts every review was expensive for what
it caught. It's now the **must-have/must-not-have checklist** run directly by
the orchestrator in Phase 4 step 1 — see `references/pr-checklist.md`, which is
the full, current version of this list (kept there instead of duplicated here so
there's one place to update as new incidents land). Nothing was dropped; it just
doesn't cost a subagent call anymore.

## Lens G+H — Operability & scale (one subagent, dispatched when either's surface matches)
Give this subagent both checklists below in one prompt. Can this be debugged at
3am when it fails in prod, AND does it hold up at realistic scale? (The
reviewer's own history is a wall of prod incidents — these two are what hurt.)

**G — Operability**
- New failure paths emit a log with enough context (request / job / user /
  tenant correlation IDs) to root-cause.
- New failure MODES are counted (a metric) if they'd otherwise be invisible;
  errors reach the error tracker with useful context.
- Redaction: no secret/token/PII in logs, the error tracker, or an error message
  returned to the caller. Trace every log and error-report call on the changed paths —
  including whether a wrapped upstream error carries a body/URL that echoes creds.
- Timeouts/retries on new external calls; a hung call can't wedge the event loop
  or exhaust a connection pool.

**H — Performance & scale**
- Unbounded query / missing `.limit`; N+1 across a loop; `await` in a loop that
  should be `Promise.all`.
- In-memory filter/sort/paginate over a bounded page (must be server-side).
- Missing index for a new query predicate; an ordering without a unique tiebreaker
  (rows duplicated/dropped across pages).
- Oversized payload into the agent context / response (cap it AND state the
  truncation, reporting the true total).
- Event-loop-blocking synchronous work; a large JSON parse/stringify on a hot path.

## Lens S — Security (converging)
Runs like a finder, but its findings get the STRONGEST verification in synthesis
— a real, reachable exploit or nothing. For a security-critical PR prefer the
dedicated security review; this lens is the in-review pass.
- Auth: a new/changed route missing its auth guard; an internal-only route
  reachable by a narrower-scope key (an agent, run or API key).
- Tenant/IDOR: a query not scoped to the caller's team; an id taken from the
  request and used without an ownership check.
- SSRF: a user/agent URL fetched without the guard (also on the checklist — report once).
- Secret leaks: credentials/tokens in logs, the error tracker, responses, or error bodies.
- Injection: unparameterised SQL, path traversal via interpolated input, XSS in
  rendered user content.
- Report only a finding with a concrete, reachable path. A hypothetical
  "the allowlist could miss a future key" defense-in-depth note is NOT a finding.

## Completeness critic (ALWAYS run — two passes)
It fights false-NEGATIVES, which for a review skill are worse than
false-positives. It does NOT re-scan line by line — it reasons about blast
radius. It runs as two passes so neither queues behind the slowest lens:

**Gap pass — dispatched WITH the finders.** Input: the diff, the changed-file
list and the PR description; no finder output is needed.
- Which high-risk area is a finder likely to skip? (auth on a new endpoint, a
  migration's data safety, a redaction path, a contract's consumer, a token race,
  a session or lifecycle interplay, a URL or path built from caller input.)
- Does the change hold end-to-end: wired across every layer, no stub/dead end, and
  does the PR description match what the diff actually does (checkable claims:
  test counts, "lint/format clean", stated behaviours)?

Returns `{ findings: [...], gaps: [ "<area the main agent must spot-check itself>" ] }`.
In Phase 5 the `findings` enter synthesis like any other; each `gap` is an area
the main agent MUST open and spot-check directly before calling the PR clean.

**Refute pass — dispatched once the lenses OTHER than D have returned.** Input: a
short digest of their CLAIMS (not their full output) plus the 2-3
highest-severity or most-attached findings. Keep it short (about 10 tool calls):
- Try to BREAK those findings — premise, trigger, severity — and name the weakest.
- Which claim is over-severe or least proven?
- Which trigger of a gate or failure finding actually fires in production?

Returns `{ findings, severityNotes: [ "<finding> -> <recommended severity + why>" ] }`.
Lens D's findings are not in its digest; the main agent adjudicates them in
Phase 5.

## Repo rule pointers to feed subagents
Give each lens only the rules relevant to the files it covers — excerpts from
the repo's `CLAUDE.md`, `AGENTS.md`, and `.claude/rules/**` on whatever it
defines: tenancy, soft-delete, SSRF, pagination, metrics, structured logging,
migrations, public-API and client parity, analytics events, entitlements,
product docs alignment, and language/style bans. Add the matching **Lens notes**
from `$PRH/checklist.local.md` when it exists. (The mechanical subset of these
is already covered by `references/pr-checklist.md` in Phase 4 step 1 — feeding
it to a lens too is fine as backup context, just don't expect the lens to
re-derive it as its main job.)
