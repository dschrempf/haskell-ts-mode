# 05 — Test-quality issues (not coverage gaps)

## A. `haskell-ts-tests--close-block-re` is a hand-copied mirror

`tests/…-tests.el` line ~146 defines `haskell-ts-tests--close-block-re` as a
literal copy of the guard regexp inside `haskell-ts--send-region`
(`"^[ \t]*:}[ \t]*$"`). `haskell-ts-test-close-block-guard` tests the *copy*, so
the production regexp can drift and this test won't notice.

The real path *is* covered: `-compile-region-rejects-close-block` exercises the
actual function (a mutation of the real regexp was caught there, not by the
mirror test).

**Options:** (a) drop `-close-block-guard` and the mirror constant as redundant;
or (b) keep the many string cases but run them through the real function/regexp
(single source of truth) instead of a copy. Prefer (b) if the string-case
coverage is felt worth keeping.

## B. Dead code the tests can't distinguish: the `"λ"` prompt alternative

Removing `"λ"` from `haskell-ts-inferior-prompt-regexp` **SURVIVED**. Confirmed
why: with `case-fold-search` (t by default), the module-qualified `upper`
branch already matches `λ`, so the dedicated alternative never fires.
`haskell-ts-test-prompt-regexp-matches` lists `"λ> "` but cannot tell "matched
by its own branch" from "matched by case-folded `upper`", giving false
confidence the branch is load-bearing.

**Action (optional, source not test):** either drop the `"λ"` alternative, or
add a source comment noting the case-fold overlap. Low priority; behavior is
correct either way (λ prompts still match).

## C. Borderline redundancy: sexp-backward regression cluster

`haskell-ts-test-sexp-backward-stall`'s assertion (backward-sexp from end of
`z = 3` → `z = 3`) is a strict subset of the second clause of
`-sexp-backward-top-level`. The docstrings justify them as *distinct*
regression anchors (different historical bugs), and the mutation
`drop declarations excl` fails only 1 test, so the cluster is less independent
than its size suggests.

**Recommendation:** keep — the regression-anchor rationale is sound and the
docstrings are excellent. Logged only so a future consolidation pass knows this
is the one defensible spot, not an oversight.
