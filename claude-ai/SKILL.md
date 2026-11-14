---
name: pr-review
description: >-
  Review a GitHub pull request through the GitHub connector — full or
  incremental, detected from saved state. Use when asked to review a PR, given a
  GitHub PR URL, or asked "what's still open on #1234", "did they address my
  comments" or "re-review this PR". A bare number means the default repo. Reads
  the PR's saved rounds from
  the state repo: no prior round → FULL review of the whole diff; head moved
  since the last round → INCREMENTAL review of only the new commits, carrying
  earlier findings forward and spot-checking the claimed fixes. Walks a
  must-have/must-not-have checklist and review lenses (correctness, tests,
  contract/compat, operability, security, UX), verifies each finding against the
  code, and returns a briefing, a suggestions table, scores and a verdict — then
  posts ONE consolidated review only after an explicit typed confirmation, and
  records the round. Reviews a chained stack as one change with per-PR
  attribution. Reduced-depth companion to the Claude Code skill of the same
  name.
---

# pr-review (connector edition)

This runs where there is **no shell access to the repository** — no clone, no
worktree, no `git`. Everything comes through the **GitHub connector**. Nothing
here executes code: the state you read is a small pre-computed sidecar and the
state you write is one small JSON file, so this edition works whether or not
code execution is enabled.

**Say this once, in the first message of every review:** this pass is shallower
than the Claude Code edition of this skill. There it dispatches six independent
lens subagents plus a completeness critic and verifies their findings
adversarially; here one model walks the same lenses in one context. It finds
less. For a Blocker-grade decision, re-run it in Claude Code.

## Constants

| | |
|---|---|
| State repo | `{{STATE_REPO}}` (private) — `none` means no store: take the stateless path from the start |
| State path | `state/<owner>-<repo>-pr-<topNumber>.json` |
| Default review repo | `{{DEFAULT_REPO}}` — a bare number means this repo; `none` means ask which repo |
| Base branch | whatever the bottom PR's `base` says |

`build-zip.sh` fills both from `PR_REVIEW_STATE_REPO` and
`PR_REVIEW_DEFAULT_REPO` when it builds the upload.

## What the connector has to give you

Everything below is a REST resource; the connector's tool names vary, so ask for
the resource, not the tool. If a resource is unavailable, say which one and stop
rather than guessing at the answer it would have given.

