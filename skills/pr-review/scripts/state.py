#!/usr/bin/env python3
"""Store and retrieve pr-review rounds.

The state file is the only durable record of what a review found. It is
append-only: a round, once written, is never rewritten. Current fixed/open
status is reconstructed by folding every round's `resolutions` forward, never
by editing an earlier record in place.

Commands
  get        summary of a PR's state + folded open findings (exit 3 = no state)
  show       full records (proof/comment/explanation) for named finding ids
  append     append one round, validated, atomically
  amend-last patch posted/heads/verdicts on the LAST round only
  heads      TSV of every state file's last-round heads (picker input)
  validate   schema + invariant check over one file or the whole dir
  doctor     can this environment read and write the store? (exit 4 = no)
  summary    (re)write the small sidecar a connector surface reads instead
  pending-merge  fold rounds dropped in state/pending/ into their state files
  sync       merge pending rounds, then pull/commit/push the state dir
             (and the learned-preference files, when they changed)

Layout: $PR_REVIEW_STATE_DIR (default ~/.claude/pr-review/state)
        <owner>-<repo>-pr-<topNumber>.json

The store lives outside the skill on purpose: the skill is public code, the
store is your private review history. Make ~/.claude/pr-review a clone of a
private repo to share it across machines and with the claude.ai edition;
leave it a plain directory to keep it local.

--owner/--repo default to $PR_REVIEW_DEFAULT_REPO (owner/repo) when set.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

SEVERITIES = ["Blocker", "High", "Medium", "Low", "Nit"]
KINDS = ["full", "re-review", "self"]
# "still-open-declined" = the user was offered it and chose not to act. It
# stays open (the risk is real) but is flagged so a later round can say so
# instead of re-litigating it.
STATUSES = ["fixed", "still-open", "still-open-declined"]

ROUND_REQUIRED = [
    "timestamp",
    "kind",
    "effort",
    "heads",
    "stackMembers",
    "verdicts",
    "scores",
    "posted",
    "findings",
]
FINDING_REQUIRED = [
    "id",
    "file",
    "line",
    "prNumber",
    "severity",
    "claim",
    "proof",
    "proposedComment",
    "chatExplanation",
]
SUMMARY_FIELDS = [
    "id", "file", "line", "prNumber", "severity", "claim", "anchorable", "declined",
]
# The sidecar deliberately carries the same lean fields — measured, adding
# `proof` doubled it (median 8KB -> 16KB, worst case 44KB -> 96KB) to save a
# fetch that fix-verification rarely needs: the claim plus the current code
# answers "is this fixed?", and the old code is in the PR's own diff anyway.
SIDECAR_FIELDS = SUMMARY_FIELDS


def state_dir() -> Path:
    return Path(
        os.environ.get("PR_REVIEW_STATE_DIR", Path.home() / ".claude/pr-review/state")
    ).expanduser()


def default_repo() -> tuple[str | None, str | None]:
    owner, _, repo = os.environ.get("PR_REVIEW_DEFAULT_REPO", "").partition("/")
    return owner or None, repo or None


def state_path(owner: str | None, repo: str | None, pr: int) -> Path:
    if not owner or not repo:
        die("pass --owner and --repo (or set PR_REVIEW_DEFAULT_REPO=owner/repo)", 2)
    return state_dir() / f"{owner}-{repo}-pr-{pr}.json"


def summary_path(owner: str, repo: str, pr: int) -> Path:
    """The sidecar: everything `get` returns except the proofs and comments.

    A full state file grows to hundreds of KB. Fetching one through a
    connector materializes all of it in the model's context — the exact cost
    `get` exists to avoid. The sidecar is a few KB and answers every question
    a review asks before it needs a specific finding's proof.
    """
    return state_dir() / "summary" / f"{owner}-{repo}-pr-{pr}.json"


def store_git_root(d: Path) -> str | None:
    """The git repo that holds the store, if the store is that repo or its
    top-level `state/` — never an enclosing repo such as dotfiles at ~."""
    import subprocess

    r = subprocess.run(["git", "-C", str(d), "rev-parse", "--show-toplevel"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    root = Path(r.stdout.strip()).resolve()
    return str(root) if root in (d.resolve(), d.resolve().parent) else None


def pending_dir() -> Path:
    """Rounds written by a surface that cannot safely rewrite the whole file.

    The connector edition PUTs one small round here instead of fetching,
    mutating and pushing back the full history. `pending-merge` folds them in
    locally, where validation has the whole file to check against.
    """
    return state_dir() / "pending"


def load(path: Path) -> dict:
    with path.open() as fh:
        return json.load(fh)


def write_atomic(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(doc, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def summarize(doc: dict, path: Path, fields: list[str] = SUMMARY_FIELDS) -> dict:
    """The static half of `get`: everything but the head comparison."""
    rounds = doc.get("rounds") or []
    last = rounds[-1] if rounds else {}
    open_findings, fixed = fold(doc)
    return {
        "found": True,
        "path": str(path),
        "owner": doc.get("owner"),
        "repo": doc.get("repo"),
        "topNumber": doc.get("topNumber"),
        "stackMembers": last.get("stackMembers"),
        "roundCount": len(rounds),
        "kinds": [r.get("kind") for r in rounds],
        "lastRound": {
            k: last.get(k)
            for k in (
                "timestamp", "kind", "effort", "effortReason", "surface", "heads", "verdicts",
                "scores", "posted",
            )
            if k in last
        },
        "counts": {
            "totalFindings": sum(len(r.get("findings") or []) for r in rounds),
            "fixed": len(fixed),
            "open": len(open_findings),
            "declined": sum(1 for f in open_findings if f.get("declined")),
        },
        "openBySeverity": by_severity(open_findings),
        "open": [{k: f.get(k) for k in fields + ["round"]} for f in open_findings],
    }


def write_summary(owner: str, repo: str, pr: int, doc: dict) -> Path:
    path = summary_path(owner, repo, pr)
    write_atomic(path, summarize(doc, state_path(owner, repo, pr), SIDECAR_FIELDS))
    return path


def die(msg: str, code: int = 1) -> None:
    print(f"state.py: {msg}", file=sys.stderr)
    sys.exit(code)


# --------------------------------------------------------------------------
# folding
# --------------------------------------------------------------------------


def fold(doc: dict) -> tuple[list[dict], set[str]]:
    """Return (open findings, fixed ids).

    A finding is fixed if the LATEST round whose resolutions mention its id
    says "fixed"; otherwise it is open. Later rounds win over earlier ones.
    An open finding whose latest status is "still-open-declined" is marked
    `declined` — still open, but already offered and waived once.
    """
    status: dict[str, str] = {}
    findings: list[dict] = []
    for idx, rnd in enumerate(doc.get("rounds", [])):
        for f in rnd.get("findings", []):
            findings.append({**f, "round": idx})
        for res in rnd.get("resolutions") or []:
            if "id" in res and res.get("status") in STATUSES:
                status[res["id"]] = res["status"]

    fixed = {fid for fid, st in status.items() if st == "fixed"}
    declined = {fid for fid, st in status.items() if st == "still-open-declined"}
    open_findings = [
        {**f, "declined": f["id"] in declined}
        for f in findings
        if f["id"] not in fixed
    ]
    open_findings.sort(
        key=lambda f: (
            SEVERITIES.index(f["severity"]) if f.get("severity") in SEVERITIES else 99,
            f.get("file", ""),
            f.get("line") or 0,
        )
    )
    return open_findings, fixed


def by_severity(findings: list[dict]) -> dict[str, int]:
    counts = {s: 0 for s in SEVERITIES}
    for f in findings:
        sev = f.get("severity")
        if sev in counts:
            counts[sev] += 1
    return {k: v for k, v in counts.items() if v}


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------


def validate_round(rnd: dict, known_ids: set[str], where: str) -> list[str]:
    errs = []
    for key in ROUND_REQUIRED:
        if key not in rnd:
            errs.append(f"{where}: missing required key '{key}'")
    if rnd.get("kind") not in KINDS:
        errs.append(f"{where}: kind must be one of {KINDS}, got {rnd.get('kind')!r}")
    if not isinstance(rnd.get("heads"), dict) or not rnd.get("heads"):
        errs.append(f"{where}: heads must be a non-empty object of prNumber -> sha")
    else:
        for pr, sha in rnd["heads"].items():
            if not isinstance(sha, str) or len(sha) < 7:
                errs.append(f"{where}: heads['{pr}'] is not a sha ({sha!r})")
    if rnd.get("stackMembers") is not None and not isinstance(
        rnd.get("stackMembers"), list
    ):
        errs.append(f"{where}: stackMembers must be null or a list of PR numbers")
    if not isinstance(rnd.get("posted"), bool):
        errs.append(f"{where}: posted must be a boolean")

    seen = set(known_ids)
    for i, f in enumerate(rnd.get("findings") or []):
        fw = f"{where}.findings[{i}]"
        for key in FINDING_REQUIRED:
            if key not in f:
                errs.append(f"{fw}: missing required key '{key}'")
        if f.get("severity") not in SEVERITIES:
            errs.append(f"{fw}: severity must be one of {SEVERITIES}")
        fid = f.get("id")
        if fid in seen:
            errs.append(
                f"{fw}: duplicate finding id {fid!r} — a re-review must not re-list a "
                "carried-forward finding; only genuinely new findings go in `findings`"
            )
        seen.add(fid)

    for i, res in enumerate(rnd.get("resolutions") or []):
        rw = f"{where}.resolutions[{i}]"
        if res.get("status") not in STATUSES:
            errs.append(f"{rw}: status must be one of {STATUSES}")
        if res.get("id") not in seen:
            errs.append(
                f"{rw}: resolution references unknown finding id {res.get('id')!r}"
            )
    return errs


def validate_doc(doc: dict, where: str) -> list[str]:
    errs = []
    for key in ("owner", "repo", "topNumber", "rounds"):
        if key not in doc:
            errs.append(f"{where}: missing top-level key '{key}'")
    known: set[str] = set()
    for i, rnd in enumerate(doc.get("rounds") or []):
        errs += validate_round(rnd, known, f"{where}.rounds[{i}]")
        known |= {f.get("id") for f in rnd.get("findings") or []}
    return errs


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------


def cmd_get(args) -> int:
    path = state_path(args.owner, args.repo, args.pr)
    if not path.exists():
        json.dump(
            {
                "found": False,
                "path": str(path),
                "owner": args.owner,
                "repo": args.repo,
                "topNumber": args.pr,
                "mode": "full",
                "reason": "no prior round on record",
            },
            sys.stdout,
            indent=2,
        )
        print()
        return 3

    doc = load(path)
    if not (doc.get("rounds") or []):
        die(f"{path}: state file has no rounds", 1)
    last = doc["rounds"][-1]
    out = summarize(doc, path)

    if args.current_heads:
        try:
            current = json.loads(args.current_heads)
        except json.JSONDecodeError as exc:
            die(f"--current-heads is not valid JSON: {exc}", 2)
        recorded = last.get("heads") or {}
        moved = [
            {"pr": int(pr), "from": recorded.get(str(pr)), "to": sha}
            for pr, sha in current.items()
            if recorded.get(str(pr)) != sha
        ]
        out["movedMembers"] = moved
        out["headMoved"] = bool(moved)
        stack_now = sorted(int(p) for p in current)
        stack_then = sorted(int(p) for p in recorded)
        out["stackShapeChanged"] = stack_now != stack_then
        if out["stackShapeChanged"]:
            out["mode"] = "full"
            out["reason"] = (
                f"stack membership changed since last round ({stack_then} -> {stack_now})"
            )
        elif moved:
            out["mode"] = "incremental"
            out["reason"] = f"{len(moved)} member(s) moved since last round"
        else:
            out["mode"] = "ask"
            out["reason"] = "nothing moved since the last round"

    json.dump(out, sys.stdout, indent=2)
    print()
    return 0


def cmd_show(args) -> int:
    path = state_path(args.owner, args.repo, args.pr)
    if not path.exists():
        die(f"no state file at {path}", 3)
    doc = load(path)
    wanted = set(args.id or [])
    findings = [
        {**f, "round": i}
        for i, r in enumerate(doc.get("rounds") or [])
        for f in r.get("findings") or []
    ]
    if wanted:
        picked = [f for f in findings if f["id"] in wanted]
        missing = wanted - {f["id"] for f in picked}
        if missing:
            die(f"unknown finding id(s): {sorted(missing)}", 1)
    else:
        picked, _ = fold(doc)
        picked = [f for f in findings if f["id"] in {p["id"] for p in picked}]
    json.dump(picked, sys.stdout, indent=2)
    print()
    return 0


def cmd_append(args) -> int:
    raw = (
        Path(args.round_file).read_text()
        if args.round_file and args.round_file != "-"
        else sys.stdin.read()
    )
    try:
        rnd = json.loads(raw)
    except json.JSONDecodeError as exc:
        die(f"round is not valid JSON: {exc}", 2)

    rnd.setdefault("timestamp", datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    rnd.setdefault("stackMembers", None)
    rnd.setdefault("findings", [])

    path = state_path(args.owner, args.repo, args.pr)
    if path.exists():
        doc = load(path)
    else:
        doc = {
            "owner": args.owner,
            "repo": args.repo,
            "topNumber": args.pr,
            "rounds": [],
        }

    known = {
        f.get("id") for r in doc["rounds"] for f in r.get("findings") or []
    }
    errs = validate_round(rnd, known, "round")
    if errs:
        for e in errs:
            print(f"state.py: {e}", file=sys.stderr)
        die(f"{len(errs)} validation error(s) — nothing written", 2)

    if doc["rounds"]:
        prev = doc["rounds"][-1]
        if prev == rnd:
            die(
                "this round is identical to the last one — a double append, not a "
                "new round. Rounds are immutable; use amend-last to patch "
                "posted/heads/verdicts on the round already written.",
                2,
            )

    doc["rounds"].append(rnd)
    write_atomic(path, doc)
    sidecar = write_summary(args.owner, args.repo, args.pr, doc)
    open_findings, fixed = fold(doc)
    json.dump(
        {
            "ok": True,
            "path": str(path),
            "summary": str(sidecar),
            "roundIndex": len(doc["rounds"]) - 1,
            "newFindings": len(rnd["findings"]),
            "resolutions": len(rnd.get("resolutions") or []),
            "open": len(open_findings),
            "fixed": len(fixed),
            "openBySeverity": by_severity(open_findings),
        },
        sys.stdout,
        indent=2,
    )
    print()
    return 0


def cmd_amend_last(args) -> int:
    path = state_path(args.owner, args.repo, args.pr)
    if not path.exists():
        die(f"no state file at {path}", 3)
    doc = load(path)
    if not doc.get("rounds"):
        die(f"{path}: no rounds to amend", 1)
    last = doc["rounds"][-1]

    changed = []
    if args.posted is not None:
        last["posted"] = args.posted == "true"
        changed.append(f"posted={args.posted}")
    for pair in args.head or []:
        pr, _, sha = pair.partition("=")
        if not sha:
            die(f"--head expects <pr>=<sha>, got {pair!r}", 2)
        last.setdefault("heads", {})[pr] = sha
        changed.append(f"heads[{pr}]={sha[:8]}")
    for pair in args.verdict or []:
        pr, _, verdict = pair.partition("=")
        if not verdict:
            die(f"--verdict expects <pr>=<VERDICT>, got {pair!r}", 2)
        last.setdefault("verdicts", {})[pr] = verdict
        changed.append(f"verdicts[{pr}]={verdict}")

    if not changed:
        die("nothing to amend — pass --posted, --head and/or --verdict", 2)

    write_atomic(path, doc)
    write_summary(args.owner, args.repo, args.pr, doc)
    json.dump({"ok": True, "path": str(path), "changed": changed}, sys.stdout, indent=2)
    print()
    return 0


def cmd_heads(args) -> int:
    for path in sorted(state_dir().glob("*.json")):
        try:
            doc = load(path)
        except json.JSONDecodeError:
            print(f"# unreadable: {path}", file=sys.stderr)
            continue
        rounds = doc.get("rounds") or []
        if not rounds:
            continue
        last = rounds[-1]
        open_findings, _ = fold(doc)
        for pr, sha in (last.get("heads") or {}).items():
            print(
                "\t".join(
                    [
                        str(doc.get("owner")),
                        str(doc.get("repo")),
                        str(pr),
                        str(sha),
                        str(last.get("timestamp")),
                        str(last.get("kind")),
                        str(len(open_findings)),
                    ]
                )
            )
    return 0


def cmd_doctor(args) -> int:
    """Report whether this environment can actually use the store.

    An unreachable store is indistinguishable from a PR with no prior round —
    both look like "do a full review" — so a session that cannot reach it will
    happily review and then fail to record anything. Ask first, and say which
    of the three states you are in:

      shared      the store is present and pushable; normal operation
      local-only  present and writable, but the remote is out of reach; rounds
                  are recorded locally and pushed later by a session that can
      unreachable no store at all (a cloud session scoped to another repo);
                  review statelessly and hand the round back to the user
    """
    import shutil
    import subprocess

    d = state_dir()
    # First use on a workstation: create the store. Not in a cloud sandbox
    # (CLAUDE_CODE_REMOTE), where a fresh local store dies with the session —
    # there "unreachable" is the honest answer, and the round gets printed.
    created = False
    if not d.exists() and not os.environ.get("CLAUDE_CODE_REMOTE"):
        try:
            d.mkdir(parents=True)
            created = True
        except OSError:
            pass
    report = {"stateDir": str(d), "exists": d.is_dir(), "created": created,
              "writable": False, "git": None, "remote": None, "pending": 0, "prs": 0}

    if report["exists"]:
        report["prs"] = len(list(d.glob("*.json")))
        report["pending"] = len(list(pending_dir().glob("*.json"))) if pending_dir().is_dir() else 0
        probe = d / ".doctor-probe"
        try:
            probe.write_text("")
            probe.unlink()
            report["writable"] = True
        except OSError as exc:
            report["writeError"] = str(exc)

    if report["exists"] and shutil.which("git"):
        root = store_git_root(d)
        if root:
            report["git"] = root
            ls = subprocess.run(["git", "-C", report["git"], "ls-remote", "--exit-code",
                                 "origin", "HEAD"], capture_output=True, text=True,
                                timeout=args.timeout)
            report["remote"] = ls.returncode == 0
            if ls.returncode != 0:
                report["remoteError"] = (ls.stderr or "").strip()[:200]

    if not report["exists"] or not report["writable"]:
        report["stateMode"] = "unreachable"
    elif report["git"] and report["remote"]:
        report["stateMode"] = "shared"
    else:
        report["stateMode"] = "local-only"

    report["advice"] = {
        "shared": "Normal operation: read state, record the round, sync.",
        "local-only": ("Record the round locally; say it is unpushed. A session "
                       "with remote access syncs it later.") if report["git"] else
                      ("Record the round locally. The store is not a git repo, so "
                       "local is its normal state — nothing to push or mention."),
        "unreachable": "No store here. Say so BEFORE reviewing — findings will "
                       "not be recorded and a re-review cannot be incremental. "
                       "Print the round JSON at the end so it can be filed by "
                       "hand or dropped into state/pending/.",
    }[report["stateMode"]]

    json.dump(report, sys.stdout, indent=2)
    print()
    return 0 if report["stateMode"] == "shared" else 4


def cmd_summary(args) -> int:
    """(Re)write sidecars. --all backfills every state file."""
    if args.all:
        paths = sorted(state_dir().glob("*.json"))
    else:
        if args.pr is None:
            die("summary needs --pr or --all", 2)
        paths = [state_path(args.owner, args.repo, args.pr)]

    written = []
    for path in paths:
        if not path.exists():
            die(f"no state file at {path}", 3)
        doc = load(path)
        if not (doc.get("rounds") or []):
            continue
        written.append(
            str(write_summary(doc["owner"], doc["repo"], doc["topNumber"], doc))
        )
    json.dump({"ok": True, "written": len(written)}, sys.stdout, indent=2)
    print()
    return 0


def cmd_pending_merge(args) -> int:
    """Fold rounds a connector surface dropped in state/pending/ into place.

    A surface that can only PUT small files writes one round here rather than
    fetching, mutating and pushing back a full state file. Each pending round
    carries a `_target` naming where it belongs; merging happens here, where
    the whole file is available for the duplicate-id and append-only checks.

    Only *.json is folded. The connector edition also drops prefs-*.md notes
    here — learned-preference lessons it cannot merge itself — and those are
    left in place on purpose, for the skill's Phase 7 to fold into
    review-preferences.md by hand. Do not treat them as junk.
    """
    d = pending_dir()
    files = sorted(d.glob("*.json")) if d.exists() else []
    if not files:
        print(json.dumps({"ok": True, "merged": 0, "reason": "nothing pending"}))
        return 0

    merged, failed = [], []
    for f in files:
        try:
            rnd = json.loads(f.read_text())
        except json.JSONDecodeError as exc:
            failed.append({"file": f.name, "error": f"unparseable: {exc}"})
            continue

        target = rnd.pop("_target", None)
        if not isinstance(target, dict) or not all(
            k in target for k in ("owner", "repo", "pr")
        ):
            failed.append({"file": f.name, "error": "missing or malformed _target"})
            continue

        owner, repo, pr = target["owner"], target["repo"], int(target["pr"])
        path = state_path(owner, repo, pr)
        doc = (
            load(path)
            if path.exists()
            else {"owner": owner, "repo": repo, "topNumber": pr, "rounds": []}
        )
        rnd.setdefault(
            "timestamp", datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        )
        rnd.setdefault("stackMembers", None)
        rnd.setdefault("findings", [])

        known = {x.get("id") for r in doc["rounds"] for x in r.get("findings") or []}
        errs = validate_round(rnd, known, f.name)
        if errs:
            failed.append({"file": f.name, "error": "; ".join(errs)})
            continue
        if doc["rounds"] and doc["rounds"][-1] == rnd:
            failed.append({"file": f.name, "error": "identical to the last round"})
            continue

        doc["rounds"].append(rnd)
        write_atomic(path, doc)
        write_summary(owner, repo, pr, doc)
        f.unlink()
        merged.append({"file": f.name, "into": path.name})

    json.dump(
        {"ok": not failed, "merged": merged, "failed": failed}, sys.stdout, indent=2
    )
    print()
    # A rejected pending round is left in place on purpose — it is someone's
    # review, and dropping it silently would lose it.
    return 1 if failed else 0


def cmd_sync(args) -> int:
    """Share the store: pull, then commit and push whatever changed.

    The state dir is tracked in the skill's own repo, so a round written here
    reaches the GitHub connector (and therefore claude.ai) only once it is
    pushed. Called at the end of a round; safe to call when nothing changed.

    Phase 7 also writes back to review-preferences.md (and, less often, the
    archive), so those ride along here — otherwise a round's learned lesson
    stays on one machine while the round itself is shared.
    """
    import subprocess

    d = state_dir()
    root = store_git_root(d)
    if not root:
        # A plain local store is a supported setup, not an error: the round is
        # already on disk, there is just nowhere to push it.
        print(json.dumps({"ok": True, "pushed": False,
                          "reason": f"{d} is a local store, not a git repo"}))
        return 0

    def git(*a, check=True):
        r = subprocess.run(["git", "-C", root, *a], capture_output=True, text=True)
        if check and r.returncode != 0:
            die(f"git {' '.join(a)} failed: {r.stderr.strip()}", 1)
        return r.stdout.strip()

    # --autostash: a review often finishes while the skill itself is being
    # edited, and a plain rebase refuses to run with a dirty tree — which would
    # fail the sync at the very last step of an otherwise finished review.
    git("pull", "--rebase", "--autostash", "--quiet")

    # A pull can bring in rounds another surface left pending; fold them in
    # before deciding there is nothing to commit.
    pending = argparse.Namespace()
    if cmd_pending_merge(pending) != 0:
        die("pending rounds failed to merge — resolve them before syncing", 1)

    # Anchored on the repo git is actually committing to, not on d.parent —
    # PR_REVIEW_STATE_DIR can move the store out of the skill directory, and
    # staging a path outside `root` would fail the sync.
    paths = [str(d)] + [
        str(pref)
        for pref in (
            Path(root) / "review-preferences.md",
            Path(root) / "review-preferences-archive.md",
        )
        if pref.exists()
    ]
    if not git("status", "--porcelain", "--", *paths):
        print(json.dumps({"ok": True, "pushed": False, "reason": "no state changes"}))
        return 0
    git("add", "--", *paths)
    git("commit", "--quiet", "-m", args.message)
    git("push", "--quiet")
    print(json.dumps({"ok": True, "pushed": True, "head": git("rev-parse", "HEAD")[:8]}))
    return 0


def cmd_validate(args) -> int:
    paths = (
        sorted(state_dir().glob("*.json"))
        if args.all
        else [state_path(args.owner, args.repo, args.pr)]
    )
    total = 0
    for path in paths:
        if not path.exists():
            die(f"no state file at {path}", 3)
        try:
            doc = load(path)
        except json.JSONDecodeError as exc:
            print(f"{path.name}: unparseable JSON — {exc}")
            total += 1
            continue
        errs = validate_doc(doc, path.name)
        kinds = [r.get("kind") for r in doc.get("rounds") or []]
        if kinds.count("full") > 1:
            errs.append(
                f"{path.name}: {kinds.count('full')} 'full' rounds — a second full "
                "review carries no resolutions, so every earlier finding stays open "
                "forever. Re-reviews should be kind='re-review'."
            )
        for e in errs:
            print(e)
        total += len(errs)
    print(f"{len(paths)} file(s), {total} problem(s)")
    return 1 if total else 0


def main() -> int:
    p = argparse.ArgumentParser(prog="state.py", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    owner, repo = default_repo()

    def common(sp):
        sp.add_argument("--owner", default=owner)
        sp.add_argument("--repo", default=repo)
        sp.add_argument("--pr", type=int, required=True, help="top PR number")

    g = sub.add_parser("get", help="summary + folded open findings")
    common(g)
    g.add_argument(
        "--current-heads",
        help='JSON map of current heads, e.g. \'{"10564":"abc123"}\' — adds '
        "headMoved/movedMembers/stackShapeChanged and the recommended mode",
    )
    g.set_defaults(fn=cmd_get)

    s = sub.add_parser("show", help="full records for finding ids (default: all open)")
    common(s)
    s.add_argument("--id", action="append", help="repeatable")
    s.set_defaults(fn=cmd_show)

    a = sub.add_parser("append", help="append one validated round")
    common(a)
    a.add_argument("--round-file", default="-", help="path or - for stdin")
    a.set_defaults(fn=cmd_append)

    m = sub.add_parser("amend-last", help="patch posted/heads/verdicts on the last round")
    common(m)
    m.add_argument("--posted", choices=["true", "false"])
    m.add_argument("--head", action="append", metavar="PR=SHA")
    m.add_argument("--verdict", action="append", metavar="PR=VERDICT")
    m.set_defaults(fn=cmd_amend_last)

    h = sub.add_parser("heads", help="TSV: owner repo pr sha timestamp kind openCount")
    h.set_defaults(fn=cmd_heads)

    dr = sub.add_parser("doctor", help="can this environment read/write the store?")
    dr.add_argument("--timeout", type=float, default=10.0,
                    help="seconds to wait on the remote probe")
    dr.set_defaults(fn=cmd_doctor)

    m2 = sub.add_parser("summary", help="(re)write the connector-facing sidecar")
    m2.add_argument("--owner", default=owner)
    m2.add_argument("--repo", default=repo)
    m2.add_argument("--pr", type=int)
    m2.add_argument("--all", action="store_true")
    m2.set_defaults(fn=cmd_summary)

    pm = sub.add_parser(
        "pending-merge", help="fold state/pending/*.json rounds into their files"
    )
    pm.set_defaults(fn=cmd_pending_merge)

    y = sub.add_parser("sync", help="merge pending rounds, then pull/commit/push")
    y.add_argument(
        "--message", "-m", default="chore(state): record review round",
        help="commit message",
    )
    y.set_defaults(fn=cmd_sync)

    v = sub.add_parser("validate", help="schema + invariant check")
    v.add_argument("--all", action="store_true")
    v.add_argument("--owner", default=owner)
    v.add_argument("--repo", default=repo)
    v.add_argument("--pr", type=int)
    v.set_defaults(fn=cmd_validate)

    args = p.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
