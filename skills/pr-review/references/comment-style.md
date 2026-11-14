# Comment style (uniform)

Every proposed comment uses ONE template: a **severity headline** followed by a
**1–2 sentence** explanation of the problem and its impact. No preamble, no
"consider maybe" hedging, no multi-paragraph essays. This is the text that gets
POSTED to GitHub — terse and professional, written for the PR author. It is a
different piece of writing from the **chat explanation** (below), which is for
the user only and never gets posted.

## Severity taxonomy (fixed)

| Badge | Severity | Meaning |
|-------|----------|---------|
| 🔴 | Blocker | Breaks correctness/security/data integrity; must not merge. |
| 🟠 | High | Real bug or risk likely to bite in production; should fix before merge. |
| 🟡 | Medium | Meaningful issue; fix soon, not necessarily blocking. |
| 🔵 | Low | Minor correctness/clarity/perf improvement. |
| ⚪ | Nit | Style/preference; safe to ignore. |

## Template

`**<badge> <Severity>** — <one or two sentences: what's wrong and why it matters>.`

Examples:
- `**🔴 Blocker** — This query omits the deleted_at filter, so soft-deleted rows leak into the API response and to other tenants.`
- `**🟠 High** — The awaited fetch is inside a for-loop, serializing N network round-trips; use Promise.all so a large list doesn't time out.`
- `**⚪ Nit** — hasError reads clearer than errorExists for this boolean.`

## Chat explanation (mandatory — for the user, never posted)

Every finding also gets a short **chat explanation**, shown alongside it in
Phase 6/7 output but NEVER included in the posted GitHub comment or review
body. Its job is to teach, not just flag — this is the user reading their own
review output, not a message to the PR author.

Rules:
- **Plain English, everyday words.** If a technical term is genuinely needed
  (e.g. "race condition," "N+1 query," "IDOR"), define it in the same
  sentence in ordinary language — don't assume the term is already understood.
- **2–4 sentences**, covering: (1) what the code is actually doing, in plain
  terms; (2) why that's a problem in practice — a concrete scenario of it
  going wrong, not an abstract rule; (3) optionally, the general pattern this
  is an example of, so the lesson generalizes past this one line.
- Can be more casual and expansive than the terse posted comment — it's
  written to build understanding, not to fit a one-line template.
- Applies to every finding shown in Phase 6's suggestions table and carries
  forward into Phase 7's per-candidate triage blocks — don't regenerate it,
  reuse what Phase 5 already wrote.

Example (same finding, two pieces of writing):
- **Posted comment:** `**🟠 High** — The awaited fetch is inside a for-loop, serializing N network round-trips; use Promise.all so a large list doesn't time out.`
- **Chat explanation:** "Right now the code fetches each item one at a time, waiting for each one to finish before starting the next — like standing in a single checkout line instead of opening several registers. If someone has a list of 500 items, that's 500 sequential waits back-to-back instead of one batch running together, and the whole request can time out before it finishes. `Promise.all` kicks all the fetches off at once and waits for the group, which is the general fix any time you see `await` sitting inside a loop."

## Code suggestions

When a fix maps cleanly to the changed line(s), append a GitHub suggestion block
so the author can one-click apply:

    ```suggestion
    const rows = await db.selectFrom("agent")
      .where("team_id", "=", teamId)
      .where("deleted_at", "is", null)
      .selectAll().execute();
    ```

Rules:
- Only emit a suggestion block when the comment is anchored to the exact changed
  line(s) it replaces — otherwise describe the fix in prose in the body.
- Keep suggestions minimal (only the lines that change).
