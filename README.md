# pr-review

A deep code-review skill for GitHub pull requests. It remembers every round, so a re-review checks only the new commits and whether earlier findings were fixed.

| Edition | Runs on | Depth |
|---|---|---|
| `skills/pr-review/` | Claude Code | full: routed review subagents, a completeness critic, adversarial verification, effort sized from the diff |
| `claude-ai/SKILL.md` | claude.ai, through the GitHub connector | reduced: one model in one context, no subagents |

## Install (Claude Code)

```
/plugin marketplace add kapicic/claude-skills
/plugin install pr-review@kapicic
```

Then run `/pr-review <PR number or URL>` inside the PR's repo, or `/pr-review` alone to pick from your review queue. It needs `gh` (logged in), `git`, `jq` and `python3`.

The install asks one question, `stack_tool`: how to restack a stacked PR's upper branches after you choose "fix directly" on a lower one. Pick `gh-stack`, `graphite` or `git`, or keep `auto`, which detects the tool per repo. Change it later in `/config`.

## Your data

The skill is code. Everything it learns about your reviews lives in `~/.claude/pr-review/`:

```
state/                      one file per reviewed PR: every round and finding
review-preferences.md       what you accept, decline or reword, learned from triage
checklist.local.md          optional: codebase-specific checklist items and lens notes
config.sh                   optional: default repo, path regexes for review surfaces
```

The directory is created on first use and stays local. To share it across machines, and with the claude.ai edition, make it a clone of a **private** repo. `state.py sync` then pulls and pushes it at the end of each round:

```bash
git clone git@github.com:<you>/pr-review-data.git ~/.claude/pr-review
```

Keep that repo private. It holds file paths, code excerpts and review reasoning from the code you review.

### config.sh

```bash
export PR_REVIEW_DEFAULT_REPO=acme/app        # what a bare PR number means outside a checkout
UX_PATHS_RE='^(web|mobile)/'                  # jq regexes over repo-relative paths that
CONTRACT_PATHS_RE='^(api|sdk)/|migrations/'   # route a diff to the UX, contract and
OPS_PATHS_RE='^(server|workers)/'             # operability lenses
```

### checklist.local.md

The checklist pass greps the diff for known mistakes, using `references/pr-checklist.md` plus this file when it exists. Add your codebase's own rules under `## MUST HAVE` and `## MUST NOT HAVE`, for example a PR label that migrations need or a registry that every new table must join. Notes under `## Lens notes` go to the review lens they name.

## Install (claude.ai)

```bash
PR_REVIEW_STATE_REPO=<you>/pr-review-data PR_REVIEW_DEFAULT_REPO=acme/app ./build-zip.sh
```

Upload `dist/pr-review.zip` at **Customize → Skills**. Without the variables, the build makes a stateless edition: every review is a full review, and a bare PR number prompts for the repo. CI builds that stateless zip and attaches it to every `v*` release.

The upload is manual because claude.ai has no API for custom Skills. The zip holds the connector edition and `references/`, without scripts or state. The edition reads your state repo at runtime through the GitHub connector, sees only small summary files, and writes each round to `state/pending/`. The next local `state.py sync` merges those rounds in.

A hosted session (claude.ai/code) can only reach the repos it was started with. Select both the repo under review and your state repo. Otherwise the review runs statelessly and gives you the round JSON to save by hand.

## Scripts

```bash
S=skills/pr-review/scripts
$S/state.py get --owner acme --repo app --pr 1234   # summary + open findings
$S/state.py heads                                    # last-round heads of every PR
$S/state.py validate --all                           # schema + invariant check
$S/state.py sync -m "chore(state): round for acme/app#1234"
$S/pr-context.sh resolve 1234                        # PR(s) → context file
```

Rounds are append-only. `state.py` refuses to rewrite a round or reuse a finding id. It works out which findings are still open from every round's resolutions, so never count them by hand.

## License

MIT
