#!/usr/bin/env bash
# pr-context.sh — the git/gh plumbing behind a pr-review round.
#
# Everything deterministic about "what am I reviewing" lives here: argument
# resolution, stack-chain detection, the isolated worktree, the review range,
# per-stack-member segments, and the delta since a previous round's heads.
#
#   resolve  <spec>...              -> writes a context file, prints it
#   worktree --ctx <f> [--since-heads <json>]
#                                   -> creates the worktree, adds ranges to ctx
#   files    --ctx <f> [--set net|delta] [--pr N]
#   hunks    --ctx <f> [--set net|delta] [--pr N]
#   profile  --ctx <f> [--set net|delta]
#                                   -> size, surfaces, risk flags, auto tier, shards
#   cleanup  --ctx <f> | --stale     (--stale sweeps leaked worktrees)
#
# A <spec> is a bare PR number (in $PR_REVIEW_DEFAULT_REPO, else the GitHub
# repo of the current checkout) or a GitHub PR URL. Several specs that chain
# base->head are detected as a stack and reviewed as one change.
#
# Context files live in $PR_REVIEW_RUN_DIR (default $TMPDIR/pr-review-run).
#
# $PR_REVIEW_HOME/config.sh (default ~/.claude/pr-review/config.sh), when it
# exists, is sourced first: set PR_REVIEW_DEFAULT_REPO or override the
# UX_PATHS_RE / CONTRACT_PATHS_RE / OPS_PATHS_RE surface regexes there to fit
# your codebase's layout.

set -euo pipefail

PR_REVIEW_HOME="${PR_REVIEW_HOME:-$HOME/.claude/pr-review}"
# shellcheck source=/dev/null
[ -f "$PR_REVIEW_HOME/config.sh" ] && . "$PR_REVIEW_HOME/config.sh"

DEFAULT_REPO="${PR_REVIEW_DEFAULT_REPO:-}"
RUN_DIR="${PR_REVIEW_RUN_DIR:-${TMPDIR:-/tmp}/pr-review-run}"
CLONE_CACHE="${PR_REVIEW_CLONE_CACHE:-$PR_REVIEW_HOME/repos}"

# Which paths count as which review surface. jq regexes over repo-relative
# paths; the defaults guess common layouts.
UX_PATHS_RE="${UX_PATHS_RE:-(^|/)(frontend|web|ui|client|app|components|pages|views)/|\.(tsx|jsx|vue|svelte|css|scss)$}"
CONTRACT_PATHS_RE="${CONTRACT_PATHS_RE:-(^|/)(api|apis|proto|protos|schemas?|sdk|contracts?|shared)/|(^|/)migrations/|openapi|\.proto$|\.types\.ts$}"
OPS_PATHS_RE="${OPS_PATHS_RE:-(^|/)(server|backend|services?|workers?|jobs?|queues?|cron)/|repositor}"

