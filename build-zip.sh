#!/usr/bin/env bash
# build-zip.sh — assemble the claude.ai upload from this repo.
#
# The zip's ROOT must be the skill folder itself (claude.ai rejects a nested
# one), so we stage into dist/pr-review/ and zip that directory by name.
#
# What goes in: claude-ai/SKILL.md (the connector edition) as SKILL.md and the
# shared skills/pr-review/references/. What stays out: scripts/ entirely — the connector edition
# reads a pre-computed sidecar and writes one small JSON round, so it needs no
# code execution at all; and state/, which is read at runtime through the
# GitHub connector rather than baked in.
#
# The upload itself is manual: claude.ai has no API for custom Skills, so CI can
# build and publish this artifact but you drop it into Customize > Skills
# yourself.

set -euo pipefail

cd "$(dirname "$0")"
SKILL_NAME="pr-review"
OUT="dist"
STAGE="$OUT/$SKILL_NAME"

fail() { echo "build-zip: $*" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$STAGE/references"

[ -f claude-ai/SKILL.md ] || fail "claude-ai/SKILL.md is missing"
cp claude-ai/SKILL.md "$STAGE/SKILL.md"
cp skills/pr-review/references/*.md "$STAGE/references/"

# Fill the two per-user constants. Unset = none: a stateless edition that asks
# which repo a bare PR number means.
STATE_REPO="${PR_REVIEW_STATE_REPO:-none}"
DEFAULT_REPO="${PR_REVIEW_DEFAULT_REPO:-none}"
sed -i.bak -e "s|{{STATE_REPO}}|$STATE_REPO|g" -e "s|{{DEFAULT_REPO}}|$DEFAULT_REPO|g" "$STAGE/SKILL.md"
rm -f "$STAGE/SKILL.md.bak"
grep -q '{{' "$STAGE/SKILL.md" && fail "unfilled {{placeholder}} left in the connector SKILL.md"

VERSION="$(git rev-parse --short HEAD 2>/dev/null || echo unversioned)"
DIRTY=""
git diff --quiet 2>/dev/null || DIRTY=" (uncommitted changes)"
cat >"$STAGE/VERSION" <<EOF
$SKILL_NAME (connector edition)
built from kapicic/pr-review @ $VERSION$DIRTY
state repo: $STATE_REPO, default repo: $DEFAULT_REPO
built $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# --- validate against claude.ai's constraints before shipping ---------------

python3 - "$STAGE/SKILL.md" <<'PY'
import re, sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
if not m:
    sys.exit("build-zip: SKILL.md has no YAML frontmatter")
fm = m.group(1)

name = re.search(r"^name:\s*(.+)$", fm, re.M)
if not name:
    sys.exit("build-zip: frontmatter has no name")
name = name.group(1).strip()
if not re.fullmatch(r"[a-z0-9-]{1,64}", name):
    sys.exit(f"build-zip: name {name!r} must be <=64 chars of [a-z0-9-]")
for word in ("anthropic", "claude"):
    if word in name:
        sys.exit(f"build-zip: name may not contain the reserved word {word!r}")

desc = re.search(r"^description:\s*>-?\n(.*?)(?=\n[a-z_]+:|\Z)", fm, re.S | re.M)
desc = " ".join(desc.group(1).split()) if desc else ""
if not desc:
    sys.exit("build-zip: frontmatter has no description")
if len(desc) > 1024:
    sys.exit(f"build-zip: description is {len(desc)} chars, max is 1024 — trim it")
if "<" in desc or ">" in desc.replace(">-", ""):
    sys.exit("build-zip: description may not contain XML tags")
print(f"build-zip: name={name}  description={len(desc)}/1024 chars")
PY

grep -q "state/pending/" "$STAGE/SKILL.md" \
  || fail "the connector SKILL.md no longer writes to state/pending/ — it would try to rewrite the full state file"
grep -q "state/summary/" "$STAGE/SKILL.md" \
  || fail "the connector SKILL.md no longer reads the sidecar — it would pull the whole state file into context"
[ -e "$STAGE/state" ] && fail "state/ must never be baked into the zip"
[ -e "$STAGE/scripts" ] && fail "scripts/ needs git+gh or a local store; it does not belong in the zip"

( cd "$OUT" && zip -qr "$SKILL_NAME.zip" "$SKILL_NAME" )

BYTES="$(du -sk "$STAGE" | cut -f1)"
[ "$BYTES" -lt 30720 ] || fail "staged skill is ${BYTES}KB uncompressed, over the 30MB limit"

echo "build-zip: wrote $OUT/$SKILL_NAME.zip ($(du -h "$OUT/$SKILL_NAME.zip" | cut -f1), ${BYTES}KB uncompressed)"
unzip -l "$OUT/$SKILL_NAME.zip" | sed -n '4,$p' | head -20
