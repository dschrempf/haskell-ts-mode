;;; haskell-ts-repl.el --- GHCi REPL integration for haskell-ts-mode -*- lexical-binding:t -*-

;; Copyright (C) 2024, 2025 Pranshu Sharma
;; Copyright (C) 2026 Dominik Schrempf

;; Author: Pranshu Sharma <pranshu@bauherren.ovh>
;;         Dominik Schrempf <dominik.schrempf@gmail.com>
;; Maintainer: Dominik Schrempf <dominik.schrempf@gmail.com>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `comint'-based GHCi integration for `haskell-ts-mode': starting the
;; inferior process (via plain `ghci' or `cabal repl'), sending code to
;; it, and loading the current file.  Required by `haskell-ts-mode.el'.

;;; Code:

(require 'comint)
(require 'treesit)
(require 'inheritenv)

(declare-function treesit-node-start "treesit.c")
(declare-function treesit-node-end "treesit.c")

(defcustom haskell-ts-ghci "ghci"
  "The name or path of the program used to run the GHCi REPL.
Any arguments to be passed should be added to
`haskell-ts-ghci-switches'."
  :type 'string
  :group 'haskell-ts)

(defcustom haskell-ts-ghci-switches nil
  "Arguments to be passed to `haskell-ts-ghci'."
  :type '(repeat string)
  :group 'haskell-ts)

(defcustom haskell-ts-cabal "cabal"
  "The name or path of the cabal program used to start the REPL.
Used instead of `haskell-ts-ghci' according to `haskell-ts-use-cabal'.
Any arguments should be added to `haskell-ts-cabal-switches'."
  :type 'string
  :group 'haskell-ts)

(defcustom haskell-ts-cabal-switches '("repl")
  "Arguments to be passed to `haskell-ts-cabal'.
The default starts an interactive session for the project's
default component.  Because `cabal repl' configures GHCi with the
component's dependencies, default language extensions and GHC
options, code loaded into such a session compiles as it would in
a build, unlike a plain `ghci' session."
  :type '(repeat string)
  :group 'haskell-ts)

(defcustom haskell-ts-use-cabal 'auto
  "Whether to start the REPL with `cabal repl' instead of `ghci'.
Starting via cabal makes the project's dependencies, default
language extensions and GHC options available in the session.
Possible values:
- `auto' (the default): use cabal when the current buffer is
  inside a cabal project (a `cabal.project' or `*.cabal' file is
  found by walking up the directory tree) and `haskell-ts-cabal'
  is on the variable `exec-path', otherwise fall back to
  `haskell-ts-ghci'.
- t: always use `haskell-ts-cabal'.
- nil: always use `haskell-ts-ghci'."
  :type '(choice (const :tag "Auto-detect cabal project" auto)
                 (const :tag "Always cabal repl" t)
                 (const :tag "Always plain ghci" nil))
  :group 'haskell-ts)

(defcustom haskell-ts-ghci-buffer-name "*Inferior Haskell*"
  "Buffer name for the ghci process."
  :type 'string
  :group 'haskell-ts)

(defcustom haskell-ts-inferior-prompt-regexp
  (rx line-start
      (or "ghci"                        ; modern GHCi default prompt
          ;; A popular custom prompt.  Redundant whenever
          ;; `case-fold-search' is non-nil (the default), since it then
          ;; already folds into the module-qualified `upper' branch
          ;; below; kept so the prompt still matches with case folding
          ;; off.
          "λ"
          ;; Module-qualified prompts such as `*Main> ' or
          ;; `Prelude Data.List> ', as produced by older GHCi and by
          ;; `cabal repl' loading named modules.
          (seq (? "*") upper (* (any alnum "_'."))
               (* (seq " " (? "*") upper (* (any alnum "_'."))))))
      ;; `> ' is the ordinary prompt, `| ' the multiline continuation.
      (any ">|") " ")
  "Regexp matching the GHCi prompt in the inferior Haskell buffer.
Used as `comint-prompt-regexp' in `haskell-ts-inferior-mode'."
  :type 'regexp
  :group 'haskell-ts)

(defcustom haskell-ts-inferior-history-file
  (locate-user-emacs-file "haskell-ts-inferior-history")
  "File where the inferior Haskell input history is saved.
Set to nil to disable history persistence across sessions."
  :type '(choice (file :tag "History file") (const :tag "Disable" nil))
  :group 'haskell-ts)

(defun haskell-ts--cabal-project-root ()
  "Return the cabal project root for the current buffer, or nil.
The root is the closest ancestor directory containing a
`cabal.project' file, or failing that one containing a `*.cabal'
file."
  (or (locate-dominating-file default-directory "cabal.project")
      (locate-dominating-file
       default-directory
       (lambda (dir)
         (ignore-errors (directory-files dir nil "\\.cabal\\'" t))))))

(defun haskell-ts--cabal-ambiguous-candidates (output)
  "Parse the component names listed in cabal's [Cabal-7132] OUTPUT.
OUTPUT is `cabal repl --dry-run's output for an \"Ambiguous
target\" failure, which lists one candidate per line, indented
and formatted as `component:path (file)'.  Return the component
names in the order cabal printed them, or nil if none could be
found there (e.g. because cabal's message format changed), so the
caller can fall back to relaying OUTPUT verbatim."
  (let (candidates)
    (dolist (line (split-string output "\n"))
      (when (string-match
             (rx line-start (+ space) (group (+ (not (any space ?:)))) ":")
             line)
        (push (match-string 1 line) candidates)))
    (nreverse candidates)))

(defun haskell-ts--choose-cabal-component (candidates target)
  "Prompt with `completing-read' for one of CANDIDATES.
CANDIDATES are the cabal components sharing TARGET, an ambiguous
file `haskell-ts--cabal-file-target' could not resolve on its own.
Return the chosen component name, to be used as the `cabal repl'
target in TARGET's place."
  (completing-read (format "Component for %s: " target) candidates nil t))

(defun haskell-ts--cabal-component-targets (pkg text)
  "Parse `cabal repl' component targets out of a `.cabal' file's TEXT.
PKG is the package name (the `.cabal' file's base name), used as the
main library's component name.  Return one qualified target string
per top-level stanza header, in file order:
  `lib:PKG'    for a bare `library' stanza (the main library),
  `lib:NAME'   for a named sub-library `library NAME',
  `exe:NAME'   for `executable NAME',
  `test:NAME'  for `test-suite NAME',
  `bench:NAME' for `benchmark NAME'.
Only column-zero stanza headers match, so indented fields (and
`common' stanzas, which are not valid repl targets) are ignored.  A
pure helper over TEXT, so it needs no filesystem access."
  (let ((case-fold-search t)
        targets)
    (dolist (line (split-string text "\n"))
      (when (string-match
             (rx line-start
                 (group (or "library" "executable" "test-suite" "benchmark"))
                 (? (+ (any " \t")) (group (+ (any alnum ?- ?_ ?.))))
                 (* (any " \t")) line-end)
             line)
        (let* ((kind (downcase (match-string 1 line)))
               (name (match-string 2 line))
               (target (cond
                        ((string= kind "library") (concat "lib:" (or name pkg)))
                        ;; A named stanza with no name is malformed; skip it.
                        ((null name) nil)
                        ((string= kind "executable") (concat "exe:" name))
                        ((string= kind "test-suite") (concat "test:" name))
                        ((string= kind "benchmark") (concat "bench:" name)))))
          (when target (push target targets)))))
    (nreverse targets)))

(defun haskell-ts--cabal-components (root)
  "Return the `cabal repl' component targets declared under ROOT.
Scans each `*.cabal' file directly in ROOT (not in subdirectories,
so a `cabal.project' aggregating packages in sibling directories is
not covered) with `haskell-ts--cabal-component-targets', in directory
order.  Return nil when no `.cabal' file or component is found, so the
caller can fall back to free-form input."
  (let ((dir (expand-file-name root))
        targets)
    (dolist (file (ignore-errors (directory-files dir t "\\.cabal\\'")))
      (setq targets
            (append targets
                    (haskell-ts--cabal-component-targets
                     (file-name-base file)
                     (with-temp-buffer
                       (insert-file-contents file)
                       (buffer-string))))))
    targets))

(defun haskell-ts--read-cabal-component (root file)
  "Read a `cabal repl' component target, offering ROOT's components.
FILE, when non-nil, only labels the prompt.  Candidates come from
`haskell-ts--cabal-components'; `require-match' is nil so any target
cabal accepts can be typed even when it is not listed (e.g. a
component of a package under a `cabal.project').  Return the entered
string, which may be empty to mean \"no override\"."
  (completing-read
   (if file
       (format "cabal repl component (for %s): "
               (file-relative-name file (expand-file-name root)))
     "cabal repl component: ")
   (haskell-ts--cabal-components root) nil nil))

(defun haskell-ts--cabal-file-target (root target)
  "Resolve TARGET against the cabal project, or decide what to do.
TARGET is a file name relative to ROOT, the cabal project root.
Run `cabal repl --dry-run TARGET' from ROOT (reusing
`haskell-ts-cabal-switches' so the probe mirrors the real
invocation) and return one of:
  TARGET      cabal resolves it to a single component, so it can be
              passed as the `cabal repl' target;
  nil         cabal resolves it to no component (an orphan file not
              listed in any `.cabal', or any other failure), so the
              caller should start a plain `cabal repl' instead;
  COMPONENT   TARGET is shared by several components (cabal's
              [Cabal-7132] \"Ambiguous target\"); the component
              chosen via `haskell-ts--choose-cabal-component' from
              cabal's own candidate list, to be used as the target
              instead of TARGET.
Signal a `user-error' if TARGET is ambiguous but cabal's candidate
list could not be parsed, relaying it verbatim."
  (let ((default-directory (expand-file-name root)))
    (with-temp-buffer
      (let ((status (apply #'call-process haskell-ts-cabal nil t nil
                           (append haskell-ts-cabal-switches
                                   (list "--dry-run" target)))))
        (if (eq status 0)
            target
          (let* ((output (buffer-string))
                 (ambiguous-p (string-match-p "Ambiguous target" output))
                 (candidates (and ambiguous-p
                                  (haskell-ts--cabal-ambiguous-candidates
                                   output))))
            (cond
             (candidates (haskell-ts--choose-cabal-component candidates target))
             (ambiguous-p
              (user-error
               (concat "haskell-ts: %s is shared by several cabal components, "
                       "but its candidate list could not be parsed.  "
                       "cabal reported:\n%s")
               target (string-trim output)))
             (t nil))))))))

(defvar-local haskell-ts--cabal-component nil
  "Cabal component remembered as this buffer's `cabal repl' target, or nil.
Set when an ambiguous file was resolved by prompting, or by the
prefix-argument override on `haskell-ts-run', so a later restart of
the REPL from this buffer reuses the choice instead of reprompting.")

(defun haskell-ts--cabal-target (root file choose)
  "Return the `cabal repl' target string for FILE in project ROOT, or nil.
When CHOOSE is non-nil, prompt for a component (the prefix-argument
override on `haskell-ts-run') and remember it in
`haskell-ts--cabal-component'; an empty entry clears the override and
falls through to automatic resolution.  Otherwise reuse a remembered
component if one is set, else resolve FILE with
`haskell-ts--cabal-file-target', remembering a component it had to
prompt the user for (the ambiguous case) so a later restart does not
reprompt."
  (when choose
    (let ((comp (haskell-ts--read-cabal-component root file)))
      (setq haskell-ts--cabal-component
            (unless (string-empty-p comp) comp))))
  (cond
   (haskell-ts--cabal-component)
   ((null file) nil)
   (t
    (let* ((rel (file-relative-name file (expand-file-name root)))
           (target (haskell-ts--cabal-file-target root rel)))
      ;; A resolved target that is not FILE itself is a component name
      ;; the user picked for an ambiguous file; remember it.
      (when (and target (not (equal target rel)))
        (setq haskell-ts--cabal-component target))
      target))))

(defun haskell-ts--repl-command (root file &optional choose)
  "Return a (program . arguments) cons for starting the REPL.
ROOT is the cabal project root as returned by
`haskell-ts--cabal-project-root', or nil.  FILE is the file visited
by the buffer from which the REPL is started, or nil.  Honour
`haskell-ts-use-cabal'.

When cabal is used and ROOT is non-nil, a `cabal repl' target is
appended so cabal opens the owning component (avoiding the Cabal-7076
error `cabal repl' raises with no target in a multi-component
project).  `haskell-ts--cabal-target' resolves it: a remembered
component (from a previous prompt, see `haskell-ts--cabal-component')
takes precedence; otherwise a FILE in one component is used as the
target, a FILE in no component is omitted so a plain `cabal repl'
starts, and a FILE shared by several components prompts (via
`haskell-ts--choose-cabal-component') for the one to use.  A non-nil
CHOOSE (the prefix argument to `haskell-ts-run') forces an interactive
component pick even for an unambiguous FILE."
  (if (and haskell-ts-use-cabal
           (or (eq haskell-ts-use-cabal t) root)
           (executable-find haskell-ts-cabal))
      (let ((target (and root (haskell-ts--cabal-target root file choose))))
        (append (cons haskell-ts-cabal haskell-ts-cabal-switches)
                (when target (list target))))
    (cons haskell-ts-ghci haskell-ts-ghci-switches)))

(defun haskell-ts-show-repl ()
  "Display the GHCi buffer, starting a session if necessary.
Focus stays in the current buffer.  Return the process."
  (unless (haskell-ts-haskell-session)
    (save-window-excursion (haskell-ts-run)))
  (display-buffer haskell-ts-ghci-buffer-name)
  (haskell-ts-haskell-session))

(defconst haskell-ts--close-block-re "^[ \t]*:}[ \t]*$"
  "Regexp matching a line that is (modulo whitespace) a bare `:}'.
Such a line cannot appear inside GHCi's `:{'/`:}' multiline block,
since GHCi has no way to escape it; see `haskell-ts--send-region'.")

(defun haskell-ts--send-region (start end)
  "Send the buffer text from START to END to the REPL.
Starts a session first with `haskell-ts-show-repl' if none is
running.  The text is wrapped in GHCi's `:{'/`:}' multiline block
delimiters, since it may span several lines (e.g. a `where' clause).
Signal a `user-error' if it contains a line that is exactly `:}',
which GHCi's multiline block has no way to escape."
  (let ((hs (haskell-ts-show-repl))
        (str (buffer-substring-no-properties start end)))
    (when (string-match-p haskell-ts--close-block-re str)
      (user-error "Region contains a line that is just `:}'; cannot send to GHCi"))
    (comint-send-string hs ":{\n")
    (comint-send-string hs str)
    (comint-send-string hs "\n:}\n")))

(defun haskell-ts-compile-region-and-go ()
  "Send the active region to the REPL, or reload the file if none is active."
  (interactive)
  (if (region-active-p)
      (haskell-ts--send-region (region-beginning) (region-end))
    (comint-send-string (haskell-ts-show-repl) ":r\n")))

(defun haskell-ts-send-line ()
  "Send the current line to the REPL, starting a session if necessary.
Unlike `haskell-ts-compile-region-and-go', the line is sent verbatim
without GHCi's `:{'/`:}' multiline wrapping, since a single line
needs none -- and so, unlike `haskell-ts--send-region', without the
guard against a bare `:}' line (a single such line is simply an error
at the GHCi prompt, not an inescapable multiline block)."
  (interactive)
  (let ((hs (haskell-ts-show-repl))
        (str (buffer-substring-no-properties
              (line-beginning-position) (line-end-position))))
    (comint-send-string hs (concat str "\n"))))

(defun haskell-ts-send-defun ()
  "Send the definition at point to the REPL.
The definition is found with `treesit-defun-at-point', the same
notion used by `treesit-defun-name-function' and imenu: the nearest
enclosing node whose parent is a `declarations' node, i.e. a
top-level binding or, from inside a `where'/`let' block, its nearest
local one.  Signal a `user-error' if point is not inside one."
  (interactive)
  (let ((node (treesit-defun-at-point)))
    (unless node
      (user-error "No definition at point"))
    (haskell-ts--send-region (treesit-node-start node) (treesit-node-end node))))

(defun haskell-ts-load-file ()
  "Load the file visited by the current buffer into the GHCi process.
Start a session with `haskell-ts-run' if none is running, save the
buffer first so GHCi reads the contents you see on disk, and
display the REPL without leaving the current buffer.

The file is loaded by its absolute path.  Relative `import's are
resolved by GHCi against its working directory, which `haskell-ts-run'
sets to the project root (see `haskell-ts--cabal-project-root'), so
sibling modules are normally found.  When the session was started
with `cabal repl' the project's dependencies and default language
extensions are in scope as well; see `haskell-ts-use-cabal'."
  (interactive)
  (unless buffer-file-name
    (user-error "Buffer is not visiting a file"))
  (save-buffer)
  ;; Capture the path before (possibly) starting GHCi, since
  ;; `haskell-ts-run' makes the inferior buffer current.
  (let* ((file buffer-file-name)
         (proc (haskell-ts-show-repl)))
    (comint-send-string proc (format ":load \"%s\"\n" file))))

(define-derived-mode haskell-ts-inferior-mode comint-mode "Inferior Haskell"
  "Major mode for the inferior Haskell (GHCi) process started by `haskell-ts-run'.

Derives from `comint-mode', so its key bindings are available:
\\<comint-mode-map>\\[comint-previous-input] and \\[comint-next-input] \
cycle the input history, \\[completion-at-point] completes file
names, and \\[comint-interrupt-subjob] interrupts GHCi.

The GHCi prompt is recognised via `haskell-ts-inferior-prompt-regexp'
and made read-only.  Input history persists across sessions in
`haskell-ts-inferior-history-file'."
  (setq-local comint-prompt-regexp haskell-ts-inferior-prompt-regexp)
  (setq-local comint-prompt-read-only t)
  (when haskell-ts-inferior-history-file
    (setq-local comint-input-ring-file-name haskell-ts-inferior-history-file)
    (comint-read-input-ring t)
    (add-hook 'kill-buffer-hook #'comint-write-input-ring nil t)))

;;;###autoload
(defun haskell-ts-run (&optional choose-component)
  "Run an inferior Haskell process.
The process is started in the current buffer's cabal project root
when one is found (so relative imports and the module search path
resolve from there), falling back to the buffer's directory
otherwise.  By default `cabal repl' is used inside a cabal project
and `ghci' elsewhere; see `haskell-ts-use-cabal'.

When starting via cabal, the current buffer's file is passed as the
`cabal repl' target so cabal opens the component that owns it (see
`haskell-ts--repl-command').  A `cabal repl' session is bound to
that one component for its lifetime: loading a file from a
different component into the same session (e.g. with
`haskell-ts-load-file') may fail because that component's modules
and dependencies are not in scope.  Restart the REPL from a buffer
in the desired component to switch.

With a prefix argument (CHOOSE-COMPONENT), prompt for the cabal
component to open even when the current file is not shared by several
components -- e.g. to deliberately open a different component's REPL.
The choice is remembered for later restarts from this buffer; so is a
component picked when resolving an ambiguous file, so neither
reprompts (see `haskell-ts--cabal-component').  Enter an empty
component to drop a remembered choice and return to automatic
resolution.

The REPL inherits the calling buffer's `process-environment' and
the variable `exec-path' via `inheritenv', so a toolchain configured
buffer-locally by envrc/direnv is honoured both when probing the
`cabal repl' target and when starting the inferior process.

The inferior buffer uses `haskell-ts-inferior-mode', which gives it
a recognised GHCi prompt, a read-only prompt, persistent input
history and the usual `comint-mode' bindings."
  (interactive "P")
  (inheritenv
   (let* ((buffer (get-buffer-create haskell-ts-ghci-buffer-name))
          ;; Capture the file before `make-comint-in-buffer' below makes
          ;; the inferior buffer current.
          (file buffer-file-name)
          (root (haskell-ts--cabal-project-root))
          (command (haskell-ts--repl-command root file choose-component))
          (program (car command))
          (switches (cdr command)))
     (unless (comint-check-proc buffer)
       (with-current-buffer buffer
         (when root
           (setq default-directory (expand-file-name root)))
         (apply 'make-comint-in-buffer "Haskell" buffer program nil switches)
         (haskell-ts-inferior-mode)))
     (pop-to-buffer-same-window buffer))))

(defun haskell-ts-haskell-session ()
  "Return the running REPL process, or nil if none is running."
  (get-buffer-process haskell-ts-ghci-buffer-name))

(provide 'haskell-ts-repl)

;;; haskell-ts-repl.el ends here