die() { echo "pr-context.sh: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

need gh
need jq
need git

# ---------------------------------------------------------------------------
# resolve
# ---------------------------------------------------------------------------

parse_spec() { # <spec> -> "owner repo number"
  local spec="$1"
  if [[ "$spec" =~ ^[0-9]+$ ]]; then
    if [ -z "$DEFAULT_REPO" ]; then
      DEFAULT_REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
        || die "bare PR number outside a GitHub checkout: pass a PR URL or set PR_REVIEW_DEFAULT_REPO=owner/repo"
    fi
    echo "${DEFAULT_REPO%/*} ${DEFAULT_REPO#*/} $spec"
  elif [[ "$spec" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
  else
    die "cannot parse PR spec: $spec (want a number or a GitHub PR URL)"
  fi
}

cmd_resolve() {
  [ $# -gt 0 ] || die "resolve needs at least one PR spec"

  local owner="" repo="" numbers=() o r n
  for spec in "$@"; do
    read -r o r n <<<"$(parse_spec "$spec")"
    if [ -z "$owner" ]; then
      owner="$o"; repo="$r"
    elif [ "$o/$r" != "$owner/$repo" ]; then
      die "all PRs must be in the same repo (got $owner/$repo and $o/$r)"
    fi
    numbers+=("$n")
  done

  local members="[]"
  for n in "${numbers[@]}"; do
    local pr
    pr="$(gh pr view "$n" --repo "$owner/$repo" \
      --json number,title,baseRefName,headRefName,headRefOid,isDraft,url,state,author \
      | jq -c '{number, title, base: .baseRefName, head: .headRefName,
                headOid: .headRefOid, isDraft, url, state, author: .author.login}')"
    members="$(jq -c --argjson m "$pr" '. + [$m]' <<<"$members")"
  done

  # Chain detection: a set is a stack when each member's base is another
  # member's head, bottoming out at exactly one member whose base is not.
  local is_stack base_branch
  is_stack=false
  if [ "${#numbers[@]}" -gt 1 ]; then
    local bottoms
    bottoms="$(jq -r '[.[].head] as $h | [.[] | select(.base as $b | ($h|index($b))==null) | .number] | join(" ")' <<<"$members")"
    if [ "$(wc -w <<<"$bottoms")" -eq 1 ]; then
      local chain=() cur="$bottoms" guard=0 nxt
      while [ -n "$cur" ]; do
        chain+=("$cur")
        local curhead
        curhead="$(jq -r --argjson n "$cur" '.[] | select(.number==$n) | .head' <<<"$members")"
        nxt="$(jq -r --arg h "$curhead" '[.[] | select(.base==$h) | .number] | .[0] // empty' <<<"$members")"
        cur="$nxt"
        guard=$((guard + 1))
        [ "$guard" -le "${#numbers[@]}" ] || die "cycle detected while walking the stack"
      done
      if [ "${#chain[@]}" -eq "${#numbers[@]}" ]; then
        is_stack=true
        local reordered="[]"
        for n in "${chain[@]}"; do
          reordered="$(jq -c --argjson n "$n" '. + [$m[] | select(.number==$n)]' --argjson m "$members" <<<"$reordered")"
        done
        members="$reordered"
      fi
    fi
  fi

  base_branch="$(jq -r '.[0].base' <<<"$members")"
  if [ "$is_stack" = false ] && [ "${#numbers[@]}" -gt 1 ]; then
    base_branch="$(jq -r '[.[].base] | unique | .[0]' <<<"$members")"
  fi

  local top
  top="$(jq -r '.[-1].number' <<<"$members")"

  mkdir -p "$RUN_DIR"
  local ctx="$RUN_DIR/$owner-$repo-pr-$top.ctx.json"
  jq -n --arg owner "$owner" --arg repo "$repo" --argjson top "$top" \
        --argjson members "$members" --arg base "$base_branch" \
        --argjson isStack "$is_stack" \
    '{owner: $owner, repo: $repo, topNumber: $top, isStack: $isStack,
      baseBranch: $base, members: $members,
      currentHeads: ($members | map({(.number|tostring): .headOid}) | add)}' \
    >"$ctx"

  echo "$ctx" >&2
  jq --arg ctx "$ctx" '. + {ctxFile: $ctx}' "$ctx"
}

# ---------------------------------------------------------------------------
# worktree
# ---------------------------------------------------------------------------

repo_root_for() { # <owner> <repo>
  local owner="$1" repo="$2" here=""
  here="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$here" ]; then
    local remote
    remote="$(git -C "$here" remote get-url origin 2>/dev/null || true)"
    if [[ "$remote" == *"$owner/$repo"* || "$remote" == *"$owner/$repo.git"* ]]; then
      echo "$here"; return
    fi
  fi
  local clone="$CLONE_CACHE/$owner-$repo"
  if [ ! -d "$clone/.git" ]; then
    mkdir -p "$CLONE_CACHE"
    gh repo clone "$owner/$repo" "$clone" -- --quiet >&2
  fi
  echo "$clone"
}

cmd_worktree() {
  local ctx="" since=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ctx) ctx="$2"; shift 2 ;;
      --since-heads) since="$2"; shift 2 ;;
      *) die "worktree: unknown arg $1" ;;
    esac
  done
  [ -n "$ctx" ] || die "worktree needs --ctx"

  local owner repo top base_branch root wt
  owner="$(jq -r .owner "$ctx")"
  repo="$(jq -r .repo "$ctx")"
  top="$(jq -r .topNumber "$ctx")"
  base_branch="$(jq -r .baseBranch "$ctx")"
  root="$(repo_root_for "$owner" "$repo")"
  wt="$root/../pr-review-worktrees/$owner-$repo-pr-$top"

  # Fetch each PR head via its pull ref — works for forks and for stack
  # branches that were never pushed to this remote under their own name.
  git -C "$root" fetch origin "$base_branch" --quiet
  local nums
  nums="$(jq -r '.members[].number' "$ctx")"
  for n in $nums; do
    git -C "$root" fetch origin "pull/$n/head:refs/pr-review/$owner-$repo/$n" \
      --force --quiet
  done

  [ -d "$wt" ] && git -C "$root" worktree remove "$wt" --force >/dev/null 2>&1
  mkdir -p "$(dirname "$wt")"
  git -C "$root" worktree add --quiet --detach "$wt" \
    "refs/pr-review/$owner-$repo/$top"

  local BASE
  BASE="$(git -C "$wt" merge-base "origin/$base_branch" HEAD)"

  # Per-member segment ranges (attribution) — bottom member against the base
  # branch, every other against the member below it.
  local segments="[]" prev_ref="origin/$base_branch"
  for n in $nums; do
    local ref="refs/pr-review/$owner-$repo/$n" seg_base
    seg_base="$(git -C "$wt" merge-base "$prev_ref" "$ref")"
    segments="$(jq -c --argjson n "$n" --arg from "$seg_base" --arg to "$ref" \
      --argjson files "$(git -C "$wt" diff "$seg_base..$ref" --name-only | jq -R . | jq -sc .)" \
      '. + [{pr: $n, from: $from, to: $to, files: $files}]' <<<"$segments")"
    prev_ref="$ref"
  done

  # Delta since a previous round's heads.
  local delta="null"
  if [ -n "$since" ]; then
    local d="[]" unreachable=false
    for n in $nums; do
      local old new
      old="$(jq -r --arg n "$n" '.[$n] // empty' <<<"$since")"
      new="$(jq -r --argjson n "$n" '.members[] | select(.number==$n) | .headOid' "$ctx")"
      [ -n "$old" ] || continue
      [ "$old" = "$new" ] && continue
      if ! git -C "$wt" cat-file -e "$old^{commit}" 2>/dev/null; then
        unreachable=true
        d="$(jq -c --argjson n "$n" --arg old "$old" --arg new "$new" \
          '. + [{pr: $n, from: $old, to: $new, reachable: false, files: []}]' <<<"$d")"
        continue
      fi
      d="$(jq -c --argjson n "$n" --arg old "$old" --arg new "$new" \
        --argjson files "$(git -C "$wt" diff "$old..$new" --name-only | jq -R . | jq -sc .)" \
        '. + [{pr: $n, from: $old, to: $new, reachable: true, files: $files}]' <<<"$d")"
    done
    delta="$(jq -c --argjson d "$d" --argjson u "$unreachable" \
      '{unreachable: $u, members: $d,
        files: ($d | map(.files[]) | unique)}' <<<'{}')"
  fi

  local net_files
  net_files="$(git -C "$wt" diff "$BASE..HEAD" --name-only | jq -R . | jq -sc .)"

  local tmp="$ctx.tmp"
  jq --arg root "$root" --arg wt "$wt" --arg base "$BASE" \
     --argjson segments "$segments" --argjson delta "$delta" \
     --argjson netFiles "$net_files" \
    '. + {repoRoot: $root, worktree: $wt, baseSha: $base,
          range: ($base + "..HEAD"), segments: $segments,
          netFiles: $netFiles, delta: $delta}' "$ctx" >"$tmp"
  mv "$tmp" "$ctx"
  jq '{worktree, baseSha, range, netFiles: (.netFiles|length),
       delta: (if .delta == null then null
               else {files: (.delta.files|length), unreachable: .delta.unreachable} end),
       segments: [.segments[] | {pr, files: (.files|length)}]}' "$ctx"
}

