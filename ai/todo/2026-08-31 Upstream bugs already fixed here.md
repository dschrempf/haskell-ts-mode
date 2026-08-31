# Five upstream bugs this fork already fixes — pin them with tests

Upstream issues 57, 28, 65, 51 and 33 at
<https://codeberg.org/pranshu/haskell-ts-mode/issues>, all still open there, all
**verified fixed in this fork on 2026-08-31** (measurements below, taken with a
scratch probe under `nix develop`, grammar from `flake.nix`).

Priority: B — five tests, no design decisions, and they lock in fixes that were
free side effects and could silently regress.

Nothing to implement. The work is a **regression test per bug**, because every
one of these was fixed as a side effect — of the grammar retarget, or of the
imenu rewrite — and nothing currently stops a future change from reintroducing
them. Order them into the existing sections of
`tests/haskell-ts-mode-tests.el`: the font-lock ones next to
`haskell-ts-test-font-lock-*` (grammar-dependent block, line ~731 onward), the
imenu/mode-wiring ones next to `haskell-ts-test-mode-activates`.

## Issue 57 — "Haddock documentation strings are not highlighted correctly"

dschrempf, 2025-10-30. Upstream, only the first line of a Haddock block got
`font-lock-doc-face`; continuation lines fell to `font-lock-comment-face`,
because the grammar emitted `(haddock) (comment) (comment)`. pranshu confirmed it
as a grammar bug and filed
<https://github.com/tree-sitter/tree-sitter-haskell/issues/142>.

Measured here:

```
-- | First haddock line
-- second line
-- third line              →  one run, font-lock-doc-face
```
tree: `(haddock marker: (marker) content: (content))` — one node for the whole
block. Fixed by the grammar fork.

Test: a three-line Haddock block, assert `font-lock-doc-face` on a character of
the *second and third* lines (the existing doc-face test at line ~811 only ever
looks at one position, which the old grammar would also have passed).

## Issue 28 — "Weird font color at commented type alias"

Netsu, 2025-04-24, plus the follow-up question about a plain comment line
directly above a Haddock line, which pranshu diagnosed as a grammar limitation
(`-- Comment` + `-- | Test what` produced a single `(comment)`).

Measured here: `-- type A = Int` → `font-lock-comment-face` throughout; and

```
-- Comment      →  font-lock-comment-face
-- | Test what  →  font-lock-doc-face
```
tree: `(comment …) (haddock …)`, two separate nodes. Both parts fixed.
A trailing `-- ^ field doc` in a record also gets `font-lock-doc-face`.

Test: the comment-then-Haddock pair, asserting the two different faces; plus the
commented-out declaration.

## Issue 65 — "treesit-simple-imenu-settings puts predicate in place of regex"

Warbo, 2026-06-09, against 1.3.5: the settings were `(CATEGORY PRED nil NAME-FN)`
where Emacs documents `(CATEGORY REGEXP PRED NAME-FN)`, which broke `embark`.

Measured here: every setting has a string in the REGEXP slot
(`"function\\|bind"`, `"signature"`, `"data_type\\|newtype"`, `"type_synonym"`)
and `treesit-simple-imenu` returns entries. Fixed by the imenu rewrite.

Test: assert `(stringp (nth 1 setting))` for every entry of
`treesit-simple-imenu-settings` in a `haskell-ts-mode` buffer. Cheap, and it is
the exact shape contract the two downstream crashes depended on.

## Issue 51 — "Error while trying to save ediff-merge edits"

Netsu, 2025-07-07. `wrong-type-argument stringp haskell-ts-imenu-func-node-p`
from `string-match` inside `treesit-outline-predicate--from-imenu`, reached via
`outline-on-heading-p` ← `revert-buffer` ← ediff/magit. Same root cause as issue
65 (a symbol where a regexp was expected); the reporter never produced a recipe
and upstream stalled there.

Measured here: `outline-minor-mode` plus `outline-on-heading-p` at every line of
a small module runs clean.

Test: the same walk — enable `outline-minor-mode`, call `outline-on-heading-p`
on each line, assert no error. That is a faithful, dependency-free stand-in for
the reporter's ediff scenario, which needs neither ediff nor magit nor VC.

## Issue 33 — "dir-locals inheritance"

Netsu, 2025-05-02: `.dir-locals.el` entries keyed on `haskell-mode` did not apply
in `haskell-ts-mode` (their case: `eglot-workspace-configuration`). Upstream
went back and forth and never resolved it.

Measured here: with `((haskell-mode . ((fill-column . 42))))` in a temp
directory, opening a `.hs` file gives `major-mode` `haskell-ts-mode` and
`fill-column` 42. `derived-mode-all-parents` is
`(haskell-ts-mode prog-mode haskell-mode)`. Emacs 30 matches dir-locals through
`derived-mode-all-parents`, which honours `derived-mode-add-parents` — so the
package's floor of 30.1 is what makes this work; on 29 it would not have.

Test: exactly the probe above (temp dir, `.dir-locals.el`, `find-file-noselect`,
assert the variable took). Note in the test's docstring *why* it is version
sensitive, so a floor change flags it.

## Afterwards

Report back on the upstream issues — 57, 28, 65 and 51 are fixed by changes this
fork already carries, and 33 is a non-bug on Emacs 30. That is useful to pranshu
whether or not the code ever merges back.
