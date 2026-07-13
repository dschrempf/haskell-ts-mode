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
;;   cabal component enumeration and the remembered-component/prefix
;;   override, prettify tables, customisation).  These run everywhere.
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

(ert-deftest haskell-ts-test-close-block-guard ()
  "A line that is exactly `:}' (modulo whitespace) is detected."
  (dolist (region '(":}"
                    "  :}"
                    ":}  "
                    "f x = x\n:}\ng y = y"))
    (should (string-match-p haskell-ts--close-block-re region)))
  (dolist (region '("foo :} bar"
                    "x = 1"
                    ":}}"
                    "a :}"))
    (should-not (string-match-p haskell-ts--close-block-re region))))

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

(ert-deftest haskell-ts-test-load-file-sends-load ()
  "`haskell-ts-load-file' saves the buffer and sends `:load \"<abspath>\"'."
  (let (sent (file (make-temp-file "haskell-ts-load-" nil ".hs")))
    (unwind-protect
        (cl-letf (((symbol-function 'haskell-ts-show-repl) (lambda () 'fake-proc))
                  ((symbol-function 'comint-send-string)
                   (lambda (_proc str) (setq sent (concat sent str)))))
          (with-temp-buffer
            (set-visited-file-name file t t)
            (insert "main = pure ()\n")
            (haskell-ts-load-file)))
      (delete-file file))
    (should (string-match-p (format ":load \"%s\"" (regexp-quote file)) sent))))

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

;;; Ambiguous `cabal repl' target resolution
;;
;; The fixtures below are real `cabal repl --dry-run' output, captured
;; from cabal-install 3.16.1.0 against synthetic two- and
;; three-component packages sharing one file.

(defconst haskell-ts-test--cabal-ambiguous-output-2
  "Error: [Cabal-7132]
Ambiguous target 'app/Main.hs'. It could be:
    exe1:app/Main.hs (file)
   exe2:app/Main.hs (file)

"
  "Real cabal output: `app/Main.hs' shared by two executables.")

(defconst haskell-ts-test--cabal-ambiguous-output-3
  "Error: [Cabal-7132]
Ambiguous target 'app/Main.hs'. It could be:
    spec:app/Main.hs (file)
   exe1:app/Main.hs (file)
   exe2:app/Main.hs (file)

"
  "Real cabal output: `app/Main.hs' shared by a test-suite and two executables.")

(ert-deftest haskell-ts-test-cabal-ambiguous-candidates-two ()
  "Parses both components, in cabal's printed order."
  (should (equal (haskell-ts--cabal-ambiguous-candidates
                  haskell-ts-test--cabal-ambiguous-output-2)
                 '("exe1" "exe2"))))

(ert-deftest haskell-ts-test-cabal-ambiguous-candidates-three ()
  "Parses all three components, in cabal's printed order."
  (should (equal (haskell-ts--cabal-ambiguous-candidates
                  haskell-ts-test--cabal-ambiguous-output-3)
                 '("spec" "exe1" "exe2"))))

(ert-deftest haskell-ts-test-cabal-ambiguous-candidates-unparseable ()
  "Output with no indented `component:path' lines yields no candidates."
  (should-not (haskell-ts--cabal-ambiguous-candidates
               "Error: [Cabal-7132]\nAmbiguous target 'app/Main.hs'.\n")))

(ert-deftest haskell-ts-test-choose-cabal-component-prompts ()
  "Prompts with `completing-read', requiring a match from CANDIDATES."
  (let (prompt collection require-match)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (p c &optional _pred rm &rest _)
                 (setq prompt p collection c require-match rm)
                 "exe2")))
      (should (equal (haskell-ts--choose-cabal-component
                      '("exe1" "exe2") "app/Main.hs")
                     "exe2")))
    (should (string-match-p "app/Main.hs" prompt))
    (should (equal collection '("exe1" "exe2")))
    (should require-match)))

(ert-deftest haskell-ts-test-cabal-file-target-single-component ()
  "A successful dry-run (exit 0) returns TARGET unchanged."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _) 0)))
    (should (equal (haskell-ts--cabal-file-target "/proj/" "app/Main.hs")
                   "app/Main.hs"))))

(ert-deftest haskell-ts-test-cabal-file-target-orphan ()
  "A failing dry-run unrelated to ambiguity returns nil."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _) (insert "cabal: no such file\n") 1)))
    (should-not (haskell-ts--cabal-file-target "/proj/" "app/Orphan.hs"))))