# ---------------------------------------------------------------------------
# files / hunks
# ---------------------------------------------------------------------------

cmd_files() {
  local ctx="" set="net" pr=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ctx) ctx="$2"; shift 2 ;;
      --set) set="$2"; shift 2 ;;
      --pr) pr="$2"; shift 2 ;;
      *) die "files: unknown arg $1" ;;
    esac
  done
  [ -n "$ctx" ] || die "files needs --ctx"
  case "$set" in
    net) jq -r '.netFiles[]' "$ctx" ;;
    delta) jq -r '(.delta.files // [])[]' "$ctx" ;;
    segment) [ -n "$pr" ] || die "--set segment needs --pr"
             jq -r --argjson n "$pr" '.segments[] | select(.pr==$n) | .files[]' "$ctx" ;;
    *) die "unknown --set $set (net|delta|segment)" ;;
  esac
}

cmd_hunks() { # TSV: file<TAB>startLine<TAB>endLine, on the NEW side
  local ctx="" set="net" pr=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ctx) ctx="$2"; shift 2 ;;
      --set) set="$2"; shift 2 ;;
      --pr) pr="$2"; shift 2 ;;
      *) die "hunks: unknown arg $1" ;;
    esac
  done
  [ -n "$ctx" ] || die "hunks needs --ctx"

  local wt range
  wt="$(jq -r .worktree "$ctx")"
  case "$set" in
    net) range="$(jq -r .baseSha "$ctx")..HEAD" ;;
    segment) [ -n "$pr" ] || die "--set segment needs --pr"
             range="$(jq -r --argjson n "$pr" '.segments[] | select(.pr==$n) | .from + ".." + .to' "$ctx")" ;;
    delta) [ -n "$pr" ] || die "--set delta needs --pr"
           range="$(jq -r --argjson n "$pr" '.delta.members[] | select(.pr==$n) | .from + ".." + .to' "$ctx")" ;;
    *) die "unknown --set $set (net|segment|delta)" ;;
  esac

  git -C "$wt" diff --unified=0 "$range" \
    | awk '
        /^\+\+\+ b\// { file = substr($0, 7); next }
        /^@@/ {
          match($0, /\+[0-9]+(,[0-9]+)?/)
          spec = substr($0, RSTART + 1, RLENGTH - 1)
          split(spec, a, ",")
          start = a[1] + 0
          len = (2 in a) ? a[2] + 0 : 1
          if (len == 0) next
          printf "%s\t%d\t%d\n", file, start, start + len - 1
        }'
}