| Need | Resource |
|---|---|
| PR metadata (base, head, `head.sha`, draft, title) | `GET /repos/{o}/{r}/pulls/{n}` |
| changed files + per-file `patch` (the `@@` hunks) | `GET /repos/{o}/{r}/pulls/{n}/files` |
| file contents at the head sha (for context beyond the patch) | `GET /repos/{o}/{r}/contents/{path}?ref={sha}` |
| delta since the last round | `GET /repos/{o}/{r}/compare/{oldHead}...{newHead}` |
| existing reviews (is there a standing CHANGES_REQUESTED? what have OTHER reviewers/bots said?) | `GET /repos/{o}/{r}/pulls/{n}/reviews` |
| other reviewers'/bots' inline comments (CodeRabbit, Greptile, Codex, humans, the author's own replies) | `GET /repos/{o}/{r}/pulls/{n}/comments` (paginate) |
| post the review | `POST /repos/{o}/{r}/pulls/{n}/reviews` |
| read state (the sidecar) | `GET /repos/{{STATE_REPO}}/contents/state/summary/<file>` |
| write state (one round) | `PUT /repos/{{STATE_REPO}}/contents/state/pending/<file>` |
| read the learned preferences | `GET /repos/{{STATE_REPO}}/contents/review-preferences.md` |
| read one archived rationale (rare) | `GET /repos/{{STATE_REPO}}/contents/review-preferences-archive.md` |
| write a preference note | `PUT /repos/{{STATE_REPO}}/contents/state/pending/prefs-<file>` |

**You never read or write the full state file.** It reaches hundreds of KB —
fetching one would put every proof and comment from every past round into
context, which is the cost this whole arrangement exists to avoid. Instead:

- **Read** `state/summary/<owner>-<repo>-pr-<N>.json` — a few KB, regenerated on
  every write, carrying the last round, the counts, and every currently-open
  finding (id, file, line, severity, claim, anchorable, declined).
- **Write** one round to `state/pending/<owner>-<repo>-pr-<N>-<UTC timestamp>.json`.
  That is a small `PUT` of a new file — no `sha`, no read-modify-write, no lost
  update if two surfaces write at once. The Claude Code edition folds pending
  rounds into the real file on its next `state.py sync`, where the whole history
  is available to validate against.

The sidecar therefore lags by one round after you write: your round is real, but
it lives in `pending/` until a local sync picks it up. Say so when you finish.

## Phase 0 — Resolve, retrieve, decide the mode

0. **Check the store is reachable before anything else.** Read the state repo
   itself (`GET /repos/{{STATE_REPO}}`). Three ways this goes:

   - **It reads.** Normal operation; continue.
   - **"repository … is not configured for this session. Allowed repositories:
     …"** — a hosted session's repo allowlist, and it is *recoverable*. This is
     the common case: the session was started by picking one repo in the UI, and
     the state repo is a second one. Call `list_repos` to see what the workspace
     can reach, then **ask the user** whether to add `{{STATE_REPO}}`
     with `add_repo` — ask, never add a repo unprompted. If `add_repo` is not
     available in this session it cannot be added: fall back to the stateless
     path below, and tell the user to select **both** repos when they start the
     next session.
   - **Anything else** (404, not authorized) — the connector cannot see the
     store at all. Fall back to the stateless path.

   **The stateless path:** say so **before you start reviewing**, not after —
   the review will be full rather than incremental, and nothing will be recorded
   unless the user files it by hand. Then continue, and in Phase 6 step 5 print
   the round JSON in chat instead of writing it.

   A repo you cannot read is not the same as a PR with no prior round, even
   though both lead to a full review. One records what it found; the other loses
   it. Never report the second when it was the first.
1. Parse the argument into `owner/repo` + PR number(s). Bare number → the
   default review repo.
2. Fetch each PR. With several PRs, check whether they **chain**: sorted so each
   PR's `base.ref` is the previous PR's `head.ref`, bottoming out at exactly one
   whose base is neither. If they chain, it is ONE set of changes — **stack
   mode**, one review pass, per-PR attribution. If they don't, review them one
   at a time. `topNumber` = the top PR of a stack, else the PR itself.
3. Read the sidecar `state/summary/<owner>-<repo>-pr-<topNumber>.json`.
   **A 404 is not an error** — it means no prior round. Also list
   `state/pending/` and read any file matching this PR: those are rounds a
   previous connector-edition run wrote that no local sync has folded in yet.
   They are as real as anything in the sidecar; fold them in yourself when you
   reason about what is open.
4. **Mode**, from `lastRound.heads` in the sidecar (plus any pending round,
   whichever is newer) against the `head.sha` you just fetched:

   | State | Mode |
   |---|---|
   | no sidecar and no pending round | `full` |
   | the PR numbers in `heads` differ from the stack you resolved | `full` — say why |
   | a recorded head differs from the current one | `incremental` |
   | every head matches | **ask** — report the last round and let the user choose: re-run full, list what's open and stop, or stop |

   This is a direct comparison of two short lists — do it yourself. `state.py`
   is not involved in reading here: it needs the full file, which is exactly
   what you are avoiding.

5. **Read `review-preferences.md`** from the state repo — the distilled record
   of the user's review taste, ~10KB, learned across past rounds. Read all of it;
   it is kept short precisely so this is cheap, and where it speaks it outranks
   your defaults on what to post, what to skip and how to pitch a verdict. Do
   NOT fetch `review-preferences-archive.md` here: it is the cold companion,
   worth a targeted read only when one rule's full story decides a call, and a
   bullet's `(archive: PR #N)` pointer names the section. On the stateless path
   you have neither — say that the review runs without learned preferences,
   because that is a real reduction in quality, not a detail.
6. Announce the mode and the PR(s) in one line, with the reduced-depth note.

## Phase 1 — Assemble the diff

**Full mode.** `GET /pulls/{n}/files` (paginate — 100 per page, and a large PR
has several). For each file keep `filename`, `status`, and `patch`. The `@@`
headers in `patch` give the NET hunk ranges on the new side: `@@ -a,b +c,d @@`
covers lines `c` through `c+d-1`. That is what decides `anchorable`.

**Incremental mode.** `GET /compare/{lastRound.heads[n]}...{current head sha}`
for each moved member. Its `files[]` is the DELTA. **Also fetch the NET file
list** and carry both — a file can be in the DELTA yet absent from the NET set,
because the branch added something and later removed it, so against the base
nothing changed. When that happens the PR does not change that file: a finding
there is about base-branch code, must not be described as introduced by this PR,
and cannot take an inline comment. Check the NET patch before ever asserting
that something "was deleted" or "is now unpinned" — that exact false positive
has shipped before.

**Stack mode.** Each member's own `/pulls/{n}/files` is its segment: the files
and hunks that member introduced. Keep them per member for attribution.

A `patch` is truncated on very large files and absent on binaries. When you need
more than the patch shows, fetch the file at the head sha. If a file is too
large to read, say so and scope the finding to what you could actually see —
never infer content you did not read.

**External review context — always, every round, full or incremental.** Fetch
`GET /pulls/{n}/reviews` and `GET /pulls/{n}/comments` (paginated) and keep, per
entry, only `author`, `state`/`path`/`line`, `created_at`/`submitted_at`,
`in_reply_to_id`, and a short prefix of `body` — a bot review's full body can
run to hundreds of KB. Exclude this edition's and the Claude Code edition's own
past reviews (their author is a bot/service account you already know from
Phase 0's sidecar, not a genuine outside opinion). In incremental mode, filter
to entries dated after the last round's `timestamp` — that is the "since you
last looked" delta. Carry a short digest (author, one-line claim, addressed
y/n) into Phase 4 for dedupe/adjudication and Phase 5 for the status line. This
is read-only — see Guardrails.

## Phase 2 — Fix verification (incremental only)

For each currently-open finding from Phase 0:

- **Its file is not in the DELTA** → still open, no work. Most land here; this
  is what makes an incremental pass cheap.
- **Its file is in the DELTA** → read the file at the new head around the
  finding's recorded location and judge, from its `claim`, whether the flagged
  problem is actually gone. One targeted read each. The sidecar carries no
  `proof` — the original quoted code — on purpose: it doubles the sidecar's
  size, and the claim plus the current code answers the question, with the old
  code visible in the PR's own diff if you need it. Classify `fixed`, or
  `still-open` (update the line if it moved), or
  still-open-but-the-fix-introduced-something-else — in that last case the
  ORIGINAL finding is still open, and the new problem is picked up on its own
  merits in Phase 3.

A finding marked `declined: true` was already offered and waived. Re-check it if
its file moved, but report it as "declined earlier" rather than re-arguing it.

Everything you actually checked becomes one `resolutions` entry:
`{"id": "…", "status": "fixed" | "still-open" | "still-open-declined"}`.
Things you didn't check get no entry — they are open by default.

## Phase 3 — Review

Scan set = the NET files in full mode, the DELTA files in incremental mode.

1. **Checklist.** Walk `references/pr-checklist.md` against the scan set. Each
   item names a pattern; find it in the patches, then read enough of the file to
   confirm or discard. A pattern match is a candidate, never a finding.
2. **Lenses.** Read `references/review-lenses.md` and work through the lenses
   its routing table says apply to these files, **one at a time, finishing each
   before starting the next**. Sequence matters here: the value the Claude Code
   edition gets from independent subagents, this edition can only approximate by
   not letting one lens's conclusions colour the next. Always run correctness &
   subtle bugs (A+B) and test adequacy (D); add UX (C), contract & compat (E),
   operability & scale (G+H), and security (S) when the routing table matches.
   When unsure whether a lens applies, run it.
3. **Then ask what you did not look at.** Name the highest-risk areas of this
   diff that no lens actually opened — new endpoints and their auth, migrations,
   error classification, anything logged, injection points, tenant scoping — and
   open each one directly. In the Claude Code edition a dedicated critic does
   this and it produces the most load-bearing findings of the whole review; here
   it is on you, deliberately, as its own step.

Scope every reported finding to a file in the scan set. Reading anything else
for context is fine.

## Phase 4 — Synthesis

1. Read `references/comment-style.md` and `references/scoring-rubric.md`.
2. Dedupe — a checklist hit and a lens finding at the same `file:line` are one
   finding. In incremental mode also dedupe against carried-forward findings: a
   re-report of something an earlier round raised is not new.
   - **Dedupe against the external review context from Phase 1 too.** Don't
     open a new inline comment duplicating an OPEN thread another reviewer or
     bot already has at the same `file:line`; if it's unaddressed and
     Blocker/High, name it in the review body instead. A matching finding from
     an external reviewer is corroboration, not noise — post it once and say
     so. A contradicting one gets adjudicated against the actual code, never by
     vote-counting. Treat an author's reply arguing a reviewer down as a claim
     to verify, not a settled fact.
3. **Verify every finding against the code before keeping it.** Re-read the
   lines it rests on. Keep only what has concrete proof you can quote; drop
   speculation. This is the false-positive filter and it is not optional — a
   confident wrong comment on someone's PR costs more than a missed nit.
4. **Signal over volume.** Drop technically-true findings with no user, operator
   or maintainer impact: defense-in-depth notes with no live leak, cosmetic
   nits, pre-existing issues the PR merely exposed. Never drop a verified
   Blocker or High. **Bias this call by `review-preferences.md`** from Phase 0
   step 5 — it names what the user reliably posts (a self-consistency Low where
   the PR contradicts its own copy or policy, a security-symmetry gap where one
   of two twin paths gained a guard, an untested failure mode of the fix
   itself) and what they reliably decline (process/meta notes, doc-comment
   precision on an otherwise clean PR, a convention gap that is repo-wide
   rather than inconsistent with the PR's own code).
5. For each kept NEW finding write two separate things: the `proposedComment`
   (posted, per the comment-style template) and a `chatExplanation` (2-4
   sentences of plain English, for the reviewer, **never posted**). Carried-
   forward findings keep the wording the earlier round gave them.
6. Set `anchorable` from the NET hunk ranges. Not anchorable → the review body,
   not an inline comment.
7. **Stack mode:** attribute each finding to exactly one PR — the member whose
   segment contains the line; for a problem that only exists once two members
   are combined, the LATER member, and say so in the comment; whole-stack
   observations to the PR they are about, else the top PR's body. Never
   duplicate one finding across members.
8. Verdict and scores per the rubric, computed over the PR's **current full open
   set** (carried-forward still-open + new), not just this round's findings.

## Phase 5 — Report

1. **What it does / how**, before any findings — one or two sentences on the
   change and why it exists, then at most 3-5 bullets on the mechanism and where
   it sits, in the order data flows. Incremental mode scopes this to the delta.
   Never posted to GitHub.
2. Incremental only: **fixed** findings, one line each; then **still open**, as a
   table. Neither goes to triage — the still-open ones were already decided in
   an earlier round. When Phase 1's external review context found activity
   since the last round, add one line naming who commented and whether the
   author replied (e.g. `CodeRabbit flagged X at file:line, unaddressed`).
3. **New findings** as a table, severity first, plus a PR column in stack mode:

   | # | Severity | Location | Anchorable | Proposed comment | Reason | Proof |

4. The `chatExplanation` for each row, below the table.
5. Scores (overall + functional / technical / bug-safety / UX) and the verdict.
   **Scores never appear in anything posted to GitHub.**
6. Say plainly that nothing has been posted, and repeat the reduced-depth note
   once here, where the user is deciding what to do with the result.

## Phase 6 — Confirm, post, persist

**The Claude Code edition gates this behind a structured multi-select. There is
no such widget here, so the gate is a typed confirmation and it is stricter, not
looser.**

1. List the candidate comments numbered, each with its severity, location,
   anchorable-or-body, and the **exact text that would be posted**. Then ask for
   the numbers to post and the verdict to use — in one message, and stop.
2. **Post only what the user typed back.** Not "the recommended set", not "all
   the Highs", not your reading of an approving remark. No numbers, or an
   ambiguous answer, or a reply that talks about the findings without selecting
   any → post nothing and ask again. Silence is never consent.
3. **Re-fetch `head.sha` immediately before posting** and compare it to what you
   reviewed. If it moved, the anchors are stale: re-fetch the files, re-derive
   the hunks, and pin `commit_id` in the payload.
4. `POST /pulls/{n}/reviews` — ONE review, with
   `event`, `body` (prose summary + any non-anchorable findings), and
   `comments[]` (`path`, `line`, `side: "RIGHT"`, `body`). Never post the
   scores. Never post a `chatExplanation`. Stack mode: at most one review per
   member, carrying only its own findings; a member with none gets no review.
   Note in your report that a COMMENT does not clear a standing
   CHANGES_REQUESTED — only an APPROVE does.
5. **Persist the round — always, even when nothing was posted.** Write ONE new
   file to `state/pending/<owner>-<repo>-pr-<topNumber>-<UTC timestamp>.json`
   in the state repo (`PUT .../contents/...`, base64, no `sha` — it is a new
   file every time, so there is nothing to overwrite and nothing to conflict
   with):

   ```jsonc
   {
     "_target": { "owner": "acme", "repo": "app", "pr": 1234 },
     "kind": "full" | "re-review",
     "effort": "connector",
     "surface": "claude-ai",          // marks this as the shallower pass
     "heads": { "1234": "<head.sha actually reviewed>" },
     "stackMembers": null,             // or [bottom, …, top]
     "verdicts": { "1234": "APPROVE|REQUEST CHANGES|COMMENT" },
     "scores": { "overall": 82, "functional": 85, "technical": 80,
                 "bugSafety": 78, "ux": 90 },
     "posted": true,
     "resolutions": [ { "id": "…", "status": "fixed" } ],   // incremental only
     "findings": [                     // NEW findings only, never a carried-forward one
       { "id": "<file>:<line>:<slug-of-claim>", "file": "…", "line": 42,
         "prNumber": 1234, "severity": "High", "claim": "…", "proof": "…",
         "proposedComment": "…", "chatExplanation": "…", "anchorable": true,
         "codeSuggestion": null }
     ]
   }
   ```

   `_target` is what tells the merge where the round belongs — without it the
   round cannot be filed and will sit in `pending/` untouched. Every other field
   is validated when it is merged: a missing key, an unknown severity, or a
   finding id that already exists in an earlier round rejects the round and
   leaves the file in place for a human, rather than dropping it.

   **A round that isn't written doesn't exist.** If the `PUT` fails, say so
   loudly and paste the JSON into the chat so it can be recovered by hand.
6. **Tell the user it is pending.** The round is filed but not yet folded into
   the state file or the sidecar; that happens on the next
   `state.py sync` in Claude Code. Until then another connector-edition run sees
   it only by reading `state/pending/` — which Phase 0 step 3 does.
7. **File what this round taught, if anything.** Triage is the signal: what the
   user selected, rejected or reworded says more than the review did. If a round
   teaches something durable — a class of finding taken or dropped against your
   expectation, a verdict call you got wrong, a verification method worth
   repeating — distil it to 1-3 sentences (rule + one-clause why + at most one
   example) and `PUT` it as a NEW file:

   ```
   state/pending/prefs-<owner>-<repo>-pr-<topNumber>-<UTC timestamp>.md
   ```

   ```markdown
   ## <section it belongs under in review-preferences.md>
   - <the distilled rule>. (archive: PR #<N>)

   <optional: the narrative worth keeping, for the archive>
   ```

   **Never `PUT` `review-preferences.md` itself.** That would be a
   read-modify-write against a file the Claude Code edition also edits, and the
   loser of a race silently loses a lesson — the same reason rounds go to
   `pending/` rather than into the state file. A `prefs-*.md` note is a plain
   create: no `sha`, no conflict. `pending-merge` ignores it (it folds `*.json`
   only); the Claude Code edition's Phase 7 folds it into
   `review-preferences.md`, moves any narrative to the archive, and deletes the
   note.

   "Nothing durable this round" is the common outcome and a fine one — say so
   and write nothing. A note you cannot `PUT` (stateless path) goes in the chat
   verbatim, labelled as something to paste in by hand.

## Guardrails

- Never post without the typed confirmation from Phase 6 step 1. Never treat
  approval of the *review* as approval to *post*.
- Never reply to or resolve existing review threads — that is the author's job.
  Phase 1's external-review-context fetch (other reviewers, bots, the author's
  replies) is read-only, every round.
- Every kept finding carries a quotable proof.
- Two things never reach GitHub: the `chatExplanation` for each finding, and the
  what/how briefing. Both orient the reviewer; the author needs neither.
- Never write to `state/<owner>-<repo>-pr-<N>.json` directly. That file is
  append-only and is maintained where the whole history can be validated;
  writing a new round into `state/pending/` is this edition's only state write.
- Trust the sidecar's counts over your own tally. Recomputing "what's open"
  by hand across rounds is wrong quietly, in the one number read as the summary.
- If the old head is unreachable in the compare (history was rewritten under the
  last reviewed sha), or a stack's membership changed, fall back to a full
  review and say why — never diff against a guessed base.
- Say the reduced-depth caveat at the start and again with the verdict. Someone
  reading only the scores should still know which edition produced them.
