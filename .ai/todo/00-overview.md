# Test-suite review — overview

Review of `tests/haskell-ts-mode-tests.el` (106 tests) done 2026-07-12, per
`TODO.org` "Review tests". This directory splits the findings into
self-contained work items; each file below is sized to be picked up in one
sitting and includes the evidence and the concrete fix.

## Method

Read all 106 tests + the three source modules, ran the suite (106/106 pass
with grammar + evil present), then **mutation-tested**: mechanically
introduced 34 bugs into the source, ran the suite against each, reverted. A
mutation that leaves the suite green is a bug the tests cannot see. Positive
controls (defun-name, align, close-block guard, send-line) were all caught,
so the method is sound. Harness lived at `/tmp/mut.py` (not kept).

## Mutation results — what SURVIVED (i.e. is not covered)

| Mutation | Area |
|---|---|
| `fontify-func` never matches `"variable"` | font lock |
| `fontify-type` drop curried-return recursion | font lock |
| `(type)`/`(constructor)`/`(operator)`/`(string)`/`function-name` face → comment | font lock |
| drop `:{` open / `:}` close in `send-region` | REPL |
| `adjacent-comment-edge` drop `(bolp)` own-line guard | prose motion |
| string segment: drop closing-quote `-1` strip | prose motion |
| `sexp` operator-length guard `1 → 2` | sexp (minor) |
| `"λ"` prompt alternative removed | REPL regexp (dead code) |

Everything else mutated was **caught** (sexp exclusions, marker-aware delete,
imenu collapse/parent/name, align, close-block guard, prompt `|`, cabal
candidate parsing, glued-comment clamps, continuation prefix, …).

## The headline

Test effort is **inversely correlated with feature prominence**: ~30 tests
exhaustively cover the fragile evil prose/paragraph confinement, while font
lock — the everyday user-visible feature and the package's namesake
"highlight only actually-bound variables" logic — asserts only two faces
(`keyword`, `doc`) and has **zero** coverage of the four AST-walking
fontifiers. Correct that imbalance first.

## Work items (priority order)

1. [`01-font-lock-coverage.md`](01-font-lock-coverage.md) — biggest gap; ~5 tests.
2. [`02-repl-coverage.md`](02-repl-coverage.md) — `:{`/`:}` wrapper, `load-file`.
3. [`03-prose-motion-gaps.md`](03-prose-motion-gaps.md) — string last sentence, inline comment.
4. [`04-mode-wiring-coverage.md`](04-mode-wiring-coverage.md) — prettify, haskell-mode parent, defun motion.
5. [`05-test-quality.md`](05-test-quality.md) — mirror constant, dead λ branch, redundancy.
6. [`06-property-tests.md`](06-property-tests.md) — virtual-text mapping.
7. [`07-un-features-notes.md`](07-un-features-notes.md) — design observations, no action required.

## What's already excellent (don't regress)

- Regression discipline: nearly every nav/prose test names the exact bug, the
  node mechanics, and why the naive approach failed. Best docs in the repo.
- Skip-vs-fail hygiene (`skip-unless` for grammar/evil, env-var escape hatches).
- Real captured `cabal repl --dry-run` fixtures, not invented strings.
- Layered testing: raw motion / `bounds-of-thing` / actual evil objects tested
  separately, so failures localize.
