---
name: pr-review
description: >-
  Deep code review of a GitHub pull request, full or incremental — one skill,
  the mode is detected, not chosen. Use when the user runs /pr-review or /prr,
  asks to "review PR" followed by a number, pastes a GitHub PR URL, asks "did
  they address my comments" / "re-review this PR" / "check if the fixes are
  good", wants their review-requested queue triaged and picked interactively,
  or says "auto pick a PR to review". A bare number means the current checkout's
  repo. Retrieves the PR's saved review state first: no prior round → FULL
  review of the whole diff; prior round whose head has moved → INCREMENTAL
  review of just the new commits, carrying forward what was already found and
  spot-checking what the author claims to have fixed. Checks out the PR head in
  an isolated git worktree, runs a must-have/must-not-have checklist scan, fans
  out routed review subagents (correctness & bugs, test adequacy,
  contract/compat, operability & scale, security, UX) plus a completeness
  critic, synthesizes with adversarial verification, and returns a laconic
  chat-only what-it-does/how briefing (with an ASCII diagram where there's a
  flow worth drawing) + a uniform suggestions table + per-criterion & overall
  scores + verdict, then posts ONE consolidated GitHub review after
  accept/discard triage. Given multiple PRs forming a GitHub stack,
  reviews the combined stack diff in ONE lens pass and attributes each finding
  to the stack PR it belongs to. Effort and subagent count are sized
  automatically from the diff's size, surfaces and risk (Phase 2); optional
  `model=` and `effort=` overrides cut subagent token spend, or spend MORE via
  `effort=max` for a Workflow-backed adversarial deep-dive.
---

# /pr-review — PR review, full or incremental

Usage: `/pr-review [<PR#>…|<url>…|auto] [model=<sonnet|opus|haiku|fable>] [effort=<auto|low|medium|high|xhigh|max>] [mode=<full|incremental>]`
(aliases: `/prr`, `/pr-re-review` — same skill, same arguments).

**There is one review flow.** `$MODE` decides only the SCAN SET fed to the
finders — the whole diff, or just the commits since the last round — plus one
extra phase (fix verification) that exists only in incremental mode. Phases 4-7
are byte-identical between modes. Never treat a re-review as a different kind of
review; it is this review with a smaller scan set and a memory.

Follow these phases in order. Create a todo per phase. Think hard (ultrathink)
in the synthesis phase. Read the four reference docs before producing output,
plus `$PRH/checklist.local.md` when it exists: codebase-specific must-have /
must-not-have items that extend `references/pr-checklist.md` and are scanned
the same way, plus Lens notes that go to the lens they name. Read `$PRH/review-preferences.md` in Phase 0, when it exists, and
carry it through every phase: it is the learned record of the user's review
taste, and where it speaks it outranks your priors about what is worth posting.

Two scripts own everything deterministic. Call them; do not re-derive their work
by hand, and do not hand-edit the state file. They live in `scripts/` beside
this file — the working directory is the repo under review, so use the full
path from this skill's base directory:

```bash
SK="<this skill's base directory>/scripts"   # $SK/state.py, $SK/pr-context.sh
PRH=~/.claude/pr-review                       # the user's private data, never in the skill
```

| Script | Owns |
|---|---|
| `pr-context.sh` | argument parsing, stack-chain detection, worktree, review range, per-member segments, delta-since-last-round, changed-file lists, hunk ranges |
| `state.py` | reading and writing review rounds — append-only, validated, atomic; folds `resolutions` forward to answer "what is still open"; `doctor` reports whether the store is usable here, `sync` pushes it |

