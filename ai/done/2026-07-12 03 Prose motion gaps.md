# 03 — Prose-motion coverage gaps

Prose motion is otherwise very well covered. Two specific holes remain, both
confirmed by surviving mutations.

## A. A string's *last* sentence (closing-quote strip) is untested

`haskell-ts--text-node-segments` strips the closing `"` of a string via
`(1- (treesit-node-end node))`. Removing that `-1` **SURVIVED** — while the
opening `+1` strip was caught.

`haskell-ts-test-sentence-motion-in-string` uses
`x = "First. Second. Third."` but only checks `"First."` and `"Second."`,
never `"Third."`, the sentence adjacent to the closing quote.

(Contrast: the block-comment test already covers its trailing `-}`, because
`"Second."` *is* the last sentence there. This gap is string-specific.)

### Action

Add to the existing test:

```elisp
(search-forward "Third")
(should (equal "Third." (haskell-ts-tests--sentence-at-point)))
```

## B. Inline trailing comments in code sentence motion are untested

`haskell-ts--adjacent-comment-edge` restricts paragraph-edge detection to
**own-line** comments via `(when (bolp) …)`, so an inline trailing comment
(`f = x -- note`) is treated as part of its code line, not a paragraph break.
Replacing `(bolp)` with `t` **SURVIVED** — no test has an inline trailing
comment adjacent to code sentence motion.

### Action

Add a test in the "sentence motion in code" cluster asserting that from a
binding with a trailing comment, `forward-sentence` stops at the equation's end
(the comment does **not** act as a paragraph boundary that splits the line),
e.g.:

```elisp
(ert-deftest haskell-ts-test-sentence-code-ignores-inline-comment ()
  "A trailing `-- note' is part of its code line, not a paragraph edge."
  (haskell-ts-tests--with-temp-hs "f = x  -- note\ng = y\n"
    (goto-char (point-min))
    (forward-sentence)
    (should (= (point) (line-end-position 1)))))  ; end of `f = x  -- note'
```
Verify the expected landing point against actual behavior first — the value is
the *observed correct* behavior this pins, not an assumption.
