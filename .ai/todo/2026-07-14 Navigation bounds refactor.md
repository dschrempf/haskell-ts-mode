# Navigation refactor — a region/bounds model for prose motion

A sketch (not yet implemented) for making `haskell-ts-navigation.el`'s
comment/code prose motion easier to reason about and less prone to the
recurring evil-interaction breakage. Written 2026-07-14, right after fixing the
three `TODO.org` navigation bugs (branch `fix-nav-paragraph-sentence-delete`):
the paragraph text-object boundary, `backward-sentence` from a blank line, and
visual-delete marker preservation. Those fixes each added *another* edge/clamp
helper or gate, which is the smell this plan addresses.

This is a **behaviour-preserving refactor**, safe to attempt now only because
the regression suite exists (134 tests covering every path below). Do **not**
start it without keeping the suite green at each step.

## Motivation

Two constraints are irreducible and no refactor removes them (record them here so
nobody re-litigates):

1. **Prose inside a comment is not in the tree.** The grammar gives one
   `comment`/`haddock` node; the sentences/paragraphs within it are not nodes.
   Any in-comment motion is text analysis on an opaque blob — hence the
   virtual-text machinery.
2. **Emacs paragraph motion has no buffer-local hook.** `forward-sentence-function`
   is buffer-local (the sentence side is already bridged cleanly), but
   `forward-paragraph`/`start-of-paragraph-text` are not, and the comment↔code
   boundary can't be expressed in `paragraph-start`/`paragraph-separate` (those
   match one line in isolation; the boundary is defined by two adjacent lines'
   syntactic classes). So global advice gated on the mode is the *only* lever,
   not a design failure.

What *is* a design issue: the same concept — "what syntactic region is point in,
and where are its bounds" — is recomputed piecemeal across a zoo of helpers, and
the prose API being *motion*-based (return a point) rather than *bounds*-based
forces compensating hacks (most glaringly the marker-aware deletion).

## Goal / non-goals

- **Goal:** one classifier + bounds functions as the single source of truth;
  rebuild the clamp helpers and marker-aware delete on top; keep behaviour and
  every current test passing.
- **Non-goal:** removing the global advice or the evil bridge (see constraint 2),
  changing user-visible behaviour, or touching sexp motion / REPL / font lock.

## The core model

Introduce two primitives, both pure (compute-and-return, no point movement):

```elisp
(haskell-ts--region-at POS)      ; => (KIND . (BEG . END))   KIND ∈ code|comment|string
(haskell-ts--prose-bounds POS UNIT DIR)  ; UNIT ∈ sentence|paragraph
                                         ; => (BEG . END) of the UNIT reached from
                                         ;    POS in DIR, confined to its region
```

`--region-at` is the one place that knows how a comment glues to code and where a
region ends; everything else asks it. `--prose-bounds` is the one place that runs
prose analysis, for both code and comments, via the **normalize-and-map** idea
already half-present in `haskell-ts--text-node-segments` /
`--virtual-text-and-table`:

- Build a normalized string for the region: strip `--`/Haddock/quote markers,
  and render the region's own boundaries (comment↔code, buffer edge) as blank
  lines so stock motion stops there.
- Run **stock** `forward-sentence`/`forward-paragraph` on that string in a temp
  buffer.
- Map the result back with the existing table machinery.

This replaces the bespoke clamp arithmetic with "stock motion on normalized
text," which is far easier to trust than reasoning about `min`/`max` of a
blank-line limit against an adjacent-comment edge.

## What collapses into what

| Today | After |
|---|---|
| `--text-node-at`, `--text-node-parent` | folded into `--region-at` (comment/string arms) |
| `--adjacent-comment-edge`, `--code-blank-line-limit`, `--code-paragraph-limit`, `--code-paragraph-clamp` | folded into `--region-at` (code arm) + `--prose-bounds` |
| `--node-forward-clamp`, `--node-backward-clamp`, `--node-glued-p` | folded into `--region-at` (returns bounds already; "glued" is a property of the returned END/BEG vs. the next region) |
| `--comment-line-segments`, `--text-node-segments`, `--virtual-text-and-table`, `--real-to-virtual`, `--virtual-to-real` | **kept** — this is the normalize-and-map engine `--prose-bounds` is built on; generalize it to also emit region-boundary blank lines |
| `--forward-sentence-in-code`, `--forward-sentence` | thin wrappers: `(goto (cdr/car (--prose-bounds ...)))` |
| `--marker-aware-delete` + `kill-region`/`delete-region` advice | shrinks: deletion asks `--prose-bounds`/`--region-at` for the *pieces* to remove (segments intersected with the range) instead of re-deriving them from two points; the "does the range straddle a marker" test becomes "are there ≥2 segment pieces," computed from the same segment list |

Net: ~7 edge/limit/clamp helpers → 2 primitives + the retained (generalized)
mapping engine.

## The evil bridge — what necessarily stays

