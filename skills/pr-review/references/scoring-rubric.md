# Scoring rubric

Score four criteria 0–100, then compute one weighted overall score.

## Criteria (0–100 each)

- **Functional correctness** — does the change do what it claims, with correct
  logic, data flow, feature completeness (wired across every layer), and
  API/DB/wire contracts (Lens A, and contract-breakage from Lens E)?
- **Technical quality** — clarity, structure, repo-convention adherence
  (the checklist scan + CLAUDE.md/AGENTS.md/.claude/rules), test adequacy
  (Lens D — vacuous or non-discriminating tests dock this even when code is
  correct), operability (Lens G+H: logs/metrics/redaction), no dead complexity.
- **Bug-safety** — freedom from subtle bugs (Lens B: edge cases, error handling/
  classification, concurrency/races, type holes), security & tenant-scope
  (Lens S), and performance/scale hazards (Lens G+H). Higher = safer.
- **UX** — user-facing behavior & copy quality (Lens C: product terminology, states,
  copy self-consistency, a11y, pagination). Use `N/A` when the PR touches no
  user-facing surface.

The lenses supply the *evidence*; the four criteria and weights below stay fixed
so scores remain comparable across reviews. A lens that didn't run (routed off)
simply contributes no findings to its criterion — don't penalise a criterion for
a surface the PR doesn't touch.

## Bands (apply to every criterion)

| Range | Meaning |
|-------|---------|
| 90–100 | Excellent — no material issues. |
| 75–89 | Good — minor issues only. |
| 60–74 | Fair — one or more Medium issues. |
| 40–59 | Weak — a High issue or several Medium. |
| 0–39 | Poor — a Blocker or multiple High issues. |

## Overall (weighted)

`Overall = 0.35*Functional + 0.30*Technical + 0.25*BugSafety + 0.10*UX`

When UX is `N/A`, drop its term and renormalize the other three weights to sum
to 1 (i.e. Functional 0.389 · Technical 0.333 · BugSafety 0.278). Round to a
whole number.

## Verdict rule (deterministic)

- Any 🔴 Blocker or 🟠 High finding → **REQUEST CHANGES**.
- Otherwise, if any 🟡/🔵/⚪ finding remains → **COMMENT**.
- No substantive findings → **APPROVE**.
