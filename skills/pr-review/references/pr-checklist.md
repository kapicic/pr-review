# PR must-have / must-not-have checklist

Run this directly by the orchestrator in Phase 4 step 1 — NOT a subagent. Most
items here are pattern-matchable; grep the changed-file list first, then read
enough surrounding code to turn a hit into a proven finding (or discard it).
This replaces the old dispatched Lens F (repo-rules compliance): the checks
below were always mostly mechanical, so paying a full subagent's reasoning
budget to re-derive them from rule excerpts every review was the expensive
way to catch a `console.log`.

Emit each match in the same shape as a lens finding —
`{ file, line, severity, claim, proof, proposedComment }` — and feed it into
Phase 5 synthesis like any other. This pass runs at every `$EFFORT` level,
including `low`: it's nearly free and catches the violations most likely to
actually ship (several of the items below are named for a real incident).

Only check items whose trigger condition matches the diff — most PRs touch
none or a handful of these, not all of them.

## MUST HAVE

- [ ] **New/changed migration** → generated DB types or clients regenerated
      and committed on the SAME PR/branch. Land them separately and the
      dependent PR's type check breaks.
- [ ] **New index on an existing table** → built online (`CREATE INDEX
      CONCURRENTLY` in Postgres), in its own single-purpose migration (no
      other DDL alongside).
- [ ] **New migration** → has a working, reversible `down()` where the
      repo's migrations support one.
- [ ] **Query against a soft-deletable table** (has `deleted_at` or similar)
      → filters out deleted rows on every select/update, unless an inline
      comment justifies the exception (audit view, admin recovery).
- [ ] **Product-facing behavior change** → the product docs updated in the
      same change, when the repo carries them.
- [ ] **New backend list endpoint** → paginated (`total`/`limit`/`offset` or
      a cursor); the frontend consumer pages and filters/sorts server-side,
      never treating a single capped page as "the list" (a capped 50-row
      fetch once silently hid 7 of a customer's 57 records).
- [ ] **New required external secret/webhook/API-key env var** → the secret
      lands and deploys BEFORE the code that references it. If it feeds a
      customer-facing flow (webhook, notification), confirm someone will set
      a REAL value post-deploy — passing a URL-format boot check is not the
      same as working. A `https://placeholder.com` webhook once shipped
      silently for weeks and 500'd a real customer flow with zero prod-log
      activity.
- [ ] **New silent-fallback / self-healing / retry path** (a soft failure
      that doesn't throw) → counted with a metric or alerted on, not just a
      debug log line — an invisible failure mode is a failure mode nobody
      finds until a customer does.

## MUST NOT HAVE

- [ ] Raw `fetch`/`axios`/`requests`/`got` on an agent- or user-supplied URL
      (a tool input, request params, any caller-controlled host) without the
      repo's SSRF guard. Fixed-host vendor API clients are exempt.
- [ ] An internal-only route that a narrower-scope credential (an agent, run
      or integration API key) can still call — it must reject those
      explicitly. This exact gap has been a real cross-tenant hole.
- [ ] Client-side `.filter()`/`.sort()`/search over a list the backend
      paginates or caps.
- [ ] A breaking public-API change (removed/renamed field, narrowed enum,
      changed status code) with no plan — either it isn't actually breaking,
      or the breaking-change gate is consciously overridden.
- [ ] A new long-lived/streaming connection (SSE, WebSocket, a hung HTTP
      call) with no timeout — a stuck stream can exhaust a connection pool or
      pin a server instance under load.

Codebase-specific items (a required PR label, a registry a new table must
join, a CLI that must mirror the API, banned types) go in
`~/.claude/pr-review/checklist.local.md`, in the same two sections. It is read
alongside this file when it exists.

## Maintaining this file

This tracks what's currently biting people, not the full rulebook — the
rulebook already lives in the repo's `CLAUDE.md`/`AGENTS.md`/`.claude/rules/**`. When
adding an item, point it at the specific rule file AND, if there's one, the
incident that motivated it — a checklist item without a "why" decays into
noise nobody trusts. When a rule becomes so well-known it stops showing up as
a review finding, cut it from here rather than letting the list grow forever;
CI/lint should already be catching the truly mechanical ones — this list exists for the gap between "a lint rule could
catch this" and "a lint rule actually does."
