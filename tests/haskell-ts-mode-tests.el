;;; haskell-ts-mode-tests.el --- Tests for haskell-ts-mode -*- lexical-binding:t -*-

;; Copyright (C) 2025, 2026 Pranshu Sharma

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
              (keymap-lookup haskell-ts-mode-map "C-c C-c"))))

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
  (haskell-ts-tests--with-temp-hs haskell-ts-tests--sample
    (should (eq major-mode 'haskell-ts-mode))
    (should treesit-primary-parser)
    (should (treesit-parser-p treesit-primary-parser))))

(ert-deftest haskell-ts-test-font-lock-applies ()
  "Fontifying the sample assigns the keyword face to `module'."
  (haskell-ts-tests--with-temp-hs haskell-ts-tests--sample
    (treesit-font-lock-fontify-region (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "module")
    (should (eq 'font-lock-keyword-face
                (get-text-property (match-beginning 0) 'face)))))

(ert-deftest haskell-ts-test-imenu-entries ()
  "Imenu finds the top-level functions, the signature, the data type
and the type synonym from the sample."
  (haskell-ts-tests--with-temp-hs haskell-ts-tests--sample
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

(ert-deftest haskell-ts-test-defun-navigation ()
  "`treesit-defun-name' reads the name of the function at point."
  (haskell-ts-tests--with-temp-hs haskell-ts-tests--sample
    (goto-char (point-min))
    (search-forward "greeting name")
    (let ((node (treesit-defun-at-point)))
      (should node)
      (should (equal "greeting" (haskell-ts-defun-name node))))))

(ert-deftest haskell-ts-test-align-wired-into-mode ()
  "The mode installs the align rule buffer-locally and \\[align] works.
This is the end-to-end check that plain `M-x align' aligns `=' in a
real `haskell-ts-mode' buffer; it needs the grammar to activate the mode."
  (require 'align)
  (haskell-ts-tests--with-temp-hs "x = 1\nfoo = 2\nab = 3\n"
    (should (local-variable-p 'align-mode-rules-list))
    (should (equal align-mode-rules-list haskell-ts-align-rules-list))
    (let ((indent-tabs-mode nil))
      (align (point-min) (point-max)))
    (should (equal (buffer-string)
                   (concat "x   = 1\n"
                           "foo = 2\n"
                           "ab  = 3\n")))))

(provide 'haskell-ts-mode-tests)
;;; haskell-ts-mode-tests.el ends here