(ert-deftest haskell-ts-test-cabal-file-target-ambiguous-prompts-choice ()
  "An ambiguous target is resolved by prompting over cabal's candidates."
  (let (seen-candidates)
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _)
                 (insert haskell-ts-test--cabal-ambiguous-output-3)
                 1))
              ((symbol-function 'haskell-ts--choose-cabal-component)
               (lambda (candidates _target)
                 (setq seen-candidates candidates)
                 "exe2")))
      (should (equal (haskell-ts--cabal-file-target "/proj/" "app/Main.hs")
                     "exe2")))
    (should (equal seen-candidates '("spec" "exe1" "exe2")))))

(ert-deftest haskell-ts-test-cabal-file-target-ambiguous-unparseable-errors ()
  "An ambiguous target cabal's candidate list can't be parsed signals an error."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _)
               (insert "Error: [Cabal-7132]\nAmbiguous target 'app/Main.hs'.\n")
               1)))
    (should-error (haskell-ts--cabal-file-target "/proj/" "app/Main.hs")
                  :type 'user-error)))

;;; Cabal component enumeration (for the prefix-argument override)

(defconst haskell-ts-test--cabal-file
  "cabal-version:      3.0
name:               mypkg
version:            0.1.0.0

common warnings
    ghc-options: -Wall

library
    import:           warnings
    exposed-modules:  MyLib
    build-depends:    base
    hs-source-dirs:   src

library internal
    exposed-modules:  Internal
    hs-source-dirs:   internal

executable myapp
    main-is:          Main.hs
    hs-source-dirs:   app

test-suite mypkg-test
    type:             exitcode-stdio-1.0
    main-is:          Spec.hs

benchmark bench1
    type:             exitcode-stdio-1.0
    main-is:          Bench.hs
"
  "A synthetic multi-component `.cabal' file for target parsing.")

(ert-deftest haskell-ts-test-cabal-component-targets ()
  "Every stanza kind parses to a qualified target, in file order.
The main library takes the package name; `common' stanzas and
indented fields are ignored."
  (should (equal (haskell-ts--cabal-component-targets
                  "mypkg" haskell-ts-test--cabal-file)
                 '("lib:mypkg" "lib:internal" "exe:myapp"
                   "test:mypkg-test" "bench:bench1"))))

(ert-deftest haskell-ts-test-cabal-component-targets-ignores-indented ()
  "Indented lines that look like stanza headers (e.g. fields) are ignored."
  (should-not (haskell-ts--cabal-component-targets
               "p" "  executable indented\n    library nope\n")))

(ert-deftest haskell-ts-test-cabal-component-targets-skips-nameless ()
  "A named stanza kind without a name is skipped, not turned into a bare `exe:'."
  (should (equal (haskell-ts--cabal-component-targets "p" "executable\nlibrary\n")
                 '("lib:p"))))

(ert-deftest haskell-ts-test-cabal-components-reads-files ()
  "Components are gathered from the `.cabal' files directly in ROOT."
  (let ((root (make-temp-file "haskell-ts-test-comp" t)))
    (unwind-protect
        (progn
          (write-region "executable myapp\n  main-is: Main.hs\n" nil
                        (expand-file-name "mypkg.cabal" root))
          (should (equal (haskell-ts--cabal-components root)
                         '("exe:myapp"))))
      (delete-directory root t))))

(ert-deftest haskell-ts-test-cabal-components-none ()
  "A directory with no `.cabal' file yields no components."
  (let ((root (make-temp-file "haskell-ts-test-nocomp" t)))
    (unwind-protect
        (should-not (haskell-ts--cabal-components root))
      (delete-directory root t))))

(ert-deftest haskell-ts-test-read-cabal-component-offers-candidates ()
  "The override reader offers the project's components without requiring a match."
  (let (collection require-match)
    (cl-letf (((symbol-function 'haskell-ts--cabal-components)
               (lambda (_root) '("lib:p" "exe:myapp")))
              ((symbol-function 'completing-read)
               (lambda (_p c &optional _pred rm &rest _)
                 (setq collection c require-match rm)
                 "exe:myapp")))
      (should (equal (haskell-ts--read-cabal-component "/proj/" "/proj/app/Main.hs")
                     "exe:myapp")))
    (should (equal collection '("lib:p" "exe:myapp")))
    (should-not require-match)))

;;; Remembered component and prefix-argument override

(ert-deftest haskell-ts-test-cabal-target-caches-ambiguous-choice ()
  "A chosen component is remembered, so a restart does not reprobe cabal."
  (with-temp-buffer
    (let ((probes 0))
      (cl-letf (((symbol-function 'haskell-ts--cabal-file-target)
                 (lambda (_root _rel) (cl-incf probes) "exe2")))
        ;; First resolution probes cabal and remembers the chosen component.
        (should (equal (haskell-ts--cabal-target "/proj/" "/proj/app/Main.hs" nil)
                       "exe2"))
        (should (equal haskell-ts--cabal-component "exe2"))
        (should (= probes 1))
        ;; A restart reuses the remembered component without probing again.
        (should (equal (haskell-ts--cabal-target "/proj/" "/proj/app/Main.hs" nil)
                       "exe2"))
        (should (= probes 1))))))

(ert-deftest haskell-ts-test-cabal-target-single-component-not-cached ()
  "An unambiguous file (target = the file itself) is not remembered."
  (with-temp-buffer
    (cl-letf (((symbol-function 'haskell-ts--cabal-file-target)
               (lambda (_root rel) rel)))
      (should (equal (haskell-ts--cabal-target "/proj/" "/proj/app/Main.hs" nil)
                     "app/Main.hs"))
      (should-not haskell-ts--cabal-component))))

(ert-deftest haskell-ts-test-cabal-target-prefix-override ()
  "A prefix override prompts, uses the chosen component, and remembers it.
It also short-circuits the dry-run probe entirely."
  (with-temp-buffer
    (let ((probes 0) prompted)
      (cl-letf (((symbol-function 'haskell-ts--read-cabal-component)
                 (lambda (_root _file) (setq prompted t) "test:spec"))
                ((symbol-function 'haskell-ts--cabal-file-target)
                 (lambda (&rest _) (cl-incf probes) "app/Main.hs")))
        (should (equal (haskell-ts--cabal-target "/proj/" "/proj/app/Main.hs" t)
                       "test:spec"))
        (should prompted)
        (should (equal haskell-ts--cabal-component "test:spec"))
        (should (= probes 0))
        ;; It persists to the next, non-prefix restart.
        (should (equal (haskell-ts--cabal-target "/proj/" "/proj/app/Main.hs" nil)
                       "test:spec"))
        (should (= probes 0))))))

(ert-deftest haskell-ts-test-cabal-target-prefix-empty-clears ()
  "An empty override entry drops any remembered choice and re-resolves."
  (with-temp-buffer
    (setq haskell-ts--cabal-component "exe1")
    (cl-letf (((symbol-function 'haskell-ts--read-cabal-component)
               (lambda (&rest _) ""))
              ((symbol-function 'haskell-ts--cabal-file-target)
               (lambda (_root rel) rel)))
      (should (equal (haskell-ts--cabal-target "/proj/" "/proj/app/Main.hs" t)
                     "app/Main.hs"))
      (should-not haskell-ts--cabal-component))))

(ert-deftest haskell-ts-test-repl-command-prefix-picks-component ()
  "A prefix argument makes cabal open the chosen component as its target."
  (with-temp-buffer
    (cl-letf (((symbol-function 'executable-find)
               (lambda (&rest _) "/usr/bin/cabal"))
              ((symbol-function 'haskell-ts--read-cabal-component)
               (lambda (&rest _) "bench:bench1")))
      (let ((haskell-ts-use-cabal 'auto)
            (haskell-ts-cabal "cabal")
            (haskell-ts-cabal-switches '("repl")))
        (should (equal (haskell-ts--repl-command "/proj/" "/proj/app/Main.hs" t)
                       '("cabal" "repl" "bench:bench1")))))))

(ert-deftest haskell-ts-test-run-accepts-prefix-arg ()
  "`haskell-ts-run' reads a prefix argument for the component override."
  (should (equal (interactive-form 'haskell-ts-run) '(interactive "P"))))

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

(defun haskell-ts-tests--gen-segment-lists ()
  "Return a handful of non-touching ascending segment lists.
Fixed rather than randomly generated, to stay deterministic; sized 2,
3 and 5 segments to exercise the >2-segment case the single hand-built
fixture above never reaches."
  '(((2 . 5) (10 . 14))
    ((1 . 3) (7 . 10) (15 . 19))
    ((2 . 4) (8 . 11) (15 . 17) (22 . 26) (33 . 38))))

(ert-deftest haskell-ts-test-virtual-mapping-roundtrip-property ()
  "Multi-segment lists round-trip, stay ordered, and clamp gaps forward.
For every real point inside a segment, `haskell-ts--real-to-virtual'
followed by `haskell-ts--virtual-to-real' returns the original point
unflagged, and virtual points strictly increase with their real
counterparts.  For every real point strictly between two segments (a
stripped marker), `haskell-ts--real-to-virtual' flags it and clamps it
to the next segment's virtual start, which maps back to that
segment's real start."
  (dolist (segments (haskell-ts-tests--gen-segment-lists))
    (with-temp-buffer
      (insert (make-string 200 ?x))
      (let* ((table (cdr (haskell-ts--virtual-text-and-table segments)))
             (pairs (cl-mapcar #'list segments table))
             prev-vpoint)
        (dolist (seg segments)
          (cl-loop for p from (car seg) to (cdr seg) do
                   (let ((loc (haskell-ts--real-to-virtual p table)))
                     (should-not (cdr loc))
                     (should (= p (haskell-ts--virtual-to-real (car loc) table)))
                     (when prev-vpoint
                       (should (> (car loc) prev-vpoint)))
                     (setq prev-vpoint (car loc)))))
        (cl-loop for (pair next-pair) on pairs
                 while next-pair do
                 (let* ((seg (car pair))
                        (next-seg (car next-pair))
                        (next-vstart (nth 2 (cadr next-pair))))
                   (cl-loop for p from (1+ (cdr seg)) to (1- (car next-seg)) do
                            (let ((loc (haskell-ts--real-to-virtual p table)))
                              (should (cdr loc))
                              (should (= next-vstart (car loc)))
                              (should (= (car next-seg)
                                         (haskell-ts--virtual-to-real (car loc) table)))))))))))

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

(ert-deftest haskell-ts-test-font-lock-extra-keywords ()
  "`forall', `pattern', deriving-strategy and fixity/do keywords
are fontified as keywords."
  (haskell-ts-tests--with-temp-hs
      "f :: forall a. a -> a
f x = x

pattern Foo <- Bar

newtype N = N Int
  deriving stock Eq
  deriving anyclass Show
  deriving (Ord) via Int

infixl 6 +++

g = mdo
  rec y <- pure y
  pure y
"
    (treesit-font-lock-fontify-region (point-min) (point-max))
    (dolist (kw '("forall" "pattern" "stock" "anyclass" "via"
                  "infixl" "mdo" "rec"))
      (goto-char (point-min))
      (search-forward kw)
      (should (eq 'font-lock-keyword-face
                  (get-text-property (match-beginning 0) 'face))))))

(ert-deftest haskell-ts-test-font-lock-do-bind-arrow ()
  "The `<-' of a do-notation bind is fontified like the list
comprehension generator's, since the two tokens are syntactically
identical."
  (haskell-ts-tests--with-temp-hs
      "main = do
  x <- action
  pure x
"
    (treesit-font-lock-fontify-region (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "<-")
    (should (eq 'font-lock-doc-face
                (get-text-property (match-beginning 0) 'face)))))

(ert-deftest haskell-ts-test-font-lock-binds-only-bound-vars ()
  "A bound parameter gets `variable-name-face'; a free variable does not."
  (haskell-ts-tests--with-temp-hs "f x = x + y\n"
    (treesit-font-lock-fontify-region (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "x")                 ; the bound parameter in `f x'
    (should (eq 'font-lock-variable-name-face
                (get-text-property (match-beginning 0) 'face)))
    (search-forward "y")                 ; free variable -- not a bound var
    (should-not (eq 'font-lock-variable-name-face
                    (get-text-property (match-beginning 0) 'face)))))

(ert-deftest haskell-ts-test-font-lock-constructor-face ()
  "A data constructor gets `haskell-ts-constructor-face'."
  (haskell-ts-tests--with-temp-hs "data Color = Red | Green | Blue\n"
    (treesit-font-lock-fontify-region (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "Red")
    (should (eq 'haskell-ts-constructor-face
                (get-text-property (match-beginning 0) 'face)))))

(ert-deftest haskell-ts-test-font-lock-string-face ()
  "A string literal gets `font-lock-string-face'."
  (haskell-ts-tests--with-temp-hs
      "greeting :: String -> String
greeting name = \"Hello, \" ++ name
"
    (treesit-font-lock-fontify-region (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "\"Hello, \"")
    (should (eq 'font-lock-string-face
                (get-text-property (match-beginning 0) 'face)))))

(ert-deftest haskell-ts-test-font-lock-function-name-face ()
  "A function's defining occurrence gets `font-lock-function-name-face'."
  (haskell-ts-tests--with-temp-hs
      "greeting :: String -> String
greeting name = \"Hello, \" ++ name
"
    (treesit-font-lock-fontify-region (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "greeting")          ; the signature's name
    (search-forward "greeting")          ; the defining occurrence
    (should (eq 'font-lock-function-name-face
                (get-text-property (match-beginning 0) 'face)))))

(ert-deftest haskell-ts-test-font-lock-type-curried-return ()
  "In a curried signature, only the final return type is a bound
type variable (`font-lock-variable-name-face'); parameter types keep
plain `font-lock-type-face'.  Guards `haskell-ts--fontify-type''s
recursion into the curried return type."
  (haskell-ts-tests--with-temp-hs "f :: Int -> Int -> Bool\n"
    (treesit-font-lock-fontify-region (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "Int")
    (should (eq 'font-lock-type-face
                (get-text-property (match-beginning 0) 'face)))
    (search-forward "Int")
    (should (eq 'font-lock-type-face
                (get-text-property (match-beginning 0) 'face)))
    (search-forward "Bool")
    (should (eq 'font-lock-variable-name-face
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

(ert-deftest haskell-ts-test-imenu-type-data ()
  "Imenu names a `TypeData'-extension `type data' declaration by its
type name, not its leading `data' keyword.
Regression test: the name extractor used to assume exactly one
leading keyword before the name, so the extra `type' keyword of `type
data Foo = ...' shifted it onto `data' instead of `Foo'."
  (haskell-ts-tests--with-temp-hs "type data Foo = MkFoo\n"
    (let* ((index (funcall imenu-create-index-function))
           (names (mapcar #'car (cl-remove-if (lambda (e) (consp (cdr e))) index))))
      (should (member "Foo" names))
      (should-not (member "data" names)))))

(ert-deftest haskell-ts-test-imenu-data-family-instance ()
  "Imenu lists `data instance'/`newtype instance' family instances,
named after the family, rather than omitting them.
Regression test: these declarations parse as a `data_type'/`newtype'
node wrapped in an outer `data_instance' node, so the old top-level
check (which required the node's direct parent to be `declarations')
silently dropped them from imenu."
  (haskell-ts-tests--with-temp-hs
      "data instance Foo Int = Bar Int\nnewtype instance Baz Int = Qux Int\n"
    (let* ((index (funcall imenu-create-index-function))
           (names (mapcar #'car (cl-remove-if (lambda (e) (consp (cdr e))) index))))
      (should (member "Foo" names))
      (should (member "Baz" names)))))

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
      (should-not (string-match-p "module Main" sent))
      (should (string-match-p ":{" sent))
      (should (string-match-p ":}" sent)))))

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
    ;; From the end of the last binding, step back over just it too, not
    ;; all the way to `point-min' (see `haskell-ts-test-sexp-backward-stall'
    ;; for the exact-boundary regression this used to stall on instead).
    (goto-char (point-min))
    (search-forward "z = 3")
    (let ((end (point)))
      (backward-sexp)
      (should (equal "z = 3"
                     (buffer-substring-no-properties (point) end))))))

(ert-deftest haskell-ts-test-sexp-backward-stall ()
  "`backward-sexp' from the exact end of the last top-level binding steps
back to its start instead of not moving at all.
Regression test: at that exact position, `treesit-node-at' resolves to
the enclosing `declarations' node rather than to the binding (the
binding's own end coincides with point, and nothing follows it for
`treesit-node-at' to fall forward to instead -- see
`haskell-ts--sexp-at-end'), and `treesit-thing-prev' cannot step
backward from `declarations' at all, so `backward-sexp' silently did
not move (better than the pre-`haskell-ts-test-sexp-backward-top-level'
behaviour of jumping all the way to `point-min', but still wrong)."
  (haskell-ts-tests--with-temp-hs "x = 1\ny = 2\nz = 3\n"
    (goto-char (point-min))
    (search-forward "z = 3")
    (let ((end (point)))
      (backward-sexp)
      (should (equal "z = 3" (buffer-substring-no-properties (point) end))))))

(ert-deftest haskell-ts-test-sexp-backward-stall-single-binding ()
  "The exact-end stall fix also covers a buffer with only one binding,
where the enclosing `declarations' node has no earlier sibling at all."
  (haskell-ts-tests--with-temp-hs "x = 1\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((end (point)))
      (backward-sexp)
      (should (equal "x = 1" (buffer-substring-no-properties (point) end))))))

(ert-deftest haskell-ts-test-sexp-backward-stall-local-binds ()
  "The same exact-end stall, one level down in a `where' block's last
local binding, also steps back to that binding's start rather than
stalling -- or, before this fix, swallowing the whole enclosing
top-level binding (see NOTES.org: local `local_binds' wrapper and the
enclosing binding both happen to end at the same position here, since
the block is the last thing in each)."
  (haskell-ts-tests--with-temp-hs "f = a\n  where a = 1\n        b = 2\n"
    (goto-char (point-min))
    (search-forward "b = 2")
    (let ((end (point)))
      (backward-sexp)
      (should (equal "b = 2" (buffer-substring-no-properties (point) end))))))

(ert-deftest haskell-ts-test-sexp-backward-local-binds-not-last-binding ()
  "`backward-sexp' from a `where' block's last local binding steps back
to just that binding, even when the enclosing top-level binding is
*not* the file's last one.
Regression test: unlike `haskell-ts-test-sexp-backward-stall-local-binds'
(where the enclosing binding and the `where' block coincide at
`point-max', so `treesit-forward-sexp' stalled), more code following
means `treesit-node-at' resolves fine and `treesit-forward-sexp' does
move -- just to the wrong place, swallowing the whole enclosing
binding's `where' keyword, header and every local binding, since
`treesit-thing-prev' climbs past the excluded `local_binds' wrapper to
the enclosing binding, which also ends at the same position (see
`haskell-ts--sexp-at-end')."
  (haskell-ts-tests--with-temp-hs
      "f = a\n  where a = 1\n        b = 2\ng = 3\n"
    (goto-char (point-min))
    (search-forward "b = 2")
    (let ((end (point)))
      (backward-sexp)
      (should (equal "b = 2" (buffer-substring-no-properties (point) end))))
    ;; Stepping back again reaches the sibling local binding, not
    ;; `point-min'.
    (backward-sexp)
    (should (equal "a = 1"
                   (buffer-substring-no-properties (point) (+ (point) 5))))))

(ert-deftest haskell-ts-test-sexp-backward-let-binds-not-last-binding ()
  "The same fix applies to a `let' block inside a `do' block, not just
`where'."
  (haskell-ts-tests--with-temp-hs
      "main = do\n  let x = 1\n      y = 2\n  print x\nz = 3\n"
    (goto-char (point-min))
    (search-forward "y = 2")
    (let ((end (point)))
      (backward-sexp)
      (should (equal "y = 2" (buffer-substring-no-properties (point) end))))))

(ert-deftest haskell-ts-test-sexp-backward-nested-where-not-last-binding ()
  "The fix also applies one level further down, in a `where' block
nested inside another `where' block's binding, with more top-level
code following the whole thing."
  (haskell-ts-tests--with-temp-hs
      "f = a\n  where\n    a = b\n      where\n        b = 1\n        c = 2\ng = 3\n"
    (goto-char (point-min))
    (search-forward "c = 2")
    (let ((end (point)))
      (backward-sexp)
      (should (equal "c = 2" (buffer-substring-no-properties (point) end))))))

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

(ert-deftest haskell-ts-test-sexp-local-binds-block-layout ()
  "Excluding `local_binds' from `haskell-ts-sexp' fixes the coarse jump
that the inline-layout exclusion of `declarations' alone did not.
Regression test: when a `where'/`let' block's own bindings start on a
new line (nothing after the keyword on its line, then each binding
indented below), `local_binds' starts exactly where its first binding
does -- the same column-0 alignment that made `declarations' get
picked as the coarse sexp at the top level.  Before excluding
`local_binds' too, `forward-sexp' from the first binding took the
whole block in one step instead of one binding at a time."
  ;; `where' block, keyword alone on its line.
  (haskell-ts-tests--with-temp-hs "f = a + b\n  where\n    a = 1\n    b = 2\n"
    (goto-char (point-min))
    (search-forward "where")
    (skip-chars-forward "\n ")
    (let ((start (point)))
      (forward-sexp)
      (should (equal "a = 1"
                     (buffer-substring-no-properties start (point)))))
    (forward-sexp)
    (should (string-suffix-p "b = 2"
                             (buffer-substring-no-properties (point-min) (point)))))
  ;; `let' block inside a `do', keyword alone on its line.
  (haskell-ts-tests--with-temp-hs
      "main = do\n  let\n    x = 1\n    y = 2\n  print x\n"
    (goto-char (point-min))
    (search-forward "let")
    (skip-chars-forward "\n ")
    (let ((start (point)))
      (forward-sexp)
      (should (equal "x = 1"
                     (buffer-substring-no-properties start (point)))))
    (forward-sexp)
    (should (string-suffix-p "y = 2"
                             (buffer-substring-no-properties (point-min) (point)))))
  ;; A `where' block nested inside another `where' block's binding.
  (haskell-ts-tests--with-temp-hs
      "f = a\n  where\n    a = b\n      where\n        b = 1\n        c = 2\n"
    (goto-char (point-min))
    (search-forward "where" nil nil 2)
    (skip-chars-forward "\n ")
    (let ((start (point)))
      (forward-sexp)
      (should (equal "b = 1"
                     (buffer-substring-no-properties start (point)))))
    (forward-sexp)
    (should (string-suffix-p "c = 2"
                             (buffer-substring-no-properties (point-min) (point))))))

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
    (should (equal "Second." (haskell-ts-tests--sentence-at-point)))
    (search-forward "Third")
    (should (equal "Third." (haskell-ts-tests--sentence-at-point)))))

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

(ert-deftest haskell-ts-test-sentence-code-ignores-inline-comment ()
  "An inline trailing `-- note' is part of its code line, not a paragraph
edge, so sentence motion runs through it into the next equation instead
of stopping at the comment.
Regression test: `haskell-ts--adjacent-comment-edge' restricts its
own-line check to `(bolp)' so an inline comment does not count as a
glued comment boundary; dropping that guard clamps motion to just
before the `--' instead of the next equation's end."
  (haskell-ts-tests--with-temp-hs
      "f = x  -- note\ng = y\n"
    (goto-char (point-min))
    (let ((second-line-end (save-excursion (forward-line 1) (line-end-position))))
      (forward-sentence 2)
      (should (= (point) second-line-end)))))

;;; `kill-sentence'/`backward-kill-sentence' marker awareness

(ert-deftest haskell-ts-test-kill-sentence-preserves-continuation-marker ()
  "`kill-sentence' on a sentence that wraps onto a comment continuation
line never removes that line's own marker along with it.
Regression test for TODO.org's marker-aware sentence deletion: the
sentence's end, mapped back from the dedented copy
`haskell-ts--forward-sentence' runs prose motion on, lands past the
continuation line's own repeated marker, so the raw buffer text
between the sentence's start and that point includes it; deleting
that raw text used to take the marker along with it, silently merging
the two comment lines into one."
  (haskell-ts-tests--with-temp-hs
      "-- Hello world\n-- again. Next sentence.\n"
    (search-forward "Hello")
    (goto-char (match-beginning 0))
    (kill-sentence)
    (should (equal (buffer-string) "-- \n--  Next sentence.\n"))
    (should (equal (substring-no-properties (current-kill 0))
                   "Hello world\nagain."))))

(ert-deftest haskell-ts-test-kill-sentence-preserves-every-continuation-marker ()
  "`kill-sentence' preserves every continuation marker a sentence spans,
not just the first one, when the sentence runs across more than one."
  (haskell-ts-tests--with-temp-hs
      "-- Foo\n-- bar\n-- baz. Qux.\n"
    (search-forward "Foo")
    (goto-char (match-beginning 0))
    (kill-sentence)
    (should (equal (buffer-string) "-- \n-- \n--  Qux.\n"))
    (should (equal (substring-no-properties (current-kill 0))
                   "Foo\nbar\nbaz."))))

(ert-deftest haskell-ts-test-backward-kill-sentence-preserves-continuation-marker ()
  "`backward-kill-sentence' is marker-aware the same way `kill-sentence' is."
  (haskell-ts-tests--with-temp-hs
      "-- Hello world\n-- again. Next sentence.\n"
    (search-forward "again.")
    (backward-kill-sentence)
    (should (equal (buffer-string) "-- \n--  Next sentence.\n"))))

(ert-deftest haskell-ts-test-kill-sentence-same-line-unaffected ()
  "A sentence that stays on one line kills exactly as before -- the
marker-aware path only ever engages when a continuation marker
actually sits between the sentence's start and end."
  (haskell-ts-tests--with-temp-hs
      "-- Hello. World.\n"
    (search-forward "Hello")
    (goto-char (match-beginning 0))
    (kill-sentence)
    (should (equal (buffer-string) "--  World.\n"))))

(ert-deftest haskell-ts-test-kill-region-manual-not-marker-aware ()
  "A manual `kill-region' spanning a continuation marker is unaffected.
Only `kill-sentence'/`backward-kill-sentence' (and, for `evil',
`d a s'/`d i s'/`c a s'/`c i s') bind
`haskell-ts--sentence-deletion-active'; marker-awareness is deliberately
scoped to sentence deletion, not every possible `kill-region' call, so
e.g. a manual mark-and-`C-w' spanning the same text still removes the
marker along with it exactly as it always did."
  (haskell-ts-tests--with-temp-hs
      "-- Hello world\n-- again. Next sentence.\n"
    (search-forward "Hello")
    (let ((start (match-beginning 0)))
      (search-forward "again.")
      (kill-region start (point)))
    (should (equal (buffer-string) "--  Next sentence.\n"))))

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

;;; Mode-wiring: activation/derivation/motion facts nothing else exercises

(ert-deftest haskell-ts-test-prettify-installed-when-enabled ()
  "The mode appends only the enabled prettify alist, buffer-locally."
  (let ((haskell-ts-prettify-symbols t)
        (haskell-ts-prettify-words nil))
    (haskell-ts-tests--with-temp-hs "x = 1\n"
      (should (local-variable-p 'prettify-symbols-alist))
      (should (assoc "->" prettify-symbols-alist))
      (should-not (assoc "forall" prettify-symbols-alist))))
  (let ((haskell-ts-prettify-symbols nil)
        (haskell-ts-prettify-words t))
    (haskell-ts-tests--with-temp-hs "x = 1\n"
      (should-not (assoc "->" prettify-symbols-alist))
      (should (assoc "forall" prettify-symbols-alist)))))

(ert-deftest haskell-ts-test-derived-from-haskell-mode ()
  "On Emacs 30+, `haskell-ts-mode' is recognised as a `haskell-mode' derivative.
Matters for third-party config keyed on `haskell-mode'."
  (skip-unless (fboundp 'provided-mode-derived-p))
  (haskell-ts-tests--with-temp-hs "x = 1\n"
    (should (provided-mode-derived-p 'haskell-ts-mode 'haskell-mode))))

(ert-deftest haskell-ts-test-beginning-end-of-defun-motion ()
  "`C-M-a'/`C-M-e' land on the enclosing binding's bounds, not just
`treesit-defun-at-point''s idea of them."
  (haskell-ts-tests--with-temp-hs
      haskell-ts-tests--sample
    (search-forward "\"Hello, \"")
    (beginning-of-defun)
    (should (looking-at-p "greeting name = "))
    (end-of-defun)
    (should (looking-at-p "\ndata Color"))))

(ert-deftest haskell-ts-test-electric-pair-pairs-installed ()
  "The mode sets its own buffer-local `electric-pair-pairs'."
  (haskell-ts-tests--with-temp-hs "x = 1\n"
    (should (local-variable-p 'electric-pair-pairs))
    (should (equal electric-pair-pairs
                   '((?` . ?`) (?\( . ?\)) (?{ . ?}) (?\" . ?\") (?\[ . ?\]))))))

(ert-deftest haskell-ts-test-comment-syntax-variables ()
  "`comment-start'/`comment-start-skip' match a `--' line comment."
  (haskell-ts-tests--with-temp-hs "x = 1\n"
    (should (equal comment-start "-- "))
    (should (string-match-p comment-start-skip "-- foo"))
    (should (string-match-p comment-start-skip "--- foo"))))

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

(defun haskell-ts-tests--evil-delete-at (needle selector &optional thing)
  "Move to just after NEEDLE, delete what SELECTOR selects, return the buffer.
Like `haskell-ts-tests--evil-object-at', but actually performs the
deletion via `evil-delete' -- what `d a s'/`d i s' (or `c a s'/`c i s',
via `evil-change' calling `evil-delete') do with the range -- rather
than just returning the selected text, so it also exercises
`haskell-ts--evil-delete-marker-aware'."
  (goto-char (point-min))
  (search-forward needle)
  (let ((range (funcall selector (or thing 'evil-sentence) nil nil 'inclusive 1)))
    (evil-delete (evil-range-beginning range) (evil-range-end range) (evil-type range)))
  (buffer-string))

(ert-deftest haskell-ts-test-evil-delete-a-sentence-preserves-continuation-marker ()
  "`d a s' on a sentence that wraps onto a comment continuation line
never deletes that line's own marker along with it.
Regression test for TODO.org's marker-aware sentence deletion, the
`evil' counterpart of
`haskell-ts-test-kill-sentence-preserves-continuation-marker': the
sentence's end, once mapped back from the dedented copy prose motion
runs on, lands past the continuation line's own repeated marker, so
plain `evil-delete' -- which just removes the raw text between the
range's endpoints -- used to take the marker along with it, silently
merging the two comment lines into one."
  (haskell-ts-tests--with-temp-hs-evil
      "-- Hello world\n-- again. Next sentence.\n"
    (should (equal "-- \n-- Next sentence.\n"
                   (haskell-ts-tests--evil-delete-at "Hello" #'evil-select-an-object)))))

(ert-deftest haskell-ts-test-evil-delete-inner-sentence-preserves-continuation-marker ()
  "`d i s' is marker-aware the same way `d a s' is."
  (haskell-ts-tests--with-temp-hs-evil
      "-- Hello world\n-- again. Next sentence.\n"
    (should (equal "-- \n--  Next sentence.\n"
                   (haskell-ts-tests--evil-delete-at "Hello" #'evil-select-inner-object)))))

(ert-deftest haskell-ts-test-evil-delete-line-not-marker-aware ()
  "A linewise `evil-delete' (`dd'-style) still removes a straddled
marker along with the rest of the line -- `haskell-ts--evil-delete-marker-aware'
only binds `haskell-ts--sentence-deletion-active' for a charwise
\(`inclusive'/`exclusive') TYPE, since deleting whole lines is meant to
take their markers with them."
  (haskell-ts-tests--with-temp-hs-evil
      "-- Hello world\n-- again. Next sentence.\n"
    (goto-char (point-min))
    (evil-delete (point-min) (point-max) 'line)
    (should (equal (buffer-string) ""))))

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

;;; `evil-forward-paragraph'/`evil-backward-paragraph' (`}'/`{') confined
;;; to a glued comment, the same way `a p'/`i p' already are above.

(ert-deftest haskell-ts-test-evil-forward-paragraph-glued-to-code ()
  "`}' from inside a `--' comment glued to code on both sides stops
right after the comment, without swallowing \"g = y\" below it -- even
with point starting exactly at the comment's own end (right after
\"Comment\", before its trailing newline).
Regression test for TODO.org's `}'/`{' confinement item:
`evil-forward-end' nudges point one character past the comment's end
before delegating to `forward-paragraph'; starting already at that
end, the nudge lands one character past `treesit-node-end', outside
the comment node, before `haskell-ts--confine-paragraph-motion''s
per-call clamp -- which only fires while point is still inside the
node -- ever gets a chance to trigger."
  (haskell-ts-tests--with-temp-hs-evil
      "f = x\n-- Comment\ng = y\n"
    (search-forward "Comment")              ; point at the comment's own end
    (evil-forward-paragraph 1)
    (should (looking-at "g = y"))))

(ert-deftest haskell-ts-test-evil-backward-paragraph-glued-to-code ()
  "`{' from inside a `--' comment glued to code on both sides stops at
the comment's own start, without spilling back into \"f = x\" above it.
Regression test: `evil-backward-paragraph' nudges point forward a
whole line -- via its own leading `(forward-line)', before ever
calling `evil-backward-beginning' -- which reliably escapes the node
from any position inside it, so `{' used to fly all the way to
`point-min' regardless of where inside the comment it started."
  (haskell-ts-tests--with-temp-hs-evil
      "f = x\n-- Comment\ng = y\n"
    (search-forward "Comm")
    (evil-backward-paragraph 1)
    (should (looking-at "-- Comment"))
    (should (> (point) (point-min)))))

(ert-deftest haskell-ts-test-evil-forward-paragraph-glued-to-code-below-only ()
  "`}' from inside a Haddock comment preceded by a blank line but glued
directly to code below stops right after the comment, on that glued
side only."
  (haskell-ts-tests--with-temp-hs-evil
      "f = x\n\n-- | Sentence here.\ng = id\n"
    (search-forward "Sentence")
    (evil-forward-paragraph 1)
    (should (looking-at "g = id"))))

(ert-deftest haskell-ts-test-evil-backward-paragraph-glued-to-code-above-only ()
  "`{' from inside a Haddock comment glued directly to code above it,
but followed by a blank line, stops at the comment's own start rather
than spilling back into \"f = x\"."
  (haskell-ts-tests--with-temp-hs-evil
      "f = x\n-- | Sentence here.\n\ng = id\n"
    (search-forward "Sentence")
    (evil-backward-paragraph 1)
    (should (looking-at "-- | Sentence"))
    (should (> (point) (point-min)))))

(ert-deftest haskell-ts-test-evil-paragraph-motion-not-glued-unaffected ()
  "`}'/`{' on a comment separated from surrounding code by real blank
lines on both sides is unaffected by glued-comment confinement: it
behaves like plain paragraph motion, free to continue past the
comment onto the following blank line instead of stopping short at
the comment's own end."
  (haskell-ts-tests--with-temp-hs-evil
      "f = x\n\n-- Comment\n\ng = y\n"
    (search-forward "Comm")
    (evil-forward-paragraph 1)
    (should (= (char-after) ?\n))
    (should (looking-at "\ng = y"))))

(ert-deftest haskell-ts-test-evil-backward-paragraph-from-code-unaffected ()
  "`{' run from code, not from inside a comment, is unaffected by the
glued-comment confinement: `haskell-ts--confine-evil-paragraph-motion'
only narrows when point already sits inside a `text' node, so plain
code motion still reaches the nearest real paragraph break (the blank
line before the next comment) even with a comment glued to the code
below that break."
  (haskell-ts-tests--with-temp-hs-evil
      "-- | Hello\nf = id\n\n-- | Test.\ng = id\n"
    (search-forward "g = ")
    (evil-backward-paragraph 1)
    (should (= (char-after) ?\n))
    (should (save-excursion (forward-line 1) (looking-at "-- | Test.")))))

(ert-deftest haskell-ts-test-evil-paragraph-motion-glued-edge-no-error ()
  "`{' from the very first character of a comment glued to code above
it -- already at the node's own edge, with nothing left to confine to
within it -- falls back to plain, unconfined motion instead of
mistaking the node's edge for the real buffer boundary and signalling
`beginning-of-buffer'.
Regression test: narrowing the whole call to the node's bounds (the
same fix `haskell-ts--confine-evil-paragraph-object' applies to
`a p'/`i p') makes `evil-signal-at-bob-or-eob' -- run before any
motion -- see the narrowed edge as `bobp'/`eobp' when point already
sits there, raising a real error even though the actual buffer
continues further; falling back to an unnarrowed retry avoids it."
  (haskell-ts-tests--with-temp-hs-evil
      "f = x\n-- Comment\ng = y\n"
    (search-forward "-- ")
    (goto-char (match-beginning 0))         ; the comment's own first character
    (evil-backward-paragraph 1)
    (should (= (point) (point-min)))))

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