Even with a clean bounds core, evil does **not** call our bounds function for
paragraphs — it calls `forward-paragraph`/`start-of-paragraph-text` and re-probes
from intermediate positions. So the advice + whole-call narrowing
(`--confine-evil-paragraph-*`, `--confining-evil-paragraph-object`) survives. But
it gets simpler: the narrowing bounds come straight from `--region-at`, and the
per-call clamp (`--confine-paragraph-motion`) can be expressed as "clamp to
`--prose-bounds paragraph`."

Two optional, larger follow-ups (each its own work item, not part of the
behaviour-preserving refactor):

- **Register real `thingatpt` things** (`beginning-op`/`end-op`/
  `bounds-of-thing-at-point-function`) backed by `--prose-bounds`, and remap
  evil's sentence/paragraph text objects to them, replacing the
  `evil-select-*-object` advice. More explicit than fighting evil's probing.
- **Reduce scope:** drop the evil `}`/`{` / `a p`/`i p` confinement (the piece
  NOTES.org records breaking 3–4 times) and accept default behaviour. Highest
  fragility, arguably lowest value vs. sentence-in-comment and RET continuation.

## Migration plan (each step ends `make check`-green)

1. Add `--region-at` + tests; assert it agrees with today's
   `--text-node-at`/`--adjacent-comment-edge`/`--code-paragraph-limit` on the
   existing fixtures. **No call sites changed yet.**
2. Generalize the segment/virtual-text engine to emit region-boundary blank
   lines; add `--prose-bounds`; assert it reproduces current
   `--forward-sentence` results on every prose fixture.
3. Reimplement `--forward-sentence`/`--forward-sentence-in-code` as wrappers over
   `--prose-bounds`; delete `--adjacent-comment-edge` & the code-limit helpers.
4. Reimplement the clamp/narrowing helpers over `--region-at`/`--prose-bounds`;
   delete `--node-*-clamp`, `--code-paragraph-clamp`, `--node-glued-p`.
5. Reimplement `--marker-aware-delete` to consume segment pieces from
   `--prose-bounds`; keep the advice wiring and the visual/operator gate as-is.
6. Delete now-dead helpers; update Commentary + the CLAUDE.md architecture notes.

## Risks

- The evil re-probing invariant (NOTES.org) is the landmine. Do **not** change
  the narrowing *strategy* during this refactor — only its *inputs*. Behaviour
  parity for `a p`/`i p`/`}`/`{` is asserted by the existing evil tests; run them
  after every step, not just at the end.
- `--prose-bounds` must reproduce the subtle cases the current code documents:
  marker exclusion at a comment's start, one-space-after-period
  (`sentence-end-double-space` nil), `{- -}` closing-`-}` trimming, string quote
  stripping, empty (marker-only) comments. Each already has a test; treat any red
  as a spec, not a nuisance.
- Watch for a future Emacs adding `forward-paragraph-function` or treesit prose
  helpers — either would let the paragraph advice be de-globalized, changing the
  calculus of the evil-bridge follow-ups above.

## Progress / decisions taken

- **Return shape:** a `cl-defstruct haskell-ts--region` (`kind` / `beg` / `end`),
  not the sketched `(KIND . (BEG . END))` cons — matches the "named record over a
  multi-field tuple" style. `kind` ∈ `code`|`comment`|`haddock`|`string` (haddock
  kept distinct from comment, since their font lock differs; prose motion still
  treats the two alike via `(not (eq kind 'code))`).
- **Blank lines stay out of `--region-at`** (it is pure syntactic
  classification). The step-1 agreement test pins the identity this rests on:
  `--code-paragraph-limit dir` = intersect(`--code-blank-line-limit dir`,
  region bound). Holds at *every* position across all prose fixtures, including
  the blank-line-between-two-comments case (there the region bound degrades to
  the buffer edge, exactly as `--adjacent-comment-edge` returns nil).
- **Deferred, flagged divergence:** `--code-region-edge` reproduces
  `--adjacent-comment-edge` *faithfully*, including its "look at the nearest
  comment only" behaviour — so an inline comment nearer than an own-line comment
  in the same non-blank stretch yields no region bound (falls to blank/buffer).
  Treating inline comments as fully within code and *continuing* past them to a
  later own-line comment is a tiny behaviour change for that (untested) corner;
  leave it for step 3, where the motion is actually rewritten, and add a test.

## Action items

- [x] Step 1: `--region-at` + agreement tests. *(done; `make check` green, 135 tests)*
- [ ] Step 2: generalize mapping engine; add `--prose-bounds` + parity tests.
- [ ] Step 3: rewrite sentence motion over `--prose-bounds`; drop code-limit helpers.
- [ ] Step 4: rewrite clamp/narrowing over the new primitives; drop node-clamp helpers.
- [ ] Step 5: rewrite marker-aware delete over segment pieces.
- [ ] Step 6: cleanup + docs (Commentary, `CLAUDE.md`).
- [ ] (Optional, separate) `thingatpt` provider + evil text-object remap.
- [ ] (Optional, separate) evaluate dropping evil `}`/`{`/`a p`/`i p` confinement.