The skill is public code (`kapicic/pr-review`). Everything personal lives in
`$PRH`: `state/` (the review rounds), the learned `review-preferences*.md`, an
optional `checklist.local.md`, and an optional `config.sh` read by
`pr-context.sh` (default repo, surface path regexes). When `$PRH` is a clone of
a private repo, `state.py sync` shares rounds across machines and with the
reduced-depth **connector edition** for claude.ai (`claude-ai/SKILL.md` in the
skill's repo); a review started on either surface continues on the other. When
you change a phase here that the connector edition mirrors, say so — it is
hand-adapted, not generated, and drifts silently otherwise.

## Phase 0 — Preconditions, arguments, and MODE

**Before step 1, read `$PRH/review-preferences.md`** when it exists — the
distilled record of the user's review taste, learned across past rounds. It is
kept short on purpose: read all of it, every review, and let it override your
defaults on what to post, what to skip, and how to pitch a verdict. A missing
file just means no taste learned yet; Phase 7 creates it. Do NOT read
`$PRH/review-preferences-archive.md` here — it is the cold companion, pulled in only
when one rule's full story matters (its header says when).

1. Verify `gh auth status` succeeds. If not, tell the user to run
   `gh auth login` and stop. Then check the store:

   ```bash
   $SK/state.py doctor        # exit 0 = shared, 4 = degraded
   ```

   Its `stateMode` is `$STATE_MODE` for the rest of the run:
   - **`shared`** — normal. Everything below applies as written.
   - **`local-only`** — the store is here but its remote is out of reach, or
     it is a plain local directory. Review and record normally; skip the push
     in Phase 7 step 6. Say the round is unpushed only when `doctor` found a git
     repo — for a plain directory, local is the normal state.
   - **`unreachable`** — there is no store in this environment. This happens in
     a hosted/cloud session scoped to the repo under review: the state repo is a
     *different* repo and was not selected when the session started. If a GitHub
     connector is present, try reading the store through it first — and if that
     is refused with "repository … is not configured for this session", call
     `list_repos` and **ask the user** whether to add the state repo (`$PRH`'s
     `origin`) with `add_repo` (ask; never add a repo unprompted). Only when that is
     unavailable is the store genuinely out of reach. **Say so before you start
     reviewing, not after** — the review will be full rather
     than incremental (there is no prior round to read, and "no store" looks
     exactly like "no prior round"), and nothing will be recorded unless the
     user files it. Then continue, and in Phase 7 step 5 print the round JSON in
     chat instead of appending it.

   Never treat `unreachable` as `no prior round`. They produce the same review
   and opposite consequences: one records what it found, the other loses it.
2. **Strip the optional control tokens** from the argument, in any order,
   before routing on what remains:
   - `model=<sonnet|opus|haiku|fable>` → `$MODEL` (default: unset — subagents
     inherit the session model).
   - `effort=<auto|low|medium|high|xhigh|max>`, or the literal `ultracode`
     (alias for `effort=max`) → `$EFFORT` (default `auto`). `auto` is resolved
     per PR in Phase 2, once the worktree exists (→ Resolve `$EFFORT`); an
     explicit tier skips that and is used as given.
   - `mode=<full|incremental>` → `$FORCED_MODE`, which overrides the detection
     in step 5. Use it when the user explicitly wants a fresh full pass over a
     PR that already has rounds on record.

   `$MODEL` and an explicit `$EFFORT` persist for every PR reviewed this
   invocation, including a multi-select from the picker; `auto` is re-resolved
   for each PR. They change only Phase 4 (which subagents get
   dispatched, on what model, by which tool) and Phase 5 (how much gets
   re-verified). Two regimes live under one `$EFFORT` scale because they are
   gated by two different tools:
   - **`low` / `medium` / `high`** dispatch subagents with the plain `Agent`
     tool. That tool has no reasoning-effort parameter at all — only `model` —
     so these three are a SCOPE dial (how many lenses run, how much gets
     re-verified), not a reasoning dial.
   - **`xhigh` / `max`** switch Phase 4/5 to a `Workflow` script instead. Only
     `Workflow`'s `agent()` helper exposes a real per-call `effort` option that
     reaches the underlying model call — the only place `xhigh`/`max` can mean
     anything. Naming `effort=max` `ultracode` too is deliberate: choosing it is
     what satisfies `Workflow`'s own opt-in requirement ("a skill's instructions
     tell you to call Workflow") — no separate confirmation needed.
3. Route on what remains:
   - **No arg** → Phase 1 (picker).
   - **`auto`** → Phase 1′ (auto-select).
   - **One or more numbers / URLs** → resolve them:

     ```bash
     CTX="$($SK/pr-context.sh resolve <spec>… | jq -r .ctxFile)"
     ```

     The context file is this run's single source of truth for
     owner/repo/members/heads. `isStack: true` means the given PRs chain
     base→head into ONE set of changes (GitHub stacks included) and get ONE
     review pass with per-PR attribution — `members` comes back ordered bottom →
     top regardless of the order they were given in. `isStack: false` with
     several PRs means independent changes: review them one at a time, each
     with its own `resolve`.
4. **Retrieve prior state** for the top PR (skip when `$STATE_MODE` is
   `unreachable` — go to Phase 2 with `$MODE=full` and the warning already
   given):

   ```bash
   $SK/state.py get --owner <o> --repo <r> --pr <topNumber> \
     --current-heads "$(jq -c .currentHeads "$CTX")"
   ```

   Exit 3 (`found: false`) = no round on record. Otherwise the output carries
   `lastRound`, `counts`, `openBySeverity`, the folded `open` findings (summary
   fields only — never the proofs), and a recommended `mode` with its `reason`.
5. **Decide `$MODE`** from that output (a `mode=` argument overrides it):

   | State | `$MODE` |
   |---|---|
   | no state file | `full` |
   | `stackShapeChanged: true` (a member was added, removed, or merged out) | `full` — say why; old state can't be diffed against a different stack |
   | `headMoved: true` | `incremental` |
   | `headMoved: false` | **ask** |
   | `delta.unreachable` after Phase 2 (force-push dropped the old head) | `full` — say why |

   In the **ask** case, report the last round (verdict, scores, open counts by
   severity) and put it to the user with `AskUserQuestion`: re-run a full review
   / list the open findings and stop / stop. Nothing has changed since the last
   round, so a fresh fan-out is a choice to spend tokens, not a default.
6. Announce `$MODE`, `$EFFORT` (`auto` until Phase 2 resolves it), and the
   PR(s) in one line before proceeding.

## Phase 1 — Picker (no arg)

1. Query the review queue. ALWAYS reduce the JSON before it enters context —
   never surface raw `reviews`, whose bodies (e.g. CodeRabbit's) run to hundreds
   of KB. Pipe to standalone `jq` with `--arg` so your login is excluded from
   the `others` count (gh's embedded `--jq` cannot take a shell variable):

   ```bash
   ME="$(gh api user --jq .login)"
   gh pr list --search "review-requested:@me is:open" \
     --json number,title,author,reviews,reviewRequests,updatedAt,isDraft \
     --limit 30 \
   | jq -r --arg me "$ME" '.[] | {n:.number, draft:.isDraft, author:.author.login,
       others: (([.reviews[].author.login] + [.reviewRequests[].login]
         | map(select(. != $me and . != null)) | unique | length)),
       upd:.updatedAt, title:(.title[0:70])}
       | "\(.n)\t\(.draft)\tothers=\(.others)\t\(.upd[0:10])\t\(.author)\t\(.title)"' \
   | sort -t$'\t' -k3
   ```

2. **Add the PRs that are waiting on a re-review** — ones with saved state whose
   head has moved since. `$SK/state.py heads` prints
   `owner repo pr sha timestamp kind openCount` per state file; for each row
   compare `sha` against `gh pr view <pr> --json headRefOid`. A moved head means
   unreviewed commits are sitting on top of a review you already did — those
   rank ABOVE anything in the queue you have never looked at, because someone is
   waiting on you.
3. If both lists are empty → say nothing awaits their review; stop.
4. Order: moved-head PRs first (oldest round first), then queue PRs by fewest
   `others`, then oldest `upd`.
5. Present a native multiselect (`AskUserQuestion`, `multiSelect: true`), label =
   `#N title — author` (or `#N title — N new commits since your review`). The
   widget caps at 4 options: with more than 4, present in priority-ordered pages
   of 4, accumulating picks until the user has no more to add.
6. Review each pick from Phase 0 step 3, one at a time.

### Phase 1′ — Auto-select (`auto`)

Same two queries. Rank: (a) a moved head over a never-reviewed PR, (b) fewest
`others`, (c) not `isDraft`, (d) oldest `upd`. Announce the chosen `#N title`
plus a one-line rationale, give the user a chance to veto, then continue.

## Phase 2 — Worktree and ranges

```bash
$SK/pr-context.sh worktree --ctx "$CTX" \
  [--since-heads '<lastRound.heads from Phase 0 step 4>']     # incremental only
```

This fetches every member via its `pull/<N>/head` ref (works for forks, and for
stack branches never pushed under their own name), creates a detached worktree,
and writes back into `$CTX`:

- `worktree` / `repoRoot` — never touch the user's working tree; everything
  happens in the worktree.
- `baseSha`, `range` — the NET review range, `merge-base(base branch, top head)..HEAD`.
  In stack mode this is the whole stack's combined change.
- `segments[]` — per stack member `{pr, from, to, files}`, for Phase 5's
  attribution.
- `netFiles` — every file the PR(s) change against the base branch.
- `delta` — `{unreachable, members[], files[]}` when `--since-heads` was given:
  what moved since the last round.

Then:

```bash
$SK/pr-context.sh files --ctx "$CTX" --set net|delta|segment [--pr N]
$SK/pr-context.sh hunks --ctx "$CTX" --set net|segment|delta [--pr N]  # file<TAB>start<TAB>end
```

**Set `$SCAN` now** — the changed-file list every finder in Phase 4 gets:
`--set net` in full mode, `--set delta` in incremental mode.

**In incremental mode, carry BOTH lists and give both to every finder.** The
DELTA is "what moved since the last round"; the NET is "what this PR changes at
all". They are different sets and conflating them is a live failure mode: a file
can be in the DELTA yet absent from the NET set, because the branch added
something and later removed it, so against the base nothing changed. Tell every
finder plainly: *a file in the delta but not in the NET set is one the PR does
not change; do not claim it introduces, removes or regresses anything, and check
the NET diff before asserting that something "was deleted" or "is now
unpinned".* Without that instruction a finder reasons correctly about the delta
and still lands a confident false positive — a real run flagged a missing test
guard for a "retired" feature flag that had never reached the base branch at
all, because it was added and removed inside the same unmerged PR.

**Stamp `anchorable: true|false` on every finding as it is created**, from the
NET hunk ranges (`hunks --set net`, or `--set segment --pr N` in stack mode).
GitHub anchors inline comments to the PR's own diff, so a line outside every NET
hunk belongs in the review body. Resolve this here — Phase 7 must not be
discovering it at post time.

If `delta.unreachable` is true (a force-push dropped the sha the last round
reviewed), say so and fall back to `$MODE=full` rather than diffing against a
guessed base.

**Resolve `$EFFORT` and the shards — every run, once `$MODE` is final.**

```bash
PROFILE="$($SK/pr-context.sh profile --ctx "$CTX" --set net|delta)"   # the $SCAN set
```

It measures the scan set and returns `codeLines` (changed lines outside tests,
docs and generated files), `surfaces` (the lens-routing surfaces it saw: `ux`,
`contract`, `ops`, `security`), `riskFlags` (`migration`, `auth`,
`tenantScope`, `invariants`, `infra`, `concurrency`, `rawSql`, `publicApi`,
`crypto`), a `tier` with its `reasons`, and
`shards` for Phase 4.

- **Explicit `$EFFORT`** — keep it. Only `shards` is used.
- **`auto`** — start from `tier`, which the script derives by fixed rule:

  | `tier` | When |
  |---|---|
  | `low` | no code lines, or ≤30 code lines with no risk flag and ≤1 surface |
  | `medium` | ≤200 code lines, no risk flag, ≤2 surfaces |
  | `xhigh` | >1500 code lines, ≥4 surfaces, a risk flag on >300 code lines, or ≥2 flags on >100 |
  | `high` | everything else |

  Then read enough of the hunks to judge whether the rule under-rated the PR.
  You may **raise** the tier by ONE step — never lower it, never past `xhigh`
  (`max` is explicit-only). Raise only for a concrete risk a line count cannot
  see, and name it with its location: error classification that gates retries
  or billing, cache invalidation, lock or ordering, tenant scoping in a query,
  a money or quota path, a shared helper with many callers (count them). "Looks
  important" is not a reason. An `auto` resolution to `xhigh` routes Phase 4 to
  the `Workflow` exactly as an explicit one does — these instructions call for
  it, so no separate confirmation.

  Announce one line and proceed without asking — the user can interrupt, and
  `effort=` always overrides: `effort: xhigh (auto — 1,412 code lines; risk:
  migration, auth)`, or `effort: high (auto, raised from medium — retry
  classifier at mcp-client.ts:88)`. Keep that text for the round's
  `effortReason` (Phase 7 step 5).

In incremental mode the profile covers the delta, so a small follow-up to a big
PR is reviewed at a small-PR tier; carried-forward findings are unaffected.

**External review context — always, every round, full or incremental.** Before
dispatching finders, pull what OTHER reviewers and bots have already said on
this PR — human reviewers, CodeRabbit/Greptile/Codex/etc., and the author's own
replies. This is separate from Phase 0 step 4's state lookup, which only knows
what THIS skill said in a prior round.

```bash
gh api repos/{owner}/{repo}/pulls/{N}/reviews \
  --jq '[.[] | {author: .user.login, state, submitted_at, body: (.body[0:300])}]'
gh api repos/{owner}/{repo}/pulls/{N}/comments --paginate \
  --jq '[.[] | {author: .user.login, path, line, created_at, in_reply_to_id, body: (.body[0:300])}]'
```

Reduce before it enters context exactly like Phase 1's picker query — a bot
review body can run to hundreds of KB; a 300-char slice is enough to judge
relevance. Fetch a specific comment's full body (`gh api .../comments/<id>`)
only for a thread you actually need to adjudicate. Exclude this skill's OWN
past reviews (`author == $(gh api user --jq .login)`) — already covered by
Phase 0 step 4.

- **Full mode** — pull everything on the PR.
- **Incremental mode ("between rounds")** — also filter to `created_at` /
  `submitted_at` AFTER the last round's `timestamp` (from Phase 0 step 4): what
  another reviewer or bot said since you last looked, and whether the author
  replied (`in_reply_to_id` pointing at it) or resolved the thread.

Carry a short digest (author, one-line claim, addressed y/n — never raw bodies)
into Phase 5, where it feeds dedupe and adjudication (→ Phase 5 step 2) and,
in incremental mode, a one-line mention in Phase 6's status line. This is a
read-only pass: never reply to, react to, or resolve another reviewer's
thread — see Guardrails.

## Phase 3 — Fix verification (incremental mode only)

Skip entirely in full mode.

Phase 0 step 4 already folded the state file into the currently-open findings —
use that list, never a hand tally. For each open finding:

- **Its file is NOT in the delta file list** → still open, zero cost. Carry it
  forward with no verification. Most findings land here; this is what makes an
  incremental review cheap.
- **Its file IS in the delta** → spot-check it directly. Pull its full record
  (`$SK/state.py show --owner <o> --repo <r> --pr <N> --id <id>`) for the proof and the original
  comment, read the file at the new head around that location, and judge whether
  the flagged problem is actually resolved. One targeted read per finding — not
  a lens subagent, not a full file review. Classify as:
  - `fixed` — the flagged problem is gone.
  - `still-open` — the file changed nearby but the flagged problem is unchanged;
    update the line number if it moved.
  - `still-open`, regressed differently — the fix attempt introduced a
    related-but-different problem at the same spot. Classify the ORIGINAL
    finding as still-open, note it in the write-up, and let Phase 4's scan pick
    up the new problem on its own merits.

A finding the user already declined (`declined: true` in the folded output) is
still open and still worth re-checking if its file moved — but say "declined
earlier" when reporting it instead of re-litigating the decision.

Every finding you actually SPOT-CHECKED becomes one entry in this round's
`resolutions`: `{"id": "<finding id>", "status": "fixed"|"still-open"}`. Use
`still-open-declined` when the user waived it in an earlier round's triage.
Findings you did not check get no entry — they are already open by default, and
a redundant entry just bloats the file.

## Phase 4 — Find

### Step 1 — Checklist scan (direct, NOT a subagent — every effort level)

Read `references/pr-checklist.md` (plus the MUST HAVE / MUST NOT HAVE items in
`$PRH/checklist.local.md`, when it exists) and walk it yourself against `$SCAN` — grep
for the pattern each item names, then read enough surrounding code in the
worktree to confirm or discard the hit. This is cheap (no subagent dispatch) and
catches the violations most likely to actually ship, so it runs even at `low`.
Emit matches in the same shape as a lens finding
(`{ file, line, severity, claim, proof, proposedComment }`) and carry them into
Phase 5 alongside the subagents' findings.

At `$EFFORT` `xhigh`/`max`, this step still runs here, the same way, before
Phase 4′ takes over.

### Step 2 — Routed finder subagents (`low` / `medium` / `high`)

Read `references/review-lenses.md`. Classify `$SCAN` into surfaces (→ Lens
routing), then dispatch the applicable finders IN PARALLEL (one Agent call per
lens GROUP, in a single message) over the worktree. Two lens pairs share one
subagent call each (→ Dispatch grouping) — that grouping is the fan-out cost
lever, not lens count: content wasn't cut, only how many calls carry it.

**Effort-gated fan-out:**
- `low` — ONLY the Always lenses (A+B, D); skip every routed lens regardless of
  match, and skip the Completeness critic. Cheapest path: 2 finder subagents
  (more only if A+B is sharded) plus the free checklist scan.
- `medium` — Always lenses plus routed lenses that CLEARLY match the routing
  table; on a close call, SKIP it (inverting `high`). Completeness critic runs.
- `high` — every applicable routed lens, "when unsure, run it," and
  the Completeness critic always.

- **Always** (any code change, every effort level): Lens A+B as one subagent
  (correctness & subtle bugs), Lens D (test adequacy).
- **Routed** (`medium`/`high`): C (UX), E (contract & compat), G+H as one
  subagent (operability & scale), S (security, never paired with anything).

**Shard A+B when `$PROFILE.shards` is non-empty** (it is only above 1,500
code lines, at any tier): one A+B subagent per shard, up to 3, each REPORTING
only on its shard's `files` but free to read anything. Tell each shard the
other shards' `areas`, and that a defect born of an interaction with another
shard's code is its to report when the faulty line sits in its own files. Every
other lens stays a single call — they cut across the diff by concern, not by
area, and a split would only duplicate their consumer tracing.

Give each subagent: the worktree path, the review range, the **exact `$SCAN`
file list** (plus the NET list in incremental mode, with the warning from Phase
2), and the relevant repo rules (CLAUDE.md / AGENTS.md / `.claude/rules`
excerpts for the touched files — feed each lens only the rules that apply to its
surface). Each returns findings as `{ file, line, severity, claim, proof,
proposedComment, codeSuggestion? }`. Pass `$MODEL` as the Agent tool's `model`
option on every call this phase makes when it is set; otherwise omit it.

**Scope the finders to the scan set** (→ Scope discipline): they may read
anything for context but only REPORT on files in `$SCAN`; drop any finding whose
file isn't in it. This matters most when reviewing a SINGLE stack member, where
the worktree contains earlier parts' code; in stack mode the scan set is the
whole stack's combined diff and per-PR ownership is resolved in Phase 5, not
here.

**Keep the wall-clock down.** The fan-out ends when its slowest member does.
Dispatch right after Phase 2's worktree and external-context pull, and do your
own probing (CI log, vendor docs, a real-library repro) WHILE the lenses run, not
before them; hand each lens the facts you already hold, and fold later finds into
synthesis. Put an explicit budget in Lens D's and Lens E's prompts — about 25
tool calls, scoped test runs only, report partial-but-honest results if cut
short — because on a 7-agent run those two ran 17 and 13 minutes (E used 93
calls) and set the pace.

**Completeness critic — two passes, neither waits on the slowest lens**
(→ Completeness critic; skip both when `$EFFORT` is `low`):

1. **Gap pass — dispatch in the SAME message as the lenses.** It needs the diff,
   the scan set and the PR description, not any finder's output, so there is no
   reason to queue it behind them. Its `findings` enter synthesis like any other;
   each `gap` it names is a high-risk area you MUST spot-check yourself in
   Phase 5.
2. **Refute pass — dispatch as soon as the lenses OTHER than D have returned.**
   Do not wait for Lens D; its mutation runs are the long pole. Give it a short
   digest of the returned finders' *claims* and ask it only to try to break your
   2-3 highest-severity or most-attached findings and to name the weakest claim.
   D's findings arrive later and you adjudicate them yourself in Phase 5
   (reproduce one or two of its mutations — its probes ship with controls).

### Phase 4′ — Workflow-backed deep fan-out (`xhigh` / `max` / `ultracode`)

Replaces step 2 AND Phase 5's adversarial-verification step. Everything else is
unchanged; feed the rest of the flow this phase's output exactly as it would
consume step 2's.

1. Classify lenses exactly as the `high` tier does — this phase changes HOW HARD
   each lens runs and gets checked, never WHICH lenses run. Same dispatch
   grouping (A+B one `agent()` call per shard, G+H one `agent()` call): the grouping is
   what keeps this tier affordable given it also multiplies each call by heavier
   `effort` and, at `max`, duplicate coverage.
2. Call `Workflow` with a script that, for the classified lens groups:
   - Fans out one `agent()` per lens GROUP (`phase: 'Find'`), each carrying
     `effort: $EFFORT` and `model: $MODEL` when set. At `max`, run each lens
     group TWICE independently (`parallel`) and dedupe the two sets before
     verification — redundant coverage of the SAME group, not extra lenses.
   - Adversarially verifies findings (`phase: 'Verify'`): at `xhigh`, one
     refuter pass per Blocker/High finding only (Medium/Low/Nit pass through
     unverified, the same treatment `high` gives them); at `max`, a 3-voter
     refuter panel (majority rules) on EVERY finding. This is the
     token-heaviest tier and is meant to be.
   - Runs the Completeness critic in two parts, same `effort`/`model`: the gap
     pass as one more `agent()` inside the Find `parallel` (it needs no finder
     output), and the refute pass once Find/Verify resolve — never waiting on
     Lens D.
   - Returns `{ findings, critic }`, where `findings` already survived
     adversarial verification.
3. `Workflow` runs in the background — wait for its completion notification;
   don't poll.
4. In Phase 5, treat the returned `findings` as already past the
   adversarial-verification step, and still open every `gap` the critic named.

## Phase 5 — Synthesis (ultrathink)

1. Read `references/comment-style.md` and `references/scoring-rubric.md`.
2. Dedupe findings across lenses AND the checklist scan — a checklist hit and a
   lens finding on the same `file:line` are one finding, not two. In incremental
   mode also dedupe against the carried-forward open findings: a finder
   re-reporting something an earlier round already raised is not new.
   - **Dedupe against the external review context from Phase 2 too.** Never
     open a new inline comment duplicating an OPEN thread another reviewer or
     bot already has on the same `file:line` — if it's unaddressed and
     Blocker/High, name it as a heads-up in the review body instead of a second
     comment. When a lens's finding matches an external one, that's
     corroboration, not redundant noise — post it once and say so. When it
     CONTRADICTS one, adjudicate by primary source (the actual code/vendor
     doc), never by vote-counting, per `review-preferences.md`. Treat an
     author's reply that argued a reviewer down as a claim to verify against
     the code, not a settled fact — it can be correct for an earlier round and
     falsified by a later one.
3. **Adversarially verify each finding** against the checked-out code. Keep only
   findings with concrete proof; drop speculation. This is the false-positive
   filter. At `low`, restrict it to Blocker/High and take Medium/Low/Nit at face
   value; at `medium`/`high`, verify everything; at `xhigh`/`max`, SKIP it —
   Phase 4′ already ran a heavier version and returned only survivors. Checklist
   findings go through this step at every effort level — a grep hit is a
   candidate, not proof.
   - **Never trust a "0 findings" / empty subagent result at face value.** An
     empty result is indistinguishable between "clean" and "the finder missed
     it." Before reporting a file or PR as clean, directly spot-check its
     highest-risk spots yourself (error classification, PII/logging paths,
     injection points, migrations, auth on new endpoints). A real run had
     finders return "clean" twice on a PR that logged an un-redacted field — the
     manual spot-check caught the Medium. At `low`, narrow this to the single
     highest-risk spot in the scan set.
   - **Open every `gap` the Completeness critic named** and spot-check it in the
     checked-out code. Resolve each to a concrete finding or an explicit
     "verified clean" before the verdict. The most load-bearing results this
     skill produces come from these targeted checks, not from the finders'
     scanning. Apply the refute pass's `severityNotes` when you down-reconcile,
     and adjudicate Lens D's findings yourself if the refute pass ran without
     them. (N/A at `low`.)
4. **Signal over volume.** Drop a finding with no real user, operator or
   maintainer impact even though it is technically true — a defense-in-depth
   note with no active leak, a cosmetic style nit, a pre-existing issue the PR
   merely exposed, an unreachable Nit that cannot actually bite. Never suppress
   a verified Blocker/High.
   - **Bias this call by `review-preferences.md`**, loaded in Phase 0. It names
     classes the user reliably posts (a self-consistency Low where the PR
     contradicts its own copy or policy, a security-symmetry gap where one of
     two twin paths gained a guard, an untested failure mode of the fix itself)
     and classes they reliably decline (process/meta notes, doc-comment precision
     on an otherwise clean PR, a convention gap that is repo-wide rather than
     inconsistent with the PR's own code). Where a rule's reasoning is
     load-bearing and its one-liner is not enough, open the section named by its
     `(archive: PR #N)` pointer in `review-preferences-archive.md`.
5. Assign final severities; write each `proposedComment` with the fixed
   template, AND a `chatExplanation` per `references/comment-style.md` → Chat
   explanation (plain English, 2-4 sentences, for the user's own understanding).
   These are two separate pieces of writing — never merge them, and never let
   the explanation's wording leak into `proposedComment`. The explanation is
   NEVER posted to GitHub. **In incremental mode this applies to NEW findings
   only** — a carried-forward still-open finding already has its severity,
   comment and explanation from the round that raised it; reuse them unchanged
   and do not regenerate them.
6. **Stack mode only — attribute each finding to its PR.** Assign every kept
   finding to exactly one stack PR, by these rules in order:
   - **Introducing segment**: the PR whose segment diff contains the flagged
     `file:line` (`pr-context.sh hunks --set segment --pr N`). When several
     segments touched the line, the LAST one that touched it owns the current
     content (`git log --oneline $BASE..HEAD -- <file>` narrows it; `git blame`
     the exact line against HEAD if still ambiguous).
   - **Interaction findings** (correct in each segment alone, wrong in
     combination — e.g. a later segment adds the first caller that makes an
     earlier segment's latent gap real): assign to the LATER segment, the one
     whose landing makes the problem live, and say so in the comment.
   - **Whole-stack findings** (test strategy, deploy ordering, PR-description
     accuracy, off-diff items): assign to the PR they're about when that's
     clear, else to the TOP PR as a body note — never duplicate one finding
     across several PRs.

   Sanity-check it: a finding must fall inside its assigned PR's own segment
   hunks to be an inline comment there; otherwise it goes in that PR's review
   body.
7. **Compute the verdict and scores over the PR's CURRENT full open set** —
   in incremental mode that is carry-forward still-open findings PLUS this
   round's new ones, not just the delta's. This is "how healthy is the PR right
   now". The folded `open` list from Phase 0 step 4 is that set; never tally it
   by hand.

## Phase 6 — Output

Present, in chat. In incremental mode, open with one **status line per moved
PR** — e.g. `#1234: 3 fixed, 1 still open, 2 new` — plus, when Phase 2's
external review context found activity since the last round, one more line
naming who commented and whether the author replied (e.g. `CodeRabbit flagged
X at file:line, unaddressed` or `@teammate approved with a nit`) — then the
fixed and still-open sections below, then the new findings in the standard
shape.

1. **What it does / how — laconic, and CHAT-ONLY.** Before any findings: the
   reviewer needs to know what they're looking at before judging it. Two parts,
   both terse:
   - **What** — one or two sentences. The change in plain terms and why it
     exists. Not the PR title reworded, and not a file-by-file tour.
   - **How** — the mechanism, in at most 3-5 bullets: the actual moving parts
     and where they sit (`file.ts:line`), in the order data flows through them.
     Name the one design decision that shaped the change, if there is one.

   Then a **diagram, only when it earns its place** — a flow, a state machine, a
   data path across layers, a before/after worth seeing. Skip it for a one-liner,
   a config bump, or a purely additive change with no path through it; a diagram
   of a straight line is noise. Plain ASCII, not mermaid — this renders in a
   terminal. Under ~15 lines, labelling the thing the findings point at.

   Budget the whole item at ~150 words plus the diagram. If it runs long, the
   "how" is too detailed. **In incremental mode, scope this to the delta and its
   fix, not the whole PR** — and only draw a diagram if the delta itself has a
   mechanism worth showing. **None of this is ever posted to GitHub.**

2. **Incremental only — fixed findings**: one line each (severity badge,
   one-sentence claim, "now fixed at `file:line`"). Chat-only, nothing to
   triage.
3. **Incremental only — still-open findings**: the same table shape as below, so
   the user sees what is still outstanding. Do NOT re-offer these for posting —
   they were already triaged in an earlier round, and re-offering them is
   exactly the noise this mode exists to avoid.
4. **Suggestions table** (new findings), sorted by severity, highest first —
   plus a **PR** column in stack mode:

   | # | Severity | Location | Proposed comment | Reason | Proof |
   |---|----------|----------|------------------|--------|-------|

5. **Chat explanation** for every row, directly below the table (not in a
   column — 2-4 sentences is too much for a cell). Reuse the `chatExplanation`
   from Phase 5; don't regenerate it here or in Phase 7's triage blocks.
6. **Code suggestions** beneath that, keyed by row #, as ` ```suggestion `
   blocks where anchorable.
7. **Scores & verdict block** per `references/scoring-rubric.md`:
   - Overall NN/100 (weighted).
   - Functional NN · Technical NN · Bug-safety NN · UX NN|N/A.
   - Verdict: APPROVE / REQUEST CHANGES / COMMENT, by the deterministic rule,
     over the current full open set (Phase 5 step 7). This is the
     *recommendation* — Phase 7 puts it to the user as a choice, and the user's
     answer is what gets posted.
8. State plainly, in words, that **nothing has been posted yet** — don't leave
   it implied by the fact that you're about to ask.

**Stack mode:** one output for the whole stack, not one per PR. The what/how
covers the combined change with the per-PR split named in the "how" (one bullet
per member, bottom → top) — that split is usually the most useful thing a stack
diagram can show. Scores are ONE combined block; verdicts are per PR, each
derived from only the findings assigned to that PR.

## Phase 7 — Triage, post, persist, cleanup

If this round produced zero new findings, skip straight to steps 5-6 (persist
and clean up) — no verdict ask, no post. Nothing changed that the user hasn't
already triaged once.

**Both asks below MUST go through the `AskUserQuestion` tool.** Ending the turn
with a prose "tell me which ones to post" is a bug, not a shortcut — never do
it, no matter how few candidates there are or how obvious the recommended set
looks. Two separate asks, in this order: *which comments*, then *which verdict*.
They can share one call when the candidate list fits; otherwise ask comments
first, then verdict.

1. **Triage the comments — `AskUserQuestion`, `multiSelect: true`.** One option
   per candidate, labelled `#N <badge> <short claim>`, ordered by severity, with
   the recommended set named as such in the question text. **Candidates are this
   round's NEW findings only** — carry-forward still-open findings never
   re-enter triage, even if the user asks to "see everything"; point them at the
   still-open table instead. (If they explicitly want to post one of those now,
   that's a signal the original triage call was wrong — handle it as a one-off,
   not as a rule.)

   Immediately BEFORE the call, print each candidate in chat as its own block —
   anchored code snippet, the `chatExplanation` (not just the terse posted
   text), and the exact `proposedComment` that would go to GitHub — so the user
   decides with the plain-English understanding in view, not just a one-line
   label. **Split the candidates by `anchorable`** and say which is which in
   each option's description: an `anchorable: false` finding goes in the review
   body, not `comments[]`, and the user should know that when choosing.

   The widget caps at 4 options per question: with more, page them into several
   questions of ≤4 (severity-ordered, so page 1 carries the most important),
   batchable into one call. **The harness sometimes drops a page's answer in a
   multi-question call — after the call, re-ask by itself any page whose answer
   didn't come back rather than reading silence as decline; if the re-ask also
   comes back empty, post NOTHING from that page.** Let the user reword any
   comment in chat before posting.
2. **Choose the verdict — `AskUserQuestion`, single-select.** Offer, in order:
   the deterministic verdict (first, labelled `(Recommended)`), then any
   defensible alternative given what survived triage (APPROVE-with-inline when
   only optional polish remains; REQUEST CHANGES when a Blocker/High was
   declined), then **"Fix directly, no review"** whenever the PR is the user's
   own (GitHub blocks self-APPROVE, so this is usually right there — name the
   severity mix in the description), then **"Post nothing"**. Never post a
   verdict the user did not pick. If the answer doesn't come back, post nothing.
   - A COMMENT does NOT clear a prior CHANGES_REQUESTED — only an APPROVE does.
     Say so in the option description when the PR already carries one.
   - If "Fix directly" is chosen: implement only verified mechanical/correctness
     fixes, leave design-judgment items as documented decisions, offer any PR
     title/body accuracy edits in the same confirmation, then commit and confirm
     again before pushing.
3. **Re-check the head before posting.** Immediately before the POST, re-read
   every member's `headRefOid` and compare against `$CTX`'s `currentHeads`. A PR
   can be force-pushed or take a base merge mid-review; a line-count shift moves
   anchors, and `gh api .../reviews` will silently accept a line number whose
   content changed underneath it. If a head moved, re-diff old..new per flagged
   file, re-derive the hunk ranges (`pr-context.sh hunks`), and pin `commit_id`
   in the payload. In stack mode re-check EVERY member: a lower branch moving as
   a pure rebase shifts every segment above it.
4. **Post ONE review** with
   `gh api --method POST repos/{owner}/{repo}/pulls/{N}/reviews --input <json>`
   where JSON = `{ "event": "<APPROVE|REQUEST_CHANGES|COMMENT>", "body": "<prose summary + any off-diff findings>", "comments": [ { "path": "...", "line": <n>, "side": "RIGHT", "body": "<template + optional suggestion block>" } ] }`.
   Write the JSON to a temp file and pass it via `--input <file>`.
   - Findings not anchorable to a changed line go into `body`, not `comments`.
   - **Never put the scores in the posted body.** The per-criterion and overall
     numbers are private judgement aids — they stay in chat. The posted review
     carries the prose summary, the verdict action, and the findings.
   - **`chatExplanation` never goes into this JSON** — only `proposedComment`
     and its optional suggestion block.
   - **Stack mode:** at most ONE review per stack PR, each carrying only the
     findings attributed to it. A PR with zero attributed findings gets no
     review — never post an empty placeholder. If fix-directly is chosen
     instead, commit each fix on ITS attributed branch (bottom-up) and restack
     the branches above it — pushing a lower branch without restacking breaks
     the stack. Stack tool: `${user_config.stack_tool}`. If this is `auto` or
     not one of `gh-stack`, `graphite`, `git` (it stays unsubstituted outside a
     plugin install), detect it in the repo, with
     `C=$(git rev-parse --git-common-dir)`: `gh-stack` when `$C/gh-stack`
     exists and `gh stack` runs; else `graphite` when
     `$C/.graphite_repo_config` exists and `gt` is on PATH; else `git`.

     | Tool | Restack from the fixed branch | Push (after the confirm) |
     |---|---|---|
     | `gh-stack` | `gh stack rebase --upstack` | `gh stack push` |
     | `graphite` | `gt restack --upstack` | `gt submit --stack` |
     | `git` | for each branch above, bottom-up: `git rebase --onto <parent> <parent's old tip> <branch>` | `git push --force-with-lease` per rebased branch |

   Then **verify what landed**: fetch the review back
   (`gh api repos/{owner}/{repo}/pulls/{N}/reviews` and `.../pulls/{N}/comments`,
   filtered by `pull_request_review_id` — the per-review `reviews/{id}/comments`
   endpoint omits `line`, so every comment there looks outdated)
   and confirm each inline comment's reported line matches the content it was
   written about. A successful POST is not proof the comment landed where
   intended; fix a mis-anchored one by deleting and reposting with an explicit
   `commit_id`.
5. **Persist the round — every run, every effort level, whatever step 2
   decided.** A "Fix directly" or "Post nothing" outcome still gets one; this is
   the only durable record of what the review found, and the next round's
   incremental mode is built on it.

   **When `$STATE_MODE` is `unreachable`:** print the round JSON in chat instead,
   wrapped in a fenced block, and say it can be filed by saving it to
   `state/pending/<owner>-<repo>-pr-<N>-<UTC timestamp>.json` in the state repo
   (add a `"_target": {"owner": …, "repo": …, "pr": …}` key) — the next local
   `sync` folds it in. Do not silently skip this step.

   Otherwise write the round to a temp file and append:

   ```bash
   $SK/state.py append --owner <o> --repo <r> --pr <topNumber> \
     --round-file /tmp/round.json
   ```

   ```jsonc
   {
     "kind": "full" | "re-review",        // $MODE; "self" is ship-it's pre-PR pass
     "effort": "<$EFFORT>",               // the resolved tier, never "auto"
     "effortReason": "auto — 1,412 code lines; risk: migration",  // or "explicit"
     "heads": { "1234": "<headRefOid actually reviewed, after step 3's re-check>" },
     "stackMembers": null,                 // or [bottom, …, top]
     "verdicts": { "1234": "APPROVE|REQUEST CHANGES|COMMENT" },
     "scores": { "overall": 82, "functional": 85, "technical": 80,
                 "bugSafety": 78, "ux": 90 },
     "posted": true,
     "resolutions": [                      // incremental only, from Phase 3
       { "id": "<finding id>", "status": "fixed|still-open|still-open-declined" }
     ],
     "findings": [                         // NEW findings only — never re-list a
       { "id": "<file>:<line>:<slug-of-claim>",   // carried-forward one
         "file": "…", "line": 42, "prNumber": 1234, "severity": "High",
         "claim": "…", "proof": "…", "proposedComment": "…",
         "chatExplanation": "…", "anchorable": true, "codeSuggestion": null }
     ]
   }
   ```

   The script validates, refuses a duplicate finding id, writes atomically, and
   refreshes the PR's sidecar (`state/summary/…`, which is what claude.ai reads
   instead of the full file); `timestamp` is stamped for you. It appends — it never rewrites an earlier
   round, and neither do you. If the round is written before the post (because
   you want the record in place first), patch the outcome afterwards rather than
   rewriting:

   ```bash
   $SK/state.py amend-last --owner <o> --repo <r> --pr <N> --posted true --head <N>=<sha>
   ```

   `id` must be stable enough for a later round to reference: file + line + a
   short slug of the claim is enough. It does not need to survive renumbering —
   an incremental round re-locates by content, not by line, when the file
   changed.
   **Then update the learned preferences.** Triage is the signal — what the user
   accepted, declined or reworded says more than the review did. When a round
   teaches something durable (a class of finding taken or dropped against your
   expectation, a verdict call you got wrong, a verification method worth
   repeating), distill it to 1-3 sentences — rule + one-clause why + at most one
   example — and add or tighten the matching bullet in `$PRH/review-preferences.md`
   (create it if this is the first lesson).
   Merge into an existing bullet rather than appending a near-duplicate: that
   file reached 36KB once by appending, which is why the hot/cold split exists.
   When the narrative itself is the value, write it into
   `$PRH/review-preferences-archive.md` under a new `## PR #<N> — <label>` section and
   leave a `(archive: PR #N)` pointer on the bullet. "Nothing durable this round"
   is a valid outcome — say so rather than inventing a lesson.

   **Also fold in anything the connector edition left.** List
   `$PRH/state/pending/prefs-*.md`: those are lessons a claude.ai round distilled but
   could not merge itself (it never edits `review-preferences.md` directly — a
   read-modify-write there loses a lesson to a race). For each, merge the rule
   into the right section of `review-preferences.md`, move any narrative to the
   archive, then delete the note. `pending-merge` deliberately leaves them
   alone; it folds `*.json` rounds only.
6. **Share the round** (skip when `$STATE_MODE` is not `shared` — say why).
   `$PRH` is a clone of the user's private state repo, and the claude.ai
   edition reads it through the GitHub connector — so a round only reaches the
   other surface once it is pushed:

   ```bash
   $SK/state.py sync -m "chore(state): review round for <owner>/<repo>#<N>"
   ```

   It pulls, folds in any rounds the claude.ai edition left in `state/pending/`,
   commits `state/` and the preference files, and pushes; it no-ops when nothing changed. A pending
   round that fails validation stops the sync and stays on disk — report it
   rather than deleting it. Skip the sync only when the user has said not to
   push.
7. **Cleanup:** `$SK/pr-context.sh cleanup --ctx "$CTX"`. (`cleanup --stale`
   sweeps worktrees left by runs that died before this step.)

## Guardrails

- Never post without explicit confirmation, and that confirmation is the
  `AskUserQuestion` answers from Phase 7 steps 1-2 — never a prose reply you
  inferred agreement from, and never your own summary of what the user "said".
  At most one review per PR; in stack mode a PR with no attributed findings gets
  none.
- Never modify the user's working tree; always the worktree.
- Never reply to or resolve existing GitHub review threads — that is the
  author's to do. This skill's only GitHub write is posting this round's new
  findings. Phase 2's external-review-context pull (other reviewers, bots,
  the author's replies) is read-only, every round — it informs dedupe and
  adjudication in Phase 5, never a reply, reaction, or resolve.
- Every kept finding carries proof.
- Every finding gets a plain-English `chatExplanation` in addition to its
  `proposedComment`. Two things are chat-only and must never reach GitHub: that
  explanation, and Phase 6 step 1's what/how summary + diagram. Both exist to
  orient the reviewer; the author needs neither.
- Never hand-edit the state file, and never hand-tally what is open. The fold is
  `state.py`'s job precisely because a hand tally is wrong quietly, in the one
  number the user reads as the summary.
- If anything about the delta is ambiguous — a moved member whose old head is
  unreachable, a rebase that rewrote history under the last reviewed sha, a
  stack whose membership changed — say so and fall back to a full review rather
  than diffing against a guessed base.