# ---------------------------------------------------------------------------
# profile — how big and how risky the scan set is, and the tier that implies
# ---------------------------------------------------------------------------

# Content patterns matched against ADDED lines of non-test, non-doc files.
# Each is a risk a line count cannot see.
CONCURRENCY_RE='Promise\.(all|race|any|allSettled)|setInterval|[Mm]utex|\.transaction\(|FOR UPDATE|advisory_lock|AbortController'
RAW_SQL_RE='sql\.raw|sql`|\.raw\('
PUBLIC_API_RE='public: *true'
EXTERNAL_CALL_RE='(^|[^A-Za-z_.])fetch\(|axios\.|undici'
CRYPTO_RE='[Kk]ms|KMS|[Ee]ncrypt|[Dd]ecrypt'

cmd_profile() { # JSON: size, surfaces, risk flags, recommended tier, A+B shards
  local ctx="" set="net"
  while [ $# -gt 0 ]; do
    case "$1" in
      --ctx) ctx="$2"; shift 2 ;;
      --set) set="$2"; shift 2 ;;
      *) die "profile: unknown arg $1" ;;
    esac
  done
  [ -n "$ctx" ] || die "profile needs --ctx"

  local wt ranges
  wt="$(jq -r .worktree "$ctx")"
  case "$set" in
    net) ranges="$(jq -r '.baseSha + "..HEAD"' "$ctx")" ;;
    delta) ranges="$(jq -r '(.delta.members // [])[] | select(.reachable) | .from + ".." + .to' "$ctx")" ;;
    *) die "unknown --set $set (net|delta)" ;;
  esac

  local numstat="" added=""
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    numstat+="$(git -C "$wt" diff --numstat --no-renames "$r")"$'\n'
    added+="$(git -C "$wt" diff --unified=0 --no-renames "$r" -- . \
      ':(exclude)*.test.*' ':(exclude)*.spec.*' ':(exclude)*.md' ':(exclude)*.mdx' \
      ':(exclude)*.lock' ':(exclude)pnpm-lock.yaml' | grep '^+[^+]' || true)"$'\n'
  done <<<"$ranges"

  local content_flags
  content_flags="$(
    {
      grep -Eq "$CONCURRENCY_RE" <<<"$added" && echo concurrency
      grep -Eq "$RAW_SQL_RE" <<<"$added" && echo rawSql
      grep -Eq "$PUBLIC_API_RE" <<<"$added" && echo publicApi
      grep -Eq "$EXTERNAL_CALL_RE" <<<"$added" && echo externalCall
      grep -Eq "$CRYPTO_RE" <<<"$added" && echo crypto
      true
    } | jq -R . | jq -sc .
  )"

  # numstat rows: added<TAB>deleted<TAB>path ("-" for binary files).
  awk -F'\t' 'NF == 3 { print }' <<<"$numstat" \
    | jq -R 'split("\t") | {file: .[2],
        lines: ((.[0] | tonumber? // 0) + (.[1] | tonumber? // 0))}' \
    | jq -s --arg set "$set" --argjson content "$content_flags" \
        --arg ux_re "$UX_PATHS_RE" --arg contract_re "$CONTRACT_PATHS_RE" --arg ops_re "$OPS_PATHS_RE" '
      def kind:
        if test("(^|/)(pnpm-lock\\.yaml|[^/]*\\.lock)$|\\.bundled\\.ts$|\\.snap$|(^|/)dist/|\\.generated\\.|\\.types\\.ts$")
          then "generated"
        elif test("\\.(test|spec)\\.[a-z]+$|(^|/)(__tests__|tests?|e2e|spec)/") then "test"
        elif test("\\.(md|mdx|txt)$") then "doc"
        else "code" end;
      def surfaces($k):
        [ if ($k == "code" and test($ux_re)) or test("\\.mdx$")
            then "ux" else empty end,
          if test($contract_re)
            then "contract" else empty end,
          if $k == "code" and test($ops_re)
            then "ops" else empty end,
          if $k == "code" and test("(?i)(^|[/._-])(auth\\w*|oauth|permissions?|credentials?|secrets?|tokens?|webhooks?|upload\\w*|routes?)([/._-]|$)")
            then "security" else empty end ];
      def risks($k):
        [ if test("(^|/)migrations/") then "migration" else empty end,
          if $k == "code" and test("(?i)(^|[/._-])(auth\\w*|oauth|entitlement\\w*|permissions?|credentials?|secrets?|tokens?)([/._-]|$)")
            then "auth" else empty end,
          if test("tenant-scope") then "tenantScope" else empty end,
          if test("(^|/)INVARIANTS\\.md$|^invariants/") then "invariants" else empty end,
          if test("^infrastructure/|\\.tf$|^\\.github/workflows/") then "infra" else empty end ];
      # The area of a file is its path cut to `depth` directories (never the file
      # itself). Sharding starts at the package and splits whichever area
      # still holds more than half the lines, so a backend-only PR shards by
      # module instead of collapsing into one shard.
      def area_at($d): split("/") as $p | $p[0:([1, ([$d, ($p | length) - 1] | min)] | max)] | join("/");
      def regroup: group_by(.area) | map({area: .[0].area, lines: (map(.lines) | add), files: .}) | sort_by(-.lines);
      def refine($total; $iter):
        regroup as $g
        | if $iter == 0 or ($g[0].lines * 2 <= $total) then $g
          else ($g[0].files | map((.depth + 1) as $d | .depth = $d | .area = (.file | area_at($d)))) as $split
            | if ($split | map(.area) | unique) == [$g[0].area] then $g
              else (($g[1:] | map(.files[])) + $split) | refine($total; $iter - 1) end
          end;
      # Greedy bin-packing of areas into at most 3 shards, heaviest first.
      def shards:
        map(.depth = (if (.file | startswith("packages/")) then 2 else 1 end) | .depth as $d | .area = (.file | area_at($d)))
        | refine(map(.lines) | add; 6) as $areas
        | ([($areas | length), 3] | min) as $n
        | if $n < 2 then []
          else reduce $areas[] as $a ([range($n)] | map({areas: [], lines: 0, files: []});
            (to_entries | min_by(.value.lines) | .key) as $i
            | .[$i].areas += [$a.area] | .[$i].lines += $a.lines | .[$i].files += ($a.files | map(.file)))
          end;

      map(. + {kind: (.file | kind)}) as $files
      | ($files | map(select(.kind == "code")) | map(.lines) | add // 0) as $code
      | ($files | map(.kind as $k | .file | surfaces($k)) | add // []
          | . + (if ($content | index("externalCall")) then ["security"] else [] end) | unique) as $surfaces
      | (($files | map(.kind as $k | .file | risks($k)) | add // [])
          + ($content - ["externalCall"]) | unique) as $risk
      | ($risk | length) as $r | ($surfaces | length) as $s
      | (if $code == 0 then "low"
         elif $code <= 30 and $r == 0 and $s <= 1 then "low"
         elif $code <= 200 and $r == 0 and $s <= 2 then "medium"
         elif $code > 1500 or $s >= 4 or ($r >= 1 and $code > 300) or ($r >= 2 and $code > 100) then "xhigh"
         else "high" end) as $tier
      | {
          set: $set,
          files: ($files | length),
          codeLines: $code,
          testLines: ($files | map(select(.kind == "test")) | map(.lines) | add // 0),
          otherLines: ($files | map(select(.kind == "doc" or .kind == "generated")) | map(.lines) | add // 0),
          surfaces: $surfaces,
          riskFlags: $risk,
          tier: $tier,
          reasons: ([ "\($code) code lines", "\($s) surface(s)\(if $s > 0 then ": " + ($surfaces | join(", ")) else "" end)" ]
                    + (if $r > 0 then ["risk: " + ($risk | join(", "))] else [] end)),
          shards: (if $code > 1500 then ($files | map(select(.kind != "generated")) | shards) else [] end)
        }'
}

cmd_cleanup() {
  local ctx="" stale=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --ctx) ctx="$2"; shift 2 ;;
      --stale) stale=true; shift ;;
      *) die "cleanup: unknown arg $1" ;;
    esac
  done

  # --stale sweeps worktrees left behind by runs that never reached cleanup.
  if [ "$stale" = true ]; then
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "--stale must run inside a repo"
    git -C "$root" worktree list --porcelain \
      | awk '/^worktree /{print substr($0,10)}' \
      | grep '/pr-review-worktrees/' \
      | while read -r old; do
          git -C "$root" worktree remove "$old" --force && echo "removed $old"
        done
    git -C "$root" worktree prune
    return 0
  fi

  [ -n "$ctx" ] || die "cleanup needs --ctx (or --stale)"
  local root wt
  root="$(jq -r '.repoRoot // empty' "$ctx")"
  wt="$(jq -r '.worktree // empty' "$ctx")"
  if [ -n "$root" ] && [ -n "$wt" ] && [ -d "$wt" ]; then
    git -C "$root" worktree remove "$wt" --force
    echo "removed $wt"
  else
    echo "nothing to remove"
  fi
}

case "${1:-}" in
  resolve)  shift; cmd_resolve "$@" ;;
  worktree) shift; cmd_worktree "$@" ;;
  files)    shift; cmd_files "$@" ;;
  hunks)    shift; cmd_hunks "$@" ;;
  profile)  shift; cmd_profile "$@" ;;
  cleanup)  shift; cmd_cleanup "$@" ;;
  ""|-h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command ${1}" ;;
esac
