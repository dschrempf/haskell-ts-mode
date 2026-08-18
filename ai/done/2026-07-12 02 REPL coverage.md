# 02 — REPL coverage gaps

## A. The `:{`/`:}` multiline wrapper is unverified

`haskell-ts--send-region` wraps the sent text in GHCi's `:{` / `:}` block
delimiters — the entire reason it exists as distinct from `haskell-ts-send-line`
(which sends verbatim). Nothing asserts the wrapper is emitted.

### Evidence (mutation — SURVIVED)

Corrupting either `(comint-send-string hs ":{\n")` or
`(comint-send-string hs "\n:}\n")` leaves the suite green.
`haskell-ts-test-send-defun` only checks the *payload*:

```elisp
(should (string-match-p "greeting name = \"Hello, \" \\+\\+ name" sent))
(should-not (string-match-p "module Main" sent))
```

### Action

`haskell-ts-test-send-defun` already concatenates every `comint-send-string`
into `sent`. Add two lines:

```elisp
(should (string-match-p ":{" sent))
(should (string-match-p ":}" sent))
```

## B. `haskell-ts-load-file` has no behavioral test

Only its keymap binding (`C-c C-l`) is checked. Nothing verifies it saves the
buffer and sends `:load "<absolute-path>"`.

### Action

Mirror the existing send-tests' stubbing of `haskell-ts-show-repl` +
`comint-send-string`. Because it also calls `save-buffer`, drive it in a real
temp *file* (or stub `save-buffer`), then assert the sent string matches
`:load "…/<name>.hs"`:

```elisp
(ert-deftest haskell-ts-test-load-file-sends-load ()
  "`haskell-ts-load-file' saves and sends `:load \"<abspath>\"'."
  (let (sent (file (make-temp-file "haskell-ts-load-" nil ".hs")))
    (unwind-protect
        (cl-letf (((symbol-function 'haskell-ts-show-repl) (lambda () 'p))
                  ((symbol-function 'comint-send-string)
                   (lambda (_ s) (setq sent (concat sent s)))))
          (with-temp-buffer
            (set-visited-file-name file t)
            (insert "main = pure ()\n")
            (haskell-ts-load-file)))
      (delete-file file))
    (should (string-match-p (format ":load \"%s\"" (regexp-quote file)) sent))))
```

Adjust for `set-visited-file-name` prompting under batch if needed
(`(let ((query-replace-map …)))` or bind `y-or-n-p`). This test does not need
the grammar (no `haskell-ts-mode` activation required for `load-file`'s logic
beyond `buffer-file-name`), so it can live among the grammar-independent tests.

## Already well-covered (leave alone)

REPL command assembly, cabal project-root detection, ambiguous-target parsing
(real fixtures), the `:}` guard *via the real function*
(`-compile-region-rejects-close-block`), prompt regexp, `send-line` verbatim.
