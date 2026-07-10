;;; haskell-ts-mode-tests.el --- Tests for haskell-ts-mode -*- lexical-binding:t -*-

;; Copyright (C) 2026 Dominik Schrempf

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; ERT test suite for `haskell-ts-mode'.  Run with:
;;
;;   make test
;;
;; or directly:
;;
;;   emacs -Q --batch -L . -l tests/haskell-ts-mode-tests.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; The tests fall into two groups:
;;
;; * Grammar-independent unit tests exercise the pure logic that does
;;   not need a running tree-sitter parser (the GHCi prompt regexp, the
;;   `:}' guard, REPL command assembly, cabal project-root detection,
;;   prettify tables, customisation).  These run everywhere.
;;
;; * Grammar-dependent integration tests open a real Haskell buffer and
;;   check font lock, imenu and navigation.  They are guarded with
;;   `skip-unless' so they are skipped — not failed — when the
;;   tree-sitter Haskell grammar is not available.  The grammar (@tek's
;;   variant, which this package's queries target) is provided by the
;;   flake, so run the suite inside the dev shell to exercise them:
;;
;;     nix develop -c make test     # or just `make test' under direnv
;;     nix flake check              # headless compile + test
;;
;; * Evil integration tests exercise `evil'\\='s sentence text objects
;;   (`d a s'/`d i s') directly, since `haskell-ts-mode' does not
;;   depend on `evil' itself.  They likewise skip, not fail, when
;;   `evil' cannot be found.  The flake's dev shell bundles `evil' into
;;   its Emacs so these always run there; outside the flake, point
;;   `HASKELL_TS_EVIL_PATH' at a checkout or installed copy instead.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'treesit)

;; The grammar-dependent tests need a tree-sitter Haskell grammar on
;; `treesit-extra-load-path'.  The flake builds @tek's grammar and points
;; HASKELL_TS_GRAMMAR_PATH at the directory holding its
;; `libtree-sitter-haskell.so'; honour it when set so `nix develop' / `nix
;; flake check' find the grammar without relying on the user's own
;; configuration.  When unset we fall back to whatever the running Emacs
;; already knows, and the grammar-dependent tests skip if that is nothing.
(let ((grammar-path (getenv "HASKELL_TS_GRAMMAR_PATH")))
  (when (and grammar-path (not (string-empty-p grammar-path)))
    (add-to-list 'treesit-extra-load-path
                 (file-name-as-directory grammar-path))))

