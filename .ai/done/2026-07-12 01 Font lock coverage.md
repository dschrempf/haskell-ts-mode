# 01 — Font-lock behavioral coverage (highest priority)

## Problem

Font lock is the package's namesake feature, and its most sophisticated part —
the custom fontifiers `haskell-ts--fontify-func/-arg/-params/-type`, which walk
the AST to highlight **only actually-bound variables, not all occurrences** —
has **zero** behavioral coverage.

Only 3 behavioral font-lock tests exist (`-applies`, `-extra-keywords`,
`-do-bind-arrow`); between them they assert exactly two faces:
`font-lock-keyword-face` and `font-lock-doc-face`. `grep` confirms no test
references `variable-name-face`, `constructor-face`, `type-face`,
`operator-face`, `string-face`, or any `fontify-*`.

## Evidence (mutation testing — all SURVIVED)

- `fontify-func`: change `(string= "variable" …)` so bound args/params never
  get `variable-name-face` → suite green.
- `fontify-type`: never recurse into the curried return type → suite green.
- `(type)`/`(constructor)`/`(operator)`/`(string)`/`function-name` rule face
  swapped to `font-lock-comment-face` → suite green.

You could silently break every variable/type/constructor/operator/string color
and CI would pass.

## Action — add ~5 tests

Model them on the existing `haskell-ts-test-font-lock-applies` (fontify the
region, `search-forward`, check `get-text-property … 'face`). The most valuable
one exercises the "only *bound* variables" claim directly:

```elisp
(ert-deftest haskell-ts-test-font-lock-binds-only-bound-vars ()
  "A bound parameter gets `variable-name-face'; a free variable does not."
  (haskell-ts-tests--with-temp-hs "f x = x + y\n"
    (treesit-font-lock-fontify-region (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "x")                 ; the bound parameter in `f x'
    (should (eq 'font-lock-variable-name-face
                (get-text-property (match-beginning 0) 'face)))
    (search-forward "y")                 ; free variable — not a bound var
    (should-not (eq 'font-lock-variable-name-face
                    (get-text-property (match-beginning 0) 'face)))))
```

Then one small test each asserting:
- `haskell-ts-constructor-face` on a constructor (e.g. `Red` in
  `data Color = Red | Green`);
- `font-lock-type-face` on a type occurrence (e.g. `String` in a signature);
- `font-lock-string-face` on a `"..."` literal;
- `font-lock-function-name-face` on a definition name (e.g. `greeting`);
- optionally `haskell-ts--fontify-type`'s curried-return behavior: in
  `f :: Int -> Int -> Bool`, the final return-type token is what gets
  `variable-name-face` (guards the recursion whose removal survived).

## Validation

Grammar is available here via `HASKELL_TS_GRAMMAR_PATH` (direnv). Confirm each
new test *fails* under the corresponding mutation before trusting it (I can
re-run the `/tmp/mut.py`-style harness). Five tests move font lock from ~0 to
well-covered.

## Note on face names

`data_constructor` uses the custom `haskell-ts-constructor-face`; check the
exact symbol in `haskell-ts-mode.el` font-lock rules — some rules apply
`@haskell-ts-constructor-face`, distinct from `font-lock-type-face` which
`(type)` uses.
