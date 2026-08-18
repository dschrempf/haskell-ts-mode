# 04 — Mode-wiring coverage

Lower priority than 01–03. These are activation/wiring facts the mode sets up
that no test exercises. Each is cheap; batch them.

## A. Prettify activation

`haskell-ts-test-prettify-tables-well-formed` checks the *alists* are
well-formed but nothing checks the mode actually installs them. The mode
appends `haskell-ts-prettify-symbols-alist` / `-words-alist` to buffer-local
`prettify-symbols-alist` only when `haskell-ts-prettify-symbols` / `-words` are
non-nil.

```elisp
(ert-deftest haskell-ts-test-prettify-installed-when-enabled ()
  (let ((haskell-ts-prettify-symbols t) (haskell-ts-prettify-words nil))
    (haskell-ts-tests--with-temp-hs "x = 1\n"
      (should (assoc "->" prettify-symbols-alist))
      (should-not (assoc "forall" prettify-symbols-alist)))))  ; words off
```

## B. Derivation from `haskell-mode` on v30+

`derived-mode-add-parents 'haskell-ts-mode '(haskell-mode)` runs at load on
Emacs 30+. No test asserts `(provided-mode-derived-p 'haskell-ts-mode
'haskell-mode)`. One `should` covers it. (Matters for third-party config keyed
on `haskell-mode`.)

## C. `beginning-of-defun` / `end-of-defun` motion

Only `treesit-defun-at-point` / `haskell-ts-defun-name` are tested — not the
actual `C-M-a` / `C-M-e` a user presses. Add a test that from inside one
binding, `beginning-of-defun` / `end-of-defun` land on that binding's bounds.

## D. Minor / optional

- `electric-pair-pairs` set buffer-locally (assert the list).
- `comment-start` / `comment-start-skip` values.
- These are low-value; include only if doing a wiring sweep.

## Note

A/B/C need only the grammar (already available here); guard with the usual
`haskell-ts-tests--with-temp-hs`, which `skip-unless`es without it.