;; Likewise for `evil': `haskell-ts-mode' has no dependency on it, so it
;; is not on `load-path' by default.  The flake's Emacs bundles it as a
;; package, so it is already on `load-path' under `nix develop'/`nix
;; flake check'.  Elsewhere, honour `HASKELL_TS_EVIL_PATH' when set so a
;; dev shell can opt into the evil-integration tests below; otherwise
;; fall back to whatever the running Emacs already knows, and those
;; tests skip if that is nothing.
(let ((evil-path (getenv "HASKELL_TS_EVIL_PATH")))
  (when (and evil-path (not (string-empty-p evil-path)))
    (add-to-list 'load-path (file-name-as-directory evil-path))))

(require 'haskell-ts-mode)

;;; Helpers

(defmacro haskell-ts-tests--with-temp-hs (text &rest body)
  "Run BODY in a temporary `haskell-ts-mode' buffer containing TEXT.
Point starts at `point-min'.  Skips the test unless the Haskell
tree-sitter grammar is available."
  (declare (indent 1) (debug (form body)))
  `(progn
     (skip-unless (treesit-ready-p 'haskell t))
     (with-temp-buffer
       (insert ,text)
       (haskell-ts-mode)
       (goto-char (point-min))
       ,@body)))

;;; --------------------------------------------------------------------
;;; Grammar-independent unit tests
;;; --------------------------------------------------------------------

(ert-deftest haskell-ts-test-feature-loads ()
  "The feature provides itself and the autoloaded entry point exists."
  (should (featurep 'haskell-ts-mode))
  (should (fboundp 'haskell-ts-mode))
  (should (fboundp 'haskell-ts-run)))

(ert-deftest haskell-ts-test-auto-mode-alist ()
  "`.hs' files are associated with `haskell-ts-mode'."
  (should (eq 'haskell-ts-mode
              (cdr (assoc "\\.hs\\'" auto-mode-alist)))))

(ert-deftest haskell-ts-test-keymap-bindings ()
  "The mode map binds the documented REPL commands."
  (should (eq #'haskell-ts-run
              (keymap-lookup haskell-ts-mode-map "C-c C-r")))
  (should (eq #'haskell-ts-load-file
              (keymap-lookup haskell-ts-mode-map "C-c C-l")))
  (should (eq #'haskell-ts-compile-region-and-go
              (keymap-lookup haskell-ts-mode-map "C-c C-c")))
  (should (eq #'haskell-ts-send-line
              (keymap-lookup haskell-ts-mode-map "C-c C-e")))
  (should (eq #'haskell-ts-send-defun
              (keymap-lookup haskell-ts-mode-map "C-M-x"))))

;;; GHCi prompt regexp

(ert-deftest haskell-ts-test-prompt-regexp-matches ()
  "The prompt regexp recognises the GHCi prompts it documents."
  (dolist (prompt '("ghci> "
                    "λ> "
                    "*Main> "
                    "*Main| "            ; multiline continuation
                    "Main> "
                    "Prelude> "
                    "Prelude Data.List> "
                    "*Main Data.Map> "))
    (should (string-match-p (concat haskell-ts-inferior-prompt-regexp "\\'")
                            prompt))))

(ert-deftest haskell-ts-test-prompt-regexp-non-matches ()
  "The prompt regexp does not match ordinary output lines."
  (dolist (line '("module Main where"
                  "  let x = 1"
                  "lowercase> "        ; module names are capitalised
                  "no prompt here"))
    (should-not (string-match-p (concat "\\`" haskell-ts-inferior-prompt-regexp
                                        "\\'")
                                line))))

;;; The `:}' guard used by `haskell-ts-compile-region-and-go'

(defconst haskell-ts-tests--close-block-re "^[ \t]*:}[ \t]*$"
  "Mirror of the guard regexp in `haskell-ts-compile-region-and-go'.")

(ert-deftest haskell-ts-test-close-block-guard ()
  "A line that is exactly `:}' (modulo whitespace) is detected."
  (dolist (region '(":}"
                    "  :}"
                    ":}  "
                    "f x = x\n:}\ng y = y"))
    (should (string-match-p haskell-ts-tests--close-block-re region)))
  (dolist (region '("foo :} bar"
                    "x = 1"
                    ":}}"
                    "a :}"))
    (should-not (string-match-p haskell-ts-tests--close-block-re region))))

(ert-deftest haskell-ts-test-compile-region-rejects-close-block ()
  "Sending a region containing a bare `:}' line signals a `user-error'.
The process layer is stubbed so the test never starts GHCi."
  (cl-letf (((symbol-function 'haskell-ts-show-repl) (lambda () 'fake-proc))
            ((symbol-function 'comint-send-string)
             (lambda (&rest _) (error "should not be reached"))))
    (with-temp-buffer
      (insert "main = do\n:}\n  return ()")
      (let ((transient-mark-mode t))
        (set-mark (point-min))
        (goto-char (point-max))
        (activate-mark)
        (should-error
         (call-interactively #'haskell-ts-compile-region-and-go)
         :type 'user-error)))))

;;; Sending a line/definition to the REPL

(ert-deftest haskell-ts-test-send-line ()
  "`haskell-ts-send-line' sends the current line verbatim, unwrapped."
  (let (sent)
    (cl-letf (((symbol-function 'haskell-ts-show-repl) (lambda () 'fake-proc))
              ((symbol-function 'comint-send-string)
               (lambda (_proc str) (setq sent str))))
      (with-temp-buffer
        (insert "foo = 1\nbar = 2\n")
        (goto-char (point-min))
        (forward-line 1)
        (call-interactively #'haskell-ts-send-line)))
    (should (equal sent "bar = 2\n"))))

;;; REPL command assembly

(ert-deftest haskell-ts-test-repl-command-ghci ()
  "With cabal disabled, plain ghci is used regardless of project root."
  (let ((haskell-ts-use-cabal nil)
        (haskell-ts-ghci "ghci")
        (haskell-ts-ghci-switches '("-XHaskell2010")))
    (should (equal (haskell-ts--repl-command "/proj/" "/proj/Main.hs")
                   '("ghci" "-XHaskell2010")))))

(ert-deftest haskell-ts-test-repl-command-cabal-no-cabal-executable ()
  "`auto' falls back to ghci when cabal is not on `exec-path'."
  (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
    (let ((haskell-ts-use-cabal 'auto)
          (haskell-ts-ghci "ghci")
          (haskell-ts-ghci-switches nil))
      (should (equal (haskell-ts--repl-command "/proj/" "/proj/Main.hs")
                     '("ghci"))))))

(ert-deftest haskell-ts-test-repl-command-auto-no-root ()
  "`auto' uses ghci outside a cabal project even when cabal exists."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (&rest _) "/usr/bin/cabal")))
    (let ((haskell-ts-use-cabal 'auto)
          (haskell-ts-ghci "ghci")
          (haskell-ts-ghci-switches nil))
      (should (equal (haskell-ts--repl-command nil "/tmp/Scratch.hs")
                     '("ghci"))))))

(ert-deftest haskell-ts-test-repl-command-cabal-with-target ()
  "Inside a project, cabal is used and the file resolves to a target."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (&rest _) "/usr/bin/cabal"))
            ;; The file resolves to a single component: echo the target back.
            ((symbol-function 'haskell-ts--cabal-file-target)
             (lambda (_root target) target)))
    (let ((haskell-ts-use-cabal 'auto)
          (haskell-ts-cabal "cabal")
          (haskell-ts-cabal-switches '("repl")))
      (should (equal (haskell-ts--repl-command "/proj/" "/proj/app/Main.hs")
                     '("cabal" "repl" "app/Main.hs"))))))

(ert-deftest haskell-ts-test-repl-command-cabal-orphan-file ()
  "A file in no component yields a plain `cabal repl' (no target)."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (&rest _) "/usr/bin/cabal"))
            ((symbol-function 'haskell-ts--cabal-file-target)
             (lambda (_root _target) nil)))
    (let ((haskell-ts-use-cabal 'auto)
          (haskell-ts-cabal "cabal")
          (haskell-ts-cabal-switches '("repl")))
      (should (equal (haskell-ts--repl-command "/proj/" "/proj/Orphan.hs")
                     '("cabal" "repl"))))))

(ert-deftest haskell-ts-test-repl-command-cabal-no-file ()
  "Without a visited file, cabal starts with no target."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (&rest _) "/usr/bin/cabal")))
    (let ((haskell-ts-use-cabal t)
          (haskell-ts-cabal "cabal")
          (haskell-ts-cabal-switches '("repl")))
      (should (equal (haskell-ts--repl-command "/proj/" nil)
                     '("cabal" "repl"))))))

;;; cabal project root detection

(ert-deftest haskell-ts-test-cabal-project-root-cabal-project ()
  "`cabal.project' marks the project root."
  (let* ((root (make-temp-file "haskell-ts-test-" t))
         (sub (expand-file-name "src/" root)))
    (unwind-protect
        (progn
          (make-directory sub t)
          (write-region "" nil (expand-file-name "cabal.project" root))
          (let ((default-directory sub))
            (should (file-equal-p (haskell-ts--cabal-project-root) root))))
      (delete-directory root t))))

(ert-deftest haskell-ts-test-cabal-project-root-dot-cabal ()
  "A bare `*.cabal' file marks the root when there is no `cabal.project'."
  (let* ((root (make-temp-file "haskell-ts-test-" t))
         (sub (expand-file-name "app/" root)))
    (unwind-protect
        (progn
          (make-directory sub t)
          (write-region "" nil (expand-file-name "pkg.cabal" root))
          (let ((default-directory sub))
            (should (file-equal-p (haskell-ts--cabal-project-root) root))))
      (delete-directory root t))))

(ert-deftest haskell-ts-test-cabal-project-root-none ()
  "Outside any cabal project the root is nil."
  (let ((root (make-temp-file "haskell-ts-test-" t)))
    (unwind-protect
        (let ((default-directory root))
          (should-not (haskell-ts--cabal-project-root)))
      (delete-directory root t))))

;;; Prettify tables and customisation

(ert-deftest haskell-ts-test-prettify-tables-well-formed ()
  "Both prettify alists map strings to single-character strings."
  (dolist (alist (list haskell-ts-prettify-symbols-alist
                       haskell-ts-prettify-words-alist))
    (should (consp alist))
    (dolist (pair alist)
      (should (stringp (car pair)))
      (should (stringp (cdr pair)))
      (should (= 1 (length (cdr pair)))))))

(ert-deftest haskell-ts-test-font-lock-level-customisable ()
  "The font lock level is a 1..4 integer and the feature list has 4 levels."
  (should (integerp haskell-ts-font-lock-level))
  (should (<= 1 haskell-ts-font-lock-level 4))
  (should (= 4 (length haskell-ts-font-lock-feature-list))))

;;; Align rules
;;;
;;; `align' is driven entirely by the regexp in
;;; `haskell-ts-align-rules-list' and never consults the tree-sitter
;;; parser, so these tests need neither a parsed buffer nor the grammar.
;;; The snippets are realistic Haskell only for confidence; what is
;;; exercised is the regexp on raw text.  (The one test that the *mode*
;;; installs the rule, below, does need the grammar and is guarded.)

(defun haskell-ts-tests--align (text)
  "Return TEXT after aligning `=' with `haskell-ts-align-rules-list'.
Mirrors what \\[align] does to the whole region, with spaces (not
tabs) for the padding so the expected strings are stable."
  (require 'align)
  (with-temp-buffer
    (let ((indent-tabs-mode nil))
      (insert text)
      (align-region (point-min) (point-max) 'entire
                    haskell-ts-align-rules-list nil)
      (buffer-string))))

(ert-deftest haskell-ts-test-align-rule-regexp ()
  "The `=' align regexp matches a standalone `=' but not its lookalikes.
Group 1 is the whitespace before the `=' that `align' adjusts."
  (let ((re (cdr (assq 'regexp
                       (cdr (assq 'haskell-ts-assignment
                                  haskell-ts-align-rules-list))))))
    ;; A binding/equation `=' is matched, capturing the leading space.
    (dolist (line '("x = 1" "foo   = bar" "main = putStrLn s"))
      (should (string-match re line))
      (should (match-string 1 line)))
    ;; Operators that merely contain `=' are left alone.
    (dolist (line '("x == y" "f :: a => b" "x <= y" "x >= y" "x /= y"))
      (should-not (string-match re line)))))

(ert-deftest haskell-ts-test-align-aligns-equals ()
  "A simple block of bindings has its `=' signs lined up."
  (should (equal (haskell-ts-tests--align
                  (concat "x = 1\n"
                          "foo = 2\n"
                          "ab = 3\n"))
                 (concat "x   = 1\n"
                         "foo = 2\n"
                         "ab  = 3\n"))))

(ert-deftest haskell-ts-test-align-let-block ()
  "Indented `let' bindings align, with the indentation preserved."
  (should (equal (haskell-ts-tests--align
                  (concat "let x = 1\n"
                          "    yy = 2\n"
                          "    zzz = 3\n"))
                 (concat "let x   = 1\n"
                         "    yy  = 2\n"
                         "    zzz = 3\n"))))

(ert-deftest haskell-ts-test-align-guards ()
  "Guard right-hand sides align on their `=', leaving the guards alone."
  (should (equal (haskell-ts-tests--align
                  (concat "  | x > 0 = \"pos\"\n"
                          "  | otherwise = \"neg\"\n"))
                 (concat "  | x > 0     = \"pos\"\n"
                         "  | otherwise = \"neg\"\n"))))

(ert-deftest haskell-ts-test-align-keeps-operators ()
  "Only the binding `=' is aligned; `==' and `/=' on the line are untouched."
  (should (equal (haskell-ts-tests--align
                  (concat "a = x == y\n"
                          "bb = p /= q\n"))
                 (concat "a  = x == y\n"
                         "bb = p /= q\n"))))

(ert-deftest haskell-ts-test-align-leaves-fat-arrow-line ()
  "A line whose only `='-like token is `=>' is never modified."
  (should (equal (haskell-ts-tests--align "f :: Eq a => a -> Bool\n")
                 "f :: Eq a => a -> Bool\n")))

(ert-deftest haskell-ts-test-align-idempotent ()
  "Re-aligning already-aligned bindings changes nothing."
  (let ((aligned (concat "x   = 1\n"
                         "foo = 2\n"
                         "ab  = 3\n")))
    (should (equal (haskell-ts-tests--align aligned) aligned))))

;;; Virtual-text mapping helpers
;;;
;;; `haskell-ts--virtual-text-and-table' and its inverse pair
;;; `haskell-ts--real-to-virtual'/`haskell-ts--virtual-to-real' operate
;;; on plain (START . END) buffer ranges, so they can be exercised
;;; directly -- no parser, no grammar -- with hand-built segments.

(ert-deftest haskell-ts-test-virtual-text-and-table-roundtrip ()
  "Two segments join with a single newline and map back and forth 1:1.
A position in the stripped gap between segments (a continuation
marker) maps forward to the next segment, flagged as on-a-marker."
  (with-temp-buffer
    (insert "aaa\nBBB\nccc")           ; "BBB" stands in for a stripped marker
    (let* ((segments '((1 . 4) (9 . 12)))
           (tt (haskell-ts--virtual-text-and-table segments))
           (vtext (car tt))
           (table (cdr tt)))
      (should (equal vtext "aaa\nccc"))
      ;; Every real point inside a segment round-trips exactly and is
      ;; not flagged as sitting on a stripped marker.
      (dolist (real '(1 2 4 9 11 12))
        (let ((loc (haskell-ts--real-to-virtual real table)))
          (should-not (cdr loc))
          (should (= real (haskell-ts--virtual-to-real (car loc) table)))))
      ;; A point in the gap ("BBB") has no virtual counterpart: it is
      ;; flagged and clamped forward to the next segment's start.
      (let ((loc (haskell-ts--real-to-virtual 6 table)))
        (should (cdr loc))
        (should (= 9 (haskell-ts--virtual-to-real (car loc) table)))))))

;;; --------------------------------------------------------------------
;;; Grammar-dependent integration tests (skipped without the grammar)
;;; --------------------------------------------------------------------

(defconst haskell-ts-tests--sample
  "module Main (main) where

import Data.List (sort)

-- | A greeting.
greeting :: String -> String
greeting name = \"Hello, \" ++ name

data Color = Red | Green | Blue

type Name = String

main :: IO ()
main = putStrLn (greeting \"world\")
"
  "A small but representative Haskell source used by integration tests.")

(ert-deftest haskell-ts-test-mode-activates ()
  "`haskell-ts-mode' activates and installs a primary parser."
  (haskell-ts-tests--with-temp-hs
      haskell-ts-tests--sample
    (should (eq major-mode 'haskell-ts-mode))
    (should treesit-primary-parser)
    (should (treesit-parser-p treesit-primary-parser))))

(ert-deftest haskell-ts-test-font-lock-applies ()
  "Fontifying the sample assigns the keyword face to `module'."
  (haskell-ts-tests--with-temp-hs
      haskell-ts-tests--sample
    (treesit-font-lock-fontify-region (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "module")
    (should (eq 'font-lock-keyword-face
                (get-text-property (match-beginning 0) 'face)))))

(ert-deftest haskell-ts-test-imenu-entries ()
  "Imenu finds the top-level functions, the signature, the data type
and the type synonym from the sample."
  (haskell-ts-tests--with-temp-hs
      haskell-ts-tests--sample
    (let* ((index (funcall imenu-create-index-function))
           (flatten (lambda (alist)
                      ;; Collapse one level of submenus (e.g. "Signatures..").
                      (cl-loop for entry in alist
                               if (and (consp (cdr entry))
                                       (consp (cadr entry)))
                               append (mapcar #'car (cdr entry))
                               else collect (car entry))))
           (names (funcall flatten index)))
      (should (member "main" names))
      (should (member "greeting" names))
      (should (member "Color" names))
      (should (member "Name" names)))))

(ert-deftest haskell-ts-test-imenu-collapses-equations ()
  "A function's multiple equations collapse to a single imenu entry."
  (haskell-ts-tests--with-temp-hs
      "fib :: Int -> Int
fib 0 = 1
fib 1 = 1
fib n = fib (n - 1) + fib (n - 2)

main :: IO ()
main = print (fib 10)
"
    (let* ((index (funcall imenu-create-index-function))
           ;; The top-level (uncategorised) function entries.
           (funcs (cl-remove-if (lambda (e) (consp (cdr e))) index))
           (names (mapcar #'car funcs)))
      ;; `fib' has three equations but must appear exactly once.
      (should (equal 1 (cl-count "fib" names :test #'equal)))
      (should (member "main" names)))))

(ert-deftest haskell-ts-test-defun-navigation ()
  "`treesit-defun-name' reads the name of the function at point."
  (haskell-ts-tests--with-temp-hs
      haskell-ts-tests--sample
    (goto-char (point-min))
    (search-forward "greeting name")
    (let ((node (treesit-defun-at-point)))
      (should node)
      (should (equal "greeting" (haskell-ts-defun-name node))))))

(ert-deftest haskell-ts-test-defun-name-infix ()
  "`haskell-ts-defun-name' returns just the operator for an infix-headed
definition, not the whole left-hand pattern.
Regression test: the left-hand side of `a <+> b = ...' is an `infix'
node whose text is the entire `a <+> b'; `haskell-ts-defun-name' (used
for e.g. which-function-mode) returned that instead of the operator.
Covers both a symbolic operator and a backtick-quoted identifier."
  (haskell-ts-tests--with-temp-hs "a <+> b = a\nx `op` y = x\n"
    (goto-char (point-min))
    (search-forward "<+>")
    (should (equal "<+>" (haskell-ts-defun-name (treesit-defun-at-point))))
    (search-forward "`op`")
    (should (equal "`op`" (haskell-ts-defun-name (treesit-defun-at-point))))))

(ert-deftest haskell-ts-test-send-defun ()
  "`haskell-ts-send-defun' sends the definition at point via `:{'/`:}'.
The definition found by `treesit-defun-at-point' -- the same node
`haskell-ts-test-defun-navigation' checks -- is what gets wrapped and
sent, not the whole buffer or an unrelated definition."
  (haskell-ts-tests--with-temp-hs
      haskell-ts-tests--sample
    (goto-char (point-min))
    (search-forward "greeting name")
    (let (sent)
      (cl-letf (((symbol-function 'haskell-ts-show-repl) (lambda () 'fake-proc))
                ((symbol-function 'comint-send-string)
                 (lambda (_proc str) (setq sent (concat sent str)))))
        (call-interactively #'haskell-ts-send-defun))
      (should (string-match-p
               "greeting name = \"Hello, \" \\+\\+ name" sent))
      (should-not (string-match-p "module Main" sent)))))

(ert-deftest haskell-ts-test-send-defun-no-defun ()
  "`haskell-ts-send-defun' signals `user-error' outside any definition.
The module header at the start of `haskell-ts-tests--sample' is not
itself a `declarations' child, so no defun is found there."
  (haskell-ts-tests--with-temp-hs
      haskell-ts-tests--sample
    (goto-char (point-min))
    (should-error (call-interactively #'haskell-ts-send-defun)
                  :type 'user-error)))

(ert-deftest haskell-ts-test-imenu-infix-operator ()
  "Imenu lists an operator definition under just its operator, matching
`haskell-ts-defun-name' now that the two share their logic."
  (haskell-ts-tests--with-temp-hs "a <+> b = a\nmain = a <+> a\n"
    (let* ((index (funcall imenu-create-index-function))
           (funcs (cl-remove-if (lambda (e) (consp (cdr e))) index))
           (names (mapcar #'car funcs)))
      (should (member "<+>" names))
      (should-not (member "a <+> b" names)))))

(ert-deftest haskell-ts-test-sexp-navigation ()
  "`forward-sexp'/`backward-sexp' step by `haskell-ts-sexp' nodes.
A parenthesised group is one sexp, and list elements are stepped over
individually in either direction.  This is the package's namesake
motion, exercised via `treesit-thing-settings'."
  ;; A parenthesised group is traversed as a single sexp.
  (haskell-ts-tests--with-temp-hs
      "r = f (g x) y\n"
    (goto-char (point-min))
    (search-forward "f ")
    (let ((start (point)))
      (forward-sexp)
      (should (equal "(g x)"
                     (buffer-substring-no-properties start (point))))))
  ;; Individual list elements are stepped over, forward and backward.
  (haskell-ts-tests--with-temp-hs
      "xs = [foo, bar, baz]\n"
    (goto-char (point-min))
    (search-forward "[")
    (let ((start (point)))
      (forward-sexp)
      (should (equal "foo" (buffer-substring-no-properties start (point)))))
    (goto-char (point-min))
    (search-forward "baz")
    (let ((end (point)))
      (backward-sexp)
      (should (equal "baz" (buffer-substring-no-properties (point) end))))))

(ert-deftest haskell-ts-test-sexp-top-level ()
  "`forward-sexp' at column 0 of a top-level binding steps over that one
binding, not the whole buffer.
Regression test: the root `haskell' node and the top-level
`declarations' wrapper both matched `haskell-ts-sexp', so from column
0 `treesit-forward-sexp' took the whole run of declarations as the
next sexp and jumped to `point-max' (and `backward-sexp' from the last
binding's end to `point-min')."
  (haskell-ts-tests--with-temp-hs "x = 1\ny = 2\nz = 3\n"
    (goto-char (point-min))
    (forward-sexp)
    (should (equal "x = 1"
                   (buffer-substring-no-properties (point-min) (point))))
    (should (< (point) (point-max)))    ; not the whole buffer
    ;; Keeps stepping binding by binding rather than to the buffer end.
    (forward-sexp)
    (should (equal "\ny = 2"
                   (buffer-substring-no-properties 6 (point))))))

(ert-deftest haskell-ts-test-sexp-backward-top-level ()
  "`backward-sexp' between top-level bindings steps over one binding, and
from the last binding's end never runs back to `point-min'.
Regression guard for the mirror of `haskell-ts-test-sexp-top-level':
before the fix, `backward-sexp' from the end of the last binding took
the whole run of declarations as one sexp and jumped to `point-min'."
  (haskell-ts-tests--with-temp-hs "x = 1\ny = 2\nz = 3\n"
    ;; From the end of a non-final binding, step back over just it.
    (goto-char (point-min))
    (search-forward "y = 2")
    (let ((end (point)))
      (backward-sexp)
      (should (equal "y = 2"
                     (buffer-substring-no-properties (point) end))))
    ;; From the end of the last binding, do not swallow back to `point-min'.
    ;; (Point at a top-level boundary may not move at all; either way it
    ;; must stay well past the start of the buffer.)
    (goto-char (point-min))
    (search-forward "z = 3")
    (backward-sexp)
    (should (> (point) (point-min)))))

(ert-deftest haskell-ts-test-sexp-nested-declarations ()
  "Excluding the top-level `declarations' wrapper from `haskell-ts-sexp'
leaves sexp motion inside a `where'/`let' block unchanged.
A nested `declarations' run is bounded by its enclosing binding, so it
never gets picked as the coarse \"next sexp\" the way the top-level one
did; motion there still steps binding by binding."
  ;; `where' block: step over each local binding in turn.
  (haskell-ts-tests--with-temp-hs "f = a\n  where a = 1\n        b = 2\n"
    (goto-char (point-min))
    (search-forward "where ")
    (let ((start (point)))
      (forward-sexp)
      (should (equal "a = 1"
                     (buffer-substring-no-properties start (point)))))
    (forward-sexp)
    (should (string-suffix-p "b = 2"
                             (buffer-substring-no-properties (point-min) (point)))))
  ;; `let' block inside a `do': likewise, one local binding at a time.
  (haskell-ts-tests--with-temp-hs "main = do\n  let x = 1\n      y = 2\n  print x\n"
    (goto-char (point-min))
    (search-forward "let ")
    (let ((start (point)))
      (forward-sexp)
      (should (equal "x = 1"
                     (buffer-substring-no-properties start (point)))))))

(ert-deftest haskell-ts-test-sentence-motion-confined-to-comment ()
  "Sentence motion inside a `--' comment never crosses into surrounding
code, with code both directly above and below the comment (no blank
line separating either side, so `prog-mode' paragraph boundaries
don't help).
Regression test, two bugs in sequence:
- `text' in `haskell-ts-thing-settings' must include `comment' (not
  just `string'), or `treesit-forward-sentence' treats the comment as
  code and jumps by the code-level `sentence' thing (a `match' node),
  landing in the following function.
- Even with that fixed, `forward-sentence-default-function' is
  paragraph-based; since a comment glued to code is not its own
  paragraph, backward motion runs all the way up through the
  preceding code (this is what broke an `evil' `d a s' text object
  on such a comment) unless `haskell-ts--forward-sentence' narrows to
  the comment node's bounds first."
  (haskell-ts-tests--with-temp-hs
      "module Main where

greeting :: String
greeting = \"hi\"
-- Hello. This is a sentence.
main :: IO ()
main = putStrLn greeting
"
    (search-forward "is a")
    (let* ((comment-start (line-beginning-position))
           (comment-end (line-end-position))
           (start (point)))
      (forward-sentence)
      (should (< start (point)))
      (should (<= (point) comment-end))
      (goto-char start)
      (backward-sentence)
      (should (< (point) start))
      (should (>= (point) comment-start)))))

(defun haskell-ts-tests--sentence-at-point ()
  "Return the text `backward-sentence'/`forward-sentence' bound at point.
This is what an `evil' `d a s' (or plain `M-a' `M-e') would operate on
from the current position.  The two bounds are computed independently
from the original point rather than chained (forward, then backward
from the result), since the latter can land exactly on the enclosing
comment node's end boundary, where `treesit-node-at' resolves to the
following node instead."
  (let ((beg (save-excursion (backward-sentence) (point)))
        (end (save-excursion (forward-sentence) (point))))
    (buffer-substring-no-properties beg end)))

(ert-deftest haskell-ts-test-sentence-excludes-comment-marker ()
  "Sentence motion never includes the comment's opening marker.
Regression test: a comment's `text' node starts at `--' (or `-- |'
for Haddock) itself, so without excluding the marker from the
narrowed region in `haskell-ts--forward-sentence', selecting the
comment's first sentence also selects -- and an `evil' `d a s' also
deletes -- the marker, turning the comment into code."
  (haskell-ts-tests--with-temp-hs
      "-- | Module bla.

x :: Int
x = 10

-- Hello. This is a sentence.
"
    (search-forward "Module")
    (should (equal "Module bla." (haskell-ts-tests--sentence-at-point)))
    (search-forward "Hell")
    (should (equal "Hello." (haskell-ts-tests--sentence-at-point)))))

(ert-deftest haskell-ts-test-backward-sentence-noop-on-marker ()
  "`backward-sentence' never moves point backward past its own start
when point sits on a comment's opening marker (before the trimmed
sentence text) -- it should leave point where it is, at most.
Regression test: `narrow-to-region' clamps an out-of-range point
forward into the narrowed part before searching, so without a
directional guard, calling `backward-sentence' from the marker moves
point FORWARD instead.  `evil'\\='s `evil-bounds-of-not-thing-at-point'
infers \"already at the start of the buffer\" whenever a backward
attempt reports net forward motion, so this single wrong-direction
move is what turns an `evil' `d a s' on the very next sentence into
deleting from the start of the buffer."
  (haskell-ts-tests--with-temp-hs
      "-- | Module bla.\n"
    (goto-char (point-min))
    (forward-char 4)                   ; right after `-- |', before the space
    (let ((start (point)))
      (backward-sentence)
      (should (<= (point) start)))))

(ert-deftest haskell-ts-test-sentence-motion-multiple-sentences-in-comment ()
  "Each sentence in a multi-sentence comment is bounded independently.
Regression test: with the default `sentence-end-double-space' (t),
`sentence-end' requires two spaces after a period, but Haddock/plain
comments conventionally use one; the first sentence then fails to
count as a sentence boundary at all, and motion from the second
sentence runs back through the first (and, per
`haskell-ts-test-sentence-motion-confined-to-comment', beyond)."
  (haskell-ts-tests--with-temp-hs
      "-- | Module bla.

x :: Int
x = 10

-- Hello. This is a sentence.
"
    (search-forward "is a")
    (should (equal "This is a sentence." (haskell-ts-tests--sentence-at-point)))))

(ert-deftest haskell-ts-test-sentence-paragraph-inside-multiline-comment ()
  "A blank (marker-only) line inside one multi-line Haddock comment is a
paragraph break.
Regression test: the grammar folds a run of adjacent `--' lines with
no intervening blank *code* line into a single `haddock' node, so a
`--'-only line meant to separate paragraphs is not a real blank line
in the buffer and does not register with `paragraph-separate' on its
own -- sentence motion ran through it into the next paragraph unless
`haskell-ts--forward-sentence' dedents (strips the repeated marker
from) each line before running prose motion."
  (haskell-ts-tests--with-temp-hs
      "-- | Hello
--
-- This sentence is deleted when deleting around sentence from Hello above
-- (e.g., cursor at _1). It shouldn't be!
module Test () where
"
    (search-forward "Hel")
    (should (equal "Hello" (haskell-ts-tests--sentence-at-point)))
    (search-forward "shouldn")
    (should (equal "It shouldn't be!" (haskell-ts-tests--sentence-at-point)))))

(ert-deftest haskell-ts-test-backward-sentence-noop-on-continuation-marker ()
  "Like `haskell-ts-test-backward-sentence-noop-on-marker', but for a
continuation line's repeated marker rather than the comment's opening
one -- `backward-sentence' never moves point forward past it."
  (haskell-ts-tests--with-temp-hs
      "-- | Long sentence that\n-- continues. Short.\n"
    (goto-char (point-min))
    (search-forward "\n-- continues")   ; right after the newline, before `--'
    (let ((start (point)))
      (backward-sentence)
      (should (<= (point) start)))))

(ert-deftest haskell-ts-test-sentence-motion-in-string ()
  "Prose motion inside a string treats its interior as text.
The surrounding quotes are stripped like a comment's `--' marker, so
a sentence never includes them."
  (haskell-ts-tests--with-temp-hs
      "x = \"First. Second. Third.\"\n"
    (search-forward "First")
    (should (equal "First." (haskell-ts-tests--sentence-at-point)))
    (search-forward "Second")
    (should (equal "Second." (haskell-ts-tests--sentence-at-point)))))

(ert-deftest haskell-ts-test-sentence-motion-in-block-comment ()
  "Prose motion inside a `{- -}' block comment works.
The grammar folds the closing `-}' into the comment's content; it is
trimmed off so it never counts as sentence text."
  (haskell-ts-tests--with-temp-hs
      "{- First. Second. -}\nx = 1\n"
    (search-forward "First")
    (should (equal "First." (haskell-ts-tests--sentence-at-point)))
    (search-forward "Second")
    (should (equal "Second." (haskell-ts-tests--sentence-at-point)))))

(ert-deftest haskell-ts-test-sentence-motion-stops-at-comment-end ()
  "`forward-sentence' at a comment's last sentence stops at the comment's
end without signalling, even though code follows below.
Regression test: prose motion runs in a scratch buffer holding only
the comment's text, so reaching its end raised a buffer-edge error --
which, unlike at the real buffer's edge, fired mid-file and broke
plain `M-e'/`kill-sentence' on a comment glued to code.  Point must
stop at the boundary (not spill into the code) and not error."
  (haskell-ts-tests--with-temp-hs
      "-- One sentence.\nmain = putStrLn x\n"
    (search-forward "One")
    (forward-sentence)                  ; move to the comment's end
    (let ((at-end (point)))
      (forward-sentence)                ; must neither error nor advance
      (should (= (point) at-end)))))

(ert-deftest haskell-ts-test-sentence-in-code-confined-to-paragraph ()
  "Sentence motion in code stops at the paragraph boundary, not the next
function equation across it.
Regression test: `treesit-forward-sentence' treats a function equation
\(`match' node) as a sentence and hunts for the next one across any
number of blank lines and comments, so from a `data' declaration `M-e'
\(and thus `evil''s `a s') ran clear past the blank line and comment
below into the following binding.  `haskell-ts--forward-sentence'
bounds the motion by the paragraph instead."
  (haskell-ts-tests--with-temp-hs
      "data Hu_hu = Huhu

-- Why should we freeze the bread? We have rolls, and things.
f = id
g = id
"
    (search-forward "Hu_")
    ;; The whole declaration line, nothing past the blank line below it.
    (should (equal "data Hu_hu = Huhu"
                   (haskell-ts-tests--sentence-at-point)))
    (let ((decl-end (line-end-position)))
      (forward-sentence)
      (should (= (point) decl-end))     ; end of the declaration, not below
      (backward-sentence)
      (should (= (point) (line-beginning-position))))))

(ert-deftest haskell-ts-test-sentence-in-code-keeps-equation-granularity ()
  "Sentence motion in code still steps equation by equation within one
paragraph.
Confining the motion to the current paragraph (see
`haskell-ts-test-sentence-in-code-confined-to-paragraph') must not
coarsen it: two adjacent bindings with no blank line between them are
still separate sentences, as `treesit-forward-sentence' has them, not
one paragraph-sized sentence spanning both."
  (haskell-ts-tests--with-temp-hs
      "f = id\ng = id\n"
    (goto-char (point-min))
    (forward-sentence)                  ; end of the first equation
    (should (= (point) (line-end-position 1)))))

(ert-deftest haskell-ts-test-sentence-in-code-confined-by-glued-comment ()
  "Sentence motion in code stops at a comment glued to it with no blank
line between, on both sides.
Regression test: `forward-sentence-default-function' reads a comment
glued directly to code as part of the same paragraph, so the
blank-line paragraph bound alone did not stop motion at it;
`haskell-ts--forward-sentence' also clamps to the nearest comment
edge."
  ;; Comment glued below: forward stops before the comment line.
  (haskell-ts-tests--with-temp-hs
      "data X = X\n-- c.\nf = id\n"
    (search-forward "data X")
    (should (equal "data X = X"
                   (haskell-ts-tests--sentence-at-point))))
  ;; Comment glued above: backward stays in the code, not up into the comment.
  (haskell-ts-tests--with-temp-hs
      "-- c.\ndata X = X\n"
    (search-forward "data X")
    (let ((code-bol (line-beginning-position)))
      (backward-sentence)
      (should (>= (point) code-bol)))))

(ert-deftest haskell-ts-test-sentence-in-code-keeps-string-whole ()
  "A period inside a string literal does not split a code sentence.
Regression test: the mode sets `sentence-end-double-space' nil (for
one-space-after-period comments), so `forward-sentence-default-function'
would treat a `. ' inside a string as a sentence end and stop there;
code sentence motion is bounded by the paragraph, not that function, so
the whole equation is one sentence."
  (haskell-ts-tests--with-temp-hs
      "foo = \"a. b. c\"\ng = id\n"
    (goto-char (point-min))
    (forward-sentence)
    (should (= (point) (line-end-position 1)))))

;;; `newline' comment continuation

(ert-deftest haskell-ts-test-newline-continues-line-comment ()
  "Breaking the line inside a `--' comment repeats the marker.
Also covers a direct, non-interactive call to `newline' -- the path
Evil's `o'/`O' use, bypassing the keymap entirely."
  (haskell-ts-tests--with-temp-hs
      "-- Comment"
    (goto-char (point-max))
    (newline)
    (should (equal (buffer-string) "-- Comment\n-- "))
    (should (= (point) (point-max)))))

(ert-deftest haskell-ts-test-newline-continues-indented-haddock ()
  "The repeated marker keeps the original line's indentation."
  (haskell-ts-tests--with-temp-hs
      "    -- | Haddock doc"
    (goto-char (point-max))
    (newline)
    (should (equal (buffer-string) "    -- | Haddock doc\n    -- "))))

(ert-deftest haskell-ts-test-newline-leaves-block-comment-alone ()
  "A `{- -}' block comment is not mistaken for a `--' line comment."
  (haskell-ts-tests--with-temp-hs
      "{- block"
    (goto-char (point-max))
    (newline)
    (should (equal (buffer-string) "{- block\n"))))

(ert-deftest haskell-ts-test-newline-leaves-code-alone ()
  "Outside a comment, `newline' is unaffected by the advice."
  (haskell-ts-tests--with-temp-hs
      "foo = 1"
    (goto-char (point-max))
    (newline)
    (should (equal (buffer-string) "foo = 1\n"))))

(ert-deftest haskell-ts-test-newline-above-comment-does-not-continue-it ()
  "`newline' on a blank line above a comment does not continue it.
Regression test: `treesit-node-at' returns the first node *after*
POS when POS sits in whitespace covered by no node -- as a blank
line above a comment is -- rather than nil, so a check that the
found node actually starts at or before POS is needed to tell
\"before the comment\" apart from \"inside it\"."
  (haskell-ts-tests--with-temp-hs
      "\n-- Comment."
    (goto-char (point-min))
    (newline)
    (should (equal (buffer-string) "\n\n-- Comment."))))

(ert-deftest haskell-ts-test-newline-below-buffer-final-comment-does-not-continue-it ()
  "`newline' on a blank line below a buffer-final comment does not
continue it.
Regression test: `treesit-node-at' returns the *previous* node when
POS sits in whitespace covered by no node and nothing follows to fall
forward to -- as the blank line below a buffer-final comment is --
rather than nil, so a check that the found node actually ends after
POS (not just starts at or before it) is needed to tell \"just below
the comment\" apart from \"inside it\"."
  (haskell-ts-tests--with-temp-hs
      "-- Bla\n--\n\n"
    (goto-char (point-max))
    (newline)
    (should (equal (buffer-string) "-- Bla\n--\n\n\n"))))

(ert-deftest haskell-ts-test-newline-repeated-on-bare-marker ()
  "Breaking the line again on a bare `-- ' line keeps the trailing space.
Regression test: delegating to `default-indent-new-line' (as the
original, broken implementation did) runs `delete-horizontal-space'
around the break point, which strips a bare marker's trailing space
before it is captured for re-insertion -- and since the new line is
bare again, every subsequent `newline' reproduces the strip."
  (haskell-ts-tests--with-temp-hs
      "-- foo"
    (goto-char (point-max))
    (newline)
    (should (equal (buffer-string) "-- foo\n-- "))
    (newline)
    (should (equal (buffer-string) "-- foo\n-- \n-- "))
    (should (= (point) (point-max)))))

(ert-deftest haskell-ts-test-newline-honours-repeat-count ()
  "`newline' with a repeat count continues each requested line.
Regression test: the advice inserted a single continuation
unconditionally, silently dropping `newline''s count argument."
  (haskell-ts-tests--with-temp-hs
      "-- foo"
    (goto-char (point-max))
    (newline 2)
    (should (equal (buffer-string) "-- foo\n-- \n-- "))
    (should (= (point) (point-max)))))

(ert-deftest haskell-ts-test-align-wired-into-mode ()
  "The mode installs the align rule buffer-locally and \\[align] works.
This is the end-to-end check that plain `M-x align' aligns `=' in a
real `haskell-ts-mode' buffer; it needs the grammar to activate the mode."
  (require 'align)
  (haskell-ts-tests--with-temp-hs
      "x = 1\nfoo = 2\nab = 3\n"
    (should (local-variable-p 'align-mode-rules-list))
    (should (equal align-mode-rules-list haskell-ts-align-rules-list))
    (let ((indent-tabs-mode nil))
      (align (point-min) (point-max)))
    (should (equal (buffer-string)
                   (concat "x   = 1\n"
                           "foo = 2\n"
                           "ab  = 3\n")))))

;;; --------------------------------------------------------------------
;;; Evil integration tests (skipped unless `evil' is available)
;;; --------------------------------------------------------------------
;;;
;;; `haskell-ts-mode' does not depend on `evil'.  These tests exercise
;;; `evil-select-an-object'/`evil-select-inner-object' (what `d a s'/
;;; `d i s' call) directly rather than through `execute-kbd-macro':
;;; the latter turned out to be unreliable in `--batch' mode -- it lost
;;; track of the current buffer even for a plain `x' in a plain-text
;;; buffer, unrelated to anything under test here.

(defmacro haskell-ts-tests--with-temp-hs-evil (text &rest body)
  "Like `haskell-ts-tests--with-temp-hs', but also enable `evil-local-mode'.
Skips the test unless `evil' can be loaded (see `HASKELL_TS_EVIL_PATH'
above)."
  (declare (indent 1) (debug (form body)))
  `(progn
     (skip-unless (require 'evil nil t))
     (haskell-ts-tests--with-temp-hs
         ,text
       (evil-local-mode 1)
       (evil-normal-state)
       ,@body)))

(defun haskell-ts-tests--evil-object-at (needle selector &optional thing line)
  "Move to just after NEEDLE and return the text SELECTOR selects.
SELECTOR is `evil-select-an-object' or `evil-select-inner-object',
called for THING (`evil-sentence' by default).  LINE matches the
LINE argument the real `evil-a-paragraph'/`evil-inner-paragraph'
text objects pass (t, since paragraph objects are linewise) -- it
matters here because it changes which internal helper functions
`evil' calls, not just the returned range's type."
  (goto-char (point-min))
  (search-forward needle)
  (let ((range (funcall selector (or thing 'evil-sentence) nil nil 'inclusive 1 line)))
    (buffer-substring-no-properties
     (evil-range-beginning range) (evil-range-end range))))

(defconst haskell-ts-tests--evil-sentence-sample
  "-- | Module bla.

x :: Int
x = 10

-- Hello. This is a sentence.
"
  "Sample reproducing the reported `evil' sentence-object bugs:
comments with no preceding `match' node (only bindings, signatures
and other comments), a comment with more than one sentence, and a
Haddock marker (`-- |') distinct from a plain one (`--').")

(ert-deftest haskell-ts-test-evil-a-sentence ()
  "`evil-a-sentence' (`d a s') never includes a comment's marker or
spills into surrounding code -- including with point on the marker
itself, where the worst case is one adjoining space."
  (haskell-ts-tests--with-temp-hs-evil
      haskell-ts-tests--evil-sentence-sample
    (should (equal "Module bla."
                   (haskell-ts-tests--evil-object-at "-- | M" #'evil-select-an-object)))
    (should (equal "Hello. "
                   (haskell-ts-tests--evil-object-at "Hell" #'evil-select-an-object)))
    (should (equal " This is a sentence."
                   (haskell-ts-tests--evil-object-at "is a" #'evil-select-an-object)))
    (should (equal " Module bla."
                   (haskell-ts-tests--evil-object-at "-- |" #'evil-select-an-object)))))

(ert-deftest haskell-ts-test-evil-a-sentence-in-code-confined-to-paragraph ()
  "`d a s'/`v a s' in code stays within the paragraph, not down into the
next function equation across a blank line and comment.
Regression test for the reported bug: with point in `data Hu_hu = Huhu',
`v a s' selected everything through the blank line and comment below and
on into `f = id'; `haskell-ts--forward-sentence' now bounds code
sentence motion to the paragraph."
  (haskell-ts-tests--with-temp-hs-evil
      "data Hu_hu = Huhu

-- Why should we freeze the bread? We have rolls, and things.
f = id
g = id
"
    (should (equal "data Hu_hu = Huhu"
                   (haskell-ts-tests--evil-object-at "Hu_" #'evil-select-an-object)))))

(ert-deftest haskell-ts-test-evil-inner-sentence ()
  "`evil-inner-sentence' (`d i s') never includes a comment's marker or
spills into surrounding code -- including with point on the marker
itself, where the worst case is a single stray space."
  (haskell-ts-tests--with-temp-hs-evil
      haskell-ts-tests--evil-sentence-sample
    (should (equal "Module bla."
                   (haskell-ts-tests--evil-object-at "-- | M" #'evil-select-inner-object)))
    (should (equal "Hello."
                   (haskell-ts-tests--evil-object-at "Hell" #'evil-select-inner-object)))
    (should (equal "This is a sentence."
                   (haskell-ts-tests--evil-object-at "is a" #'evil-select-inner-object)))
    (should (equal " "
                   (haskell-ts-tests--evil-object-at "-- |" #'evil-select-inner-object)))))

(ert-deftest haskell-ts-test-evil-a-sentence-paragraph-inside-comment ()
  "`d a s' on a comment's first paragraph never reaches into a later
paragraph of the same multi-line comment.
Regression test for the originally reported bug: without dedenting
each line before running prose motion, a `--'-only line between two
paragraphs of one `haddock' node is not a paragraph break, and `d a s'
on \"Hello\" swallows the entire next paragraph too."
  (haskell-ts-tests--with-temp-hs-evil
      "-- | Hello
--
-- This is the next paragraph.
"
    (should (equal "Hello"
                   (haskell-ts-tests--evil-object-at "Hel" #'evil-select-an-object)))))

(ert-deftest haskell-ts-test-evil-a-paragraph-inside-comment ()
  "`d a p' on one paragraph of a multi-line comment never reaches into
a later paragraph of the same comment, even when a real blank line
(a separate `haddock' node) follows.
Regression test: a `--'-only line between two paragraphs of one
`haddock' node is not a real blank line in the buffer, so
`paragraph-start'/`paragraph-separate' must be taught to treat it as
one -- `forward-paragraph'/`backward-paragraph' (unlike sentence
motion) work directly off those variables, not off
`haskell-ts--forward-sentence''s dedented copy."
  (haskell-ts-tests--with-temp-hs-evil
      "-- Paragraph 1
--
-- Paragraph 2

-- Paragraph 3
"
    (should (equal "-- Paragraph 1\n--\n"
                   (haskell-ts-tests--evil-object-at
                    "Paragraph 1" #'evil-select-an-object 'evil-paragraph t)))
    (should (equal "-- Paragraph 2\n\n"
                   (haskell-ts-tests--evil-object-at
                    "Paragraph 2" #'evil-select-an-object 'evil-paragraph t)))
    (should (equal "\n-- Paragraph 3\n"
                   (haskell-ts-tests--evil-object-at
                    "Paragraph 3" #'evil-select-an-object 'evil-paragraph t)))))

(ert-deftest haskell-ts-test-evil-a-paragraph-glued-to-code ()
  "`d a p' on a `--' comment with code directly above and below it (no
blank line separating either side) is confined to the comment alone.
Regression test: `paragraph-start'/`paragraph-separate' cannot mark a
glued comment's boundary against code the way they can a marker-only
line inside one multi-line comment (see
`haskell-ts-test-evil-a-paragraph-inside-comment'), so without
`haskell-ts--confine-evil-paragraph-object' narrowing the buffer to
the comment before `evil' computes the object, `d a p' swallowed the
function above and below it too."
  (haskell-ts-tests--with-temp-hs-evil
      "f = x
-- Comment
g = y
"
    (should (equal "-- Comment\n"
                   (haskell-ts-tests--evil-object-at
                    "Comment" #'evil-select-an-object 'evil-paragraph t)))))

(ert-deftest haskell-ts-test-evil-a-paragraph-glued-to-code-below-only ()
  "`d a p' on a Haddock comment preceded by a blank line but glued
directly to code below (no blank line there) is confined to the
comment alone, on both sides.
Regression test: clamping a glued boundary to `treesit-node-end'
itself, rather than one past it, left point exactly at the comment's
last character with nothing beyond within the clamp to move into.
`bounds-of-thing-at-point' -- which restores point since it wraps its
own probing in `save-excursion' -- then finds point is not *strictly
before* that (unmoved) end, so `evil-select-an-object' decides the
comment is not the object at point after all, and falls through to
its no-thing-found fallback of `(point-min) . (point-max)': every
line from the start of the buffer, not just the comment.  Distinct
from `haskell-ts-test-evil-a-paragraph-glued-to-code' above: there,
both sides are glued, so that same wrong fallback range happens to
still coincide with the comment's own (narrowed) bounds; here, only
the *below* side is glued, so the fallback's un-narrowed above side
gives the wrong, too-large answer instead."
  (haskell-ts-tests--with-temp-hs-evil
      "f = x

-- | This is a sentence and a paragraph.
g = id
"
    (should (equal "\n-- | This is a sentence and a paragraph.\n"
                   (haskell-ts-tests--evil-object-at
                    "paragraph." #'evil-select-an-object 'evil-paragraph t)))))

(ert-deftest haskell-ts-test-evil-a-paragraph-from-code-glued-to-comment ()
  "`d a p' from *code* glued to a comment above it (no blank line
there) stays within that code+comment pair -- it must not reach into
a second, unrelated comment+code pair elsewhere in the buffer.
Regression test: `bounds-of-thing-at-point' and `evil''s
whitespace-detection helpers re-probe with `forward-paragraph'/
`start-of-paragraph-text' from intermediate positions found while
computing an object's bounds -- here, from point in \"f = id\", one
such probe lands on the *first character* of the unrelated \"-- | Hello\"
comment.  `haskell-ts--confine-paragraph-motion' used to clamp that
probe to `--| Hello''s own bounds regardless of where the object being
computed actually started, breaking the invariant `evil' relies on
that `forward-paragraph' reaches the same end from any point within an
object -- one probe got clamped, another (from \"f = id\" itself) did
not, and `evil' concluded there was no consistent object at point at
all, falling back to selecting from the start of the buffer.
`haskell-ts--confining-evil-paragraph-object' now suppresses that
per-call clamp for the whole `evil-select-an-object' call, deferring
entirely to the buffer-narrowing `haskell-ts--confine-evil-paragraph-object'
already applies once, consistently, for the object's own start."
  (haskell-ts-tests--with-temp-hs-evil
      "-- | Hello
f = id

-- | Test.
g = id
"
    (should (equal "-- | Hello\nf = id\n\n"
                   (haskell-ts-tests--evil-object-at
                    "id" #'evil-select-an-object 'evil-paragraph t)))))

;;; `evil' `o'/`O' comment continuation

(ert-deftest haskell-ts-test-evil-open-below-continues-comment ()
  "Evil's `o' (`evil-open-below') continues a `--' comment like `RET' does.
Regression test: `evil-insert-newline-below' breaks the line with a
plain `insert', bypassing `newline' -- and the advice on it -- entirely,
so it needs the dedicated advice on `evil-insert-newline-below' to pick
up the same continuation."
  (haskell-ts-tests--with-temp-hs-evil
      "-- Comment"
    (goto-char (point-max))
    (evil-open-below 1)
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "-- Comment\n-- "))
    (should (= (point) (point-max)))))

(ert-deftest haskell-ts-test-evil-open-above-continues-comment ()
  "Evil's `O' (`evil-open-above') continues a `--' comment above it.
Same rationale as `haskell-ts-test-evil-open-below-continues-comment',
but for `evil-insert-newline-above': the new blank line precedes the
original one and point lands right after the repeated marker."
  (haskell-ts-tests--with-temp-hs-evil
      "-- Comment"
    (goto-char (point-max))
    (evil-open-above 1)
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "-- \n-- Comment"))
    (should (equal (buffer-substring-no-properties (point-min) (point)) "-- "))))

(provide 'haskell-ts-mode-tests)
;;; haskell-ts-mode-tests.el ends here
