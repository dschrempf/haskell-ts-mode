;;; haskell-ts-mode.el --- A treesit based major mode for haskell -*- lexical-binding:t -*-

;; Copyright (C) 2024, 2025 Pranshu Sharma
;; Copyright (C) 2026 Dominik Schrempf

;; Author: Pranshu Sharma <pranshu@bauherren.ovh>
;;         Dominik Schrempf <dominik.schrempf@gmail.com>
;; Maintainer: Dominik Schrempf <dominik.schrempf@gmail.com>
;; URL: https://codeberg.org/pranshu/haskell-ts-mode
;; Package-Requires: ((emacs "29.3") (inheritenv "0.1"))
;; Version: 1.4
;; Keywords: languages, Haskell

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

;; This is a major mode that uses treesitter to provide all the basic
;; major mode stuff, like indentation, font lock, etc...
;; It uses the grammar at: https://github.com/tek/tree-sitter-haskell

;;; Code:

(require 'comint)
(require 'treesit)
(require 'inheritenv)
(require 'haskell-ts-navigation)

(declare-function treesit-parser-create "treesit.c")
(declare-function treesit-node-start "treesit.c")
(declare-function treesit-node-parent "treesit.c")
(declare-function treesit-node-prev-sibling "treesit.c")
(declare-function treesit-node-next-sibling "treesit.c")
(declare-function treesit-node-end "treesit.c")
(declare-function treesit-node-child "treesit.c")
(declare-function treesit-node-type "treesit.c")

;; Loaded lazily by `align'; declared here so byte-compilation does not
;; warn about a free variable when we set it buffer-locally in the mode.
(defvar align-mode-rules-list)

(defgroup haskell-ts-mode nil
  "Group that contains haskell-ts-mode variables"
  :group 'langs)

(defcustom haskell-ts-ghci "ghci"
  "The name or path program to be called to run the ghci repl.  Any
arguments to be passed should be added `haskell-ts-ghci-switches`."
  :type 'string
  :group 'haskell-ts-mode)

(defcustom haskell-ts-ghci-switches nil
  "Arguments to be passed to `haskell-ts-ghci'."
  :type '(repeat string)
  :group 'haskell-ts-mode)

(defcustom haskell-ts-cabal "cabal"
  "The name or path of the cabal program used to start the REPL.
Used instead of `haskell-ts-ghci' according to `haskell-ts-use-cabal'.
Any arguments should be added to `haskell-ts-cabal-switches'."
  :type 'string
  :group 'haskell-ts-mode)

(defcustom haskell-ts-cabal-switches '("repl")
  "Arguments to be passed to `haskell-ts-cabal'.
The default starts an interactive session for the project's
default component.  Because `cabal repl' configures GHCi with the
component's dependencies, default language extensions and GHC
options, code loaded into such a session compiles as it would in
a build, unlike a plain `ghci' session."
  :type '(repeat string)
  :group 'haskell-ts-mode)

(defcustom haskell-ts-use-cabal 'auto
  "Whether to start the REPL with `cabal repl' instead of `ghci'.
Starting via cabal makes the project's dependencies, default
language extensions and GHC options available in the session.
Possible values:
- `auto' (the default): use cabal when the current buffer is
  inside a cabal project (a `cabal.project' or `*.cabal' file is
  found by walking up the directory tree) and `haskell-ts-cabal'
  is on `exec-path', otherwise fall back to `haskell-ts-ghci'.
- t: always use `haskell-ts-cabal'.
- nil: always use `haskell-ts-ghci'."
  :type '(choice (const :tag "Auto-detect cabal project" auto)
                 (const :tag "Always cabal repl" t)
                 (const :tag "Always plain ghci" nil))
  :group 'haskell-ts-mode)

(defcustom haskell-ts-ghci-buffer-name "*Inferior Haskell*"
  "Buffer name for the ghci process."
  :type 'string
  :group 'haskell-ts-mode)

(defcustom haskell-ts-inferior-prompt-regexp
  (rx line-start
      (or "ghci"                        ; modern GHCi default prompt
          "λ"                           ; a popular custom prompt
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
  :group 'haskell-ts-mode)

(defcustom haskell-ts-inferior-history-file
  (locate-user-emacs-file "haskell-ts-inferior-history")
  "File where the inferior Haskell input history is saved.
Set to nil to disable history persistence across sessions."
  :type '(choice (file :tag "History file") (const :tag "Disable" nil))
  :group 'haskell-ts-mode)

(defcustom haskell-ts-font-lock-level 4
  "Level of font lock, 1 for minimum highlighting and 4 for maximum."
  :type '(choice (const :tag "Minimal Highlighting" 1)
                 (const :tag "Low Highlighting" 2)
                 (const :tag "High Highlighting" 3)
                 (const :tag "Maximum Highlighting" 4))
  :group 'haskell-ts-mode)

(defcustom haskell-ts-prettify-symbols nil
  "Prettify some symbol combinations to unicode symbols.
This will concat `haskell-ts-prettify-symbols-alist' to
`prettify-symbols-alist' in `haskell-ts-mode'."
  :type 'boolean
  :group 'haskell-ts-mode)

(defcustom haskell-ts-prettify-words nil
  "Prettify some words to unicode symbols.
This will concat `haskell-ts-prettify-words-alist' to
`prettify-symbols-alist' in `haskell-ts-mode'."
  :type 'boolean
  :group 'haskell-ts-mode)

(defface haskell-constructor-face
  '((t :inherit font-lock-type-face))
  "Face used to highlight Haskell constructors."
  :group 'haskell-appearance)

(defvar haskell-ts-font-lock-feature-list
  `((comment str pragma parens)
    (type definition function args module import operator)
    (match keyword constructors)
    (otherwise signature type-sig)))

(defvar haskell-ts-prettify-symbols-alist
  '(("\\" . "λ")
    ("/=" . "≠")
    ("->" . "→")
    ("=>" . "⇒")
    ("<-" . "←")
    ("<=" . "≤")
    (">=" . "≥")
    ("/<" . "≮")
    ("/>" . "≯")
    ("==" . "≡"))
  "`prettify-symbols-alist' for `haskell-ts-mode'.
This variable contains all the symbol for `haskell-ts-mode' to unicode
character.  See `haskell-ts-prettify-words-alist' for mapping words to
alternative unicode character.")

(defvar haskell-ts-prettify-words-alist
  '(("forall"           . "∀")
    ("exists"           . "∃")
    ("elem"             . "∈")
    ("notElem"          . "∉")
    ("member"           . "∈")
    ("notMember"        . "∉")
    ("union"            . "∪")
    ("intersection"     . "∩")
    ("isSubsetOf"       . "⊆")
    ("isProperSubsetOf" . "⊂")
    ("mempty"           . "∅")
    ("&&" . "∧")
    ("||" . "∨"))
  "Additional symbols to prettify for `haskell-ts-mode'.
This is added to `prettify-symbols-alist' for `haskell-ts-mode' buffers
when `haskell-ts-prettify-words' is non-nil.")

(defvar haskell-ts-font-lock
  (treesit-font-lock-rules
   :language 'haskell
   :feature 'keyword
   `(["module" "import" "data" "let" "where" "case" "type" "family"
      "if" "then" "else" "of" "do" "in" "instance" "class" "newtype"]
     @font-lock-keyword-face)
   :language 'haskell
   :feature 'otherwise
   :override t
   `(((match (guards guard: (boolean (variable) @font-lock-keyword-face)))
      (:match "otherwise" @font-lock-keyword-face)))
   
   :language 'haskell
   :feature 'type
   :override t
   '((type) @font-lock-type-face)

   :language 'haskell
   :override t
   :feature 'signature
   '((signature (function) @haskell-ts--fontify-type)
     (context (function) @haskell-ts--fontify-type)
     (signature "::" @font-lock-operator-face))

   :language 'haskell
   :feature 'module
   '((module (module_id) @font-lock-type-face))

   :language 'haskell
   :feature 'import
   '((import ["qualified" "as" "hiding"] @font-lock-keyword-face))

   :language 'haskell
   :feature 'type-sig
   '((signature (binding_list (variable) @font-lock-doc-markup-face))
     (signature (variable) @font-lock-doc-markup-face))

   :language 'haskell
   :feature 'args
   :override 'keep
   '((function (infix left_operand: (_) @haskell-ts--fontify-arg))
     (function (infix right_operand: (_) @haskell-ts--fontify-arg))
     (generator :anchor (_) @haskell-ts--fontify-arg)
     (patterns) @haskell-ts--fontify-arg)

   :language 'haskell
   :feature 'constructors
   :override t
   '((constructor) @haskell-constructor-face
     (data_constructor
      (prefix field: (_) @haskell-ts--fontify-arg))
     (type_params (_) @font-lock-variable-name-face)
     (type_synonym (name) @font-lock-type-face)
     (data_type name: (name) @font-lock-type-face)
     (newtype name: (name) @font-lock-type-face)
     (deriving "deriving" @font-lock-keyword-face
               classes: (_) @haskell-constructor-face)
     (deriving_instance "deriving" @font-lock-keyword-face
                        name: (_) @haskell-constructor-face))

   :language 'haskell
   :feature 'match
   `((match ("|" @font-lock-doc-face) ("=" @font-lock-doc-face))
     (list_comprehension ("|" @font-lock-doc-face
                          (qualifiers (generator "<-" @font-lock-doc-face))))
     (match ("->" @font-lock-doc-face)))

   :language 'haskell
   :override t
   :feature 'comment
   `(((comment) @font-lock-comment-face)
     ((haddock) @font-lock-doc-face))

   :language 'haskell
   :feature 'pragma
   `((pragma) @font-lock-preprocessor-face
     (cpp) @font-lock-preprocessor-face)

   :language 'haskell
   :feature 'str
   :override t
   `((char) @font-lock-string-face
     (string) @font-lock-string-face
     (quasiquote (quoter) @font-lock-type-face)
     (quasiquote (quasiquote_body) @font-lock-preprocessor-face))

   :language 'haskell
   :feature 'parens
   :override t
   `(["(" ")" "[" "]"] @font-lock-bracket-face
     (infix operator: (_) @font-lock-operator-face))

   :language 'haskell
   :feature 'function
   :override t
   '((function name: (variable) @font-lock-function-name-face)
     (function (infix (operator)  @font-lock-function-name-face))
     (function (infix (infix_id (variable) @font-lock-function-name-face)))
     (bind :anchor (_) @haskell-ts--fontify-params)
     (function arrow: _ @font-lock-operator-face))

   :language 'haskell
   :feature 'operator
   :override t
   `((operator) @font-lock-operator-face
     ["=" "," "=>"] @font-lock-operator-face))
  "The treesitter font lock settings for haskell.")

(defvar haskell-ts--ignore-types
  (regexp-opt '("comment" "cpp" "haddock" ";"))
  "Node types that will be ignored when locating a defun's parent.")

(defvar haskell-ts-mode-syntax-table
  (eval-when-compile
    (let ((table (make-syntax-table))
          (syntax-list
           `((" " " \t\n\r\f\v")
             ("_" "!#$%&*+./<=>?\\^|-~:")
             ("w" ?_ ?\')
             ("." ",:@")
             ("\"" ?\")
             ("()" ?\()
             (")(" ?\))
             ("(]" ?\[)
             (")[" ?\])
             ("$`" ?\`)
             ("(}1nb" ?\{ )
             ("){4nb" ?\} )
             ("_ 123" ?- )
             (">" "\r\n\f\v"))))
      (dolist (ls syntax-list table)
        (dolist (char (if (stringp (cadr ls))
                          (string-to-list (cadr ls))
                        (cdr ls)))
          (modify-syntax-entry char (car ls) table)))))
  "The syntax table for haskell.")

(defvar haskell-ts-align-rules-list
  '((haskell-ts-assignment
     (regexp . "\\(\\s-+\\)=\\s-+")))
  "`align-mode-rules-list' for `haskell-ts-mode'.
Aligns the standalone `=' signs (binding and equation operators) in
a region under \\[align].  The trailing `\\s-+' makes the rule skip
`==', `=>', `<=', `>=' and `/=': only an `=' surrounded by
whitespace is matched.")

(defun haskell-ts--imenu-node-name (node)
  "Return the name imenu should display for declaration NODE.
For an operator definition (an `infix' first child, as in
`a <+> b = ...') this is the operator; otherwise it is the bound
name as given by `haskell-ts-defun-name'."
  (let ((nn (treesit-node-child node 0 t)))
    (if (string= (treesit-node-type nn) "infix")
        (treesit-node-text (treesit-node-child nn 1))
      (haskell-ts-defun-name node))))

(defvar-keymap  haskell-ts-mode-map
  :doc "Keymap for haskell-ts-mode."
  "C-c C-c" #'haskell-ts-compile-region-and-go
  "C-c C-l" #'haskell-ts-load-file
  "C-c C-r" #'haskell-ts-run)

;;;###autoload
(define-derived-mode haskell-ts-mode prog-mode "haskell ts mode"
  "Major mode for Haskell files using tree-sitter."
  :table haskell-ts-mode-syntax-table
  (unless (treesit-ready-p 'haskell)
    (error "Tree-sitter for Haskell is not available"))
  (setq treesit-primary-parser (treesit-parser-create 'haskell))
  (setq treesit-language-at-point-function
        (lambda (&rest _) 'haskell))
  ;; Comment
  (setq-local comment-start "-- ")
  (setq-local comment-use-syntax t)
  (setq-local comment-start-skip "\\(?: \\|^\\)--+\\s-*")
  ;; Haddock and plain comments end sentences with a single space, not
  ;; the double space `sentence-end' otherwise requires.
  (setq-local sentence-end-double-space nil)
  ;; A `--'-only line (whitespace and dashes, nothing else) is always a
  ;; marker-only comment line, never code -- `--' immediately followed by
  ;; end-of-line or whitespace can only start a comment, not an operator.
  ;; Counting it as blank lets `forward-paragraph'/`backward-paragraph'
  ;; (and callers like `evil''s `a p'/`i p') split paragraphs inside one
  ;; multi-line comment, where such a line is not a real blank line.
  (setq-local paragraph-start (concat paragraph-start "\\|[ \t]*--+[ \t]*$"))
  (setq-local paragraph-separate (concat paragraph-separate "\\|[ \t]*--+[ \t]*$"))
  ;; Electric
  (setq-local electric-pair-pairs
              '((?` . ?`) (?\( . ?\)) (?{ . ?}) (?\" . ?\") (?\[ . ?\])))
  ;; Align (M-x align aligns the `=' signs in a region)
  (setq-local align-mode-rules-list haskell-ts-align-rules-list)
  ;; Navigation
  (setq-local treesit-defun-name-function 'haskell-ts-defun-name)
  (setq-local treesit-thing-settings haskell-ts-thing-settings)
  (setq-local treesit-defun-type-regexp
              ;; Since haskell is strict functional, any 2nd level
              ;; entity is defintion
              (cons ".+"
                    (lambda (node)
                      (and (not (string-match haskell-ts--ignore-types (treesit-node-type node)))
                           (string= "declarations" (treesit-node-type (treesit-node-parent node)))))))
  (setq-local prettify-symbols-alist
              (append (and haskell-ts-prettify-symbols
                           haskell-ts-prettify-symbols-alist)
                      (and haskell-ts-prettify-words
                           haskell-ts-prettify-words-alist)))

  ;; Imenu
  (setq-local treesit-simple-imenu-settings
              `((nil "function\\|bind" haskell-ts-imenu-func-node-p
                     haskell-ts--imenu-node-name)
                ("Signatures.." "signature" haskell-ts-imenu-sig-node-p
                 haskell-ts--imenu-node-name)
                (nil "data_type\\|newtype" haskell-ts-imenu-data-type-p
                     (lambda (node)
                       (treesit-node-text (treesit-node-child node 1) t)))
                (nil "type_synonym" haskell-ts-imenu-typealias-type-p
                     (lambda (node)
                       (treesit-node-text (treesit-node-child node 1) t)))))
  ;; font-lock
  (setq-local treesit-font-lock-level haskell-ts-font-lock-level)
  (setq-local treesit-font-lock-settings haskell-ts-font-lock)
  (setq-local treesit-font-lock-feature-list
              haskell-ts-font-lock-feature-list)
  (treesit-major-mode-setup)
  (setq-local forward-sentence-function #'haskell-ts--forward-sentence))

(defun haskell-ts--fontify-func (node face)
  (if (string= "variable" (treesit-node-type node))
      (put-text-property
       (treesit-node-start node)
       (treesit-node-end node)
       'face face)
    (mapc (lambda (n) (haskell-ts--fontify-func n face))
          (treesit-node-children node))))

(defun haskell-ts--fontify-arg (node &optional _ _ _)
  (haskell-ts--fontify-func node 'font-lock-variable-name-face))

(defun haskell-ts--fontify-params (node &optional _ _ _)
  (haskell-ts--fontify-func node 'font-lock-function-name-face))

(defun haskell-ts--fontify-type (node &optional _ _ _)
  (let ((last-child (treesit-node-child node -1)))
    (if (string= (treesit-node-type last-child) "function")
        (haskell-ts--fontify-type last-child)
      (put-text-property
       (treesit-node-start last-child)
       (treesit-node-end last-child)
       'face 'font-lock-variable-name-face))))

(defun haskell-ts-imenu-node-p (regex node)
  (and (string-match-p regex (treesit-node-type node))
       (string= (treesit-node-type (treesit-node-parent node)) "declarations")))

(defun haskell-ts--imenu-earlier-equation-p (node)
  "Return non-nil if an earlier top-level sibling defines the same name as NODE.
A multi-equation function produces one `function' node per equation;
only the first should reach imenu, so later equations are recognised
here by an earlier `function'/`bind' sibling sharing NODE's name."
  (let ((name (haskell-ts--imenu-node-name node))
        (prev (treesit-node-prev-sibling node t))
        (found nil))
    (while (and prev (not found))
      (when (and (string-match-p "function\\|bind" (treesit-node-type prev))
                 (equal name (haskell-ts--imenu-node-name prev)))
        (setq found t))
      (setq prev (treesit-node-prev-sibling prev t)))
    found))

(defun haskell-ts-imenu-func-node-p (node)
  (and (haskell-ts-imenu-node-p "function\\|bind" node)
       ;; Collapse a function's multiple equations into a single entry.
       (not (haskell-ts--imenu-earlier-equation-p node))))

(defun haskell-ts-imenu-sig-node-p (node)
  (haskell-ts-imenu-node-p "signature" node))

(defun haskell-ts-imenu-data-type-p (node)
  (haskell-ts-imenu-node-p "data_type\\|newtype" node))

(defun haskell-ts-imenu-typealias-type-p (node)
  (haskell-ts-imenu-node-p "type_synonym" node))

(defun haskell-ts-defun-name (node)
  (treesit-node-text (treesit-node-child node 0)))

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

(defun haskell-ts--cabal-file-target (root target)
  "Resolve TARGET against the cabal project, or decide what to do.
TARGET is a file name relative to ROOT, the cabal project root.
Run `cabal repl --dry-run TARGET' from ROOT (reusing
`haskell-ts-cabal-switches' so the probe mirrors the real
invocation) and return one of:
  TARGET  cabal resolves it to a single component, so it can be
          passed as the `cabal repl' target;
  nil     cabal resolves it to no component (an orphan file not
          listed in any `.cabal', or any other failure), so the
          caller should start a plain `cabal repl' instead.
Signal a `user-error' when TARGET is shared by several components
and cabal cannot pick one (its [Cabal-7132] \"Ambiguous target\"):
neither passing nor omitting it would start the REPL the user
meant, so abort with cabal's candidate list and the fix."
  (let ((default-directory (expand-file-name root)))
    (with-temp-buffer
      (let ((status (apply #'call-process haskell-ts-cabal nil t nil
                           (append haskell-ts-cabal-switches
                                   (list "--dry-run" target)))))
        (cond
         ((eq status 0) target)
         ((save-excursion
            (goto-char (point-min))
            (re-search-forward "Ambiguous target" nil t))
          (user-error
           (concat "haskell-ts: %s is shared by several cabal components; "
                   "`cabal repl' cannot choose one.  Name a component in "
                   "`haskell-ts-cabal-switches', e.g. (\"repl\" \"my-exe\").  "
                   "cabal reported:\n%s")
           target (string-trim (buffer-string))))
         (t nil))))))

(defun haskell-ts--repl-command (root file)
  "Return (PROGRAM . SWITCHES) for starting the REPL.
ROOT is the cabal project root as returned by
`haskell-ts--cabal-project-root', or nil.  FILE is the file visited
by the buffer from which the REPL is started, or nil.  Honour
`haskell-ts-use-cabal'.

When cabal is used and both ROOT and FILE are non-nil, FILE is
appended (relative to ROOT) as a `cabal repl' target so that cabal
selects the component that owns it.  In a multi-component project
this avoids the Cabal-7076 error that `cabal repl' raises when no
target is given.  `haskell-ts--cabal-file-target' decides per file:
a FILE in one component is used as the target, a FILE in no
component is omitted so a plain `cabal repl' starts, and a FILE
shared by several components aborts with a helpful `user-error'."
  (if (and haskell-ts-use-cabal
           (or (eq haskell-ts-use-cabal t) root)
           (executable-find haskell-ts-cabal))
      (let ((target (and root file
                         (haskell-ts--cabal-file-target
                          root (file-relative-name
                                file (expand-file-name root))))))
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

(defun haskell-ts-compile-region-and-go (start end)
  "Compile the text from START to END in the haskell proc.
If region is not active, reload the whole file."
  (interactive (if (region-active-p)
                   (list (region-beginning) (region-end))
                 (list (point-min) (point-max))))
  (let ((hs (haskell-ts-show-repl)))
    (if (region-active-p)
        (let ((str (buffer-substring-no-properties start end)))
          ;; GHCi's `:{' ... `:}' multiline block has no escape mechanism:
          ;; it terminates at the first line that is exactly `:}'.  Such a
          ;; line is not valid Haskell, but if one ever appears in the
          ;; region we must refuse rather than send a corrupted block.
          (when (string-match-p "^[ \t]*:}[ \t]*$" str)
            (user-error "Region contains a line that is just `:}'; cannot send to GHCi"))
          (comint-send-string hs ":{\n")
          (comint-send-string hs str)
          (comint-send-string hs "\n:}\n"))
      (comint-send-string hs ":r\n"))))

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
(defun haskell-ts-run ()
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

The REPL inherits the calling buffer's `process-environment' and
`exec-path' via `inheritenv', so a toolchain configured
buffer-locally by envrc/direnv is honoured both when probing the
`cabal repl' target and when starting the inferior process.

The inferior buffer uses `haskell-ts-inferior-mode', which gives it
a recognised GHCi prompt, a read-only prompt, persistent input
history and the usual `comint-mode' bindings."
  (interactive)
  (inheritenv
   (let* ((buffer (get-buffer-create haskell-ts-ghci-buffer-name))
          ;; Capture the file before `make-comint-in-buffer' below makes
          ;; the inferior buffer current.
          (file buffer-file-name)
          (root (haskell-ts--cabal-project-root))
          (command (haskell-ts--repl-command root file))
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
  (get-buffer-process haskell-ts-ghci-buffer-name))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.hs\\'" . haskell-ts-mode))

(provide 'haskell-ts-mode)

;; derive from `haskell-mode' on emacs v30+
(when (functionp 'derived-mode-add-parents)
  (derived-mode-add-parents 'haskell-ts-mode '(haskell-mode)))

;;; haskell-ts-mode.el ends here
