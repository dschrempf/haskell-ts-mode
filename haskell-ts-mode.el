;;; haskell-ts-mode.el --- A treesit based major mode for haskell -*- lexical-binding:t -*-

;; Copyright (C) 2024, 2025 Pranshu Sharma

;; Author: Pranshu Sharma <pranshu@bauherren.ovh>
;; URL: https://codeberg.org/pranshu/haskell-ts-mode
;; Package-Requires: ((emacs "29.3") (inheritenv "0.1"))
;; Version: 1.3.5
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
;; It uses the grammar at: https://github.com/tree-sitter/tree-sitter-haskell

;;; Code:

(require 'comint)
(require 'treesit)
(require 'inheritenv)

(declare-function treesit-parser-create "treesit.c")
(declare-function treesit-node-start "treesit.c")
(declare-function treesit-node-parent "treesit.c")
(declare-function treesit-node-prev-sibling "treesit.c")
(declare-function treesit-node-next-sibling "treesit.c")
(declare-function treesit-node-end "treesit.c")
(declare-function treesit-node-child "treesit.c")
(declare-function treesit-node-type "treesit.c")

(defgroup haskell-ts-mode nil
  "Group that contains haskell-ts-mode variables"
  :group 'langs)

(defcustom haskell-ts-ghci "ghci"
  "The name or path program to be called to run the ghci repl.  Any
arguments to be passed should be added `haskell-ts-ghci-switches`."
  :type 'string)

(defcustom haskell-ts-ghci-switches nil
  "Arguments to be passed to `haskell-ts-ghci'."
  :type '(repeat string))

(defcustom haskell-ts-cabal "cabal"
  "The name or path of the cabal program used to start the REPL.
Used instead of `haskell-ts-ghci' according to `haskell-ts-use-cabal'.
Any arguments should be added to `haskell-ts-cabal-switches'."
  :type 'string)

(defcustom haskell-ts-cabal-switches '("repl")
  "Arguments to be passed to `haskell-ts-cabal'.
The default starts an interactive session for the project's
default component.  Because `cabal repl' configures GHCi with the
component's dependencies, default language extensions and GHC
options, code loaded into such a session compiles as it would in
a build, unlike a plain `ghci' session."
  :type '(repeat string))

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
                 (const :tag "Always plain ghci" nil)))

(defcustom haskell-ts-ghci-buffer-name "*Inferior Haskell*"
  "Buffer name for the ghci process."
  :type 'string)

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

(defcustom haskell-ts-use-indent nil
  "Set to non-nil to use the indentation provided by haskell-ts-mode"
  :type 'boolean)

(defcustom haskell-ts-font-lock-level 4
  "Level of font lock, 1 for minimum highlighting and 4 for maximum."
  :type '(choice (const :tag "Minimal Highlighting" 1)
                 (const :tag "Low Highlighting" 2)
                 (const :tag "High Highlighting" 3)
                 (const :tag "Maximum Highlighting" 4)))

(defcustom haskell-ts-prettify-symbols nil
  "Prettify some symbol combinations to unicode symbols.
This will concat `haskell-ts-prettify-symbols-alist' to
`prettify-symbols-alist' in `haskell-ts-mode'."
  :type 'boolean)

(defcustom haskell-ts-prettify-words nil
  "Prettify some words to unicode symbols.
This will concat `haskell-ts-prettify-words-alist' to
`prettify-symbols-alist' in `haskell-ts-mode'."
  :type 'boolean)

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

(defun haskell-ts--stand-alone-parent (_ parent _ &optional last_non_paren first)
  (save-excursion
    (goto-char (treesit-node-start parent))
    (let* ((type (treesit-node-type parent))
           (res (if (or (and first
                             (member
                              type
                              '("when" "do" "let_in" "local_binds" "function")))
                        (looking-back "^[ \t]*" (line-beginning-position)))
                    (treesit-node-start (if (and (string= "parens" type) last_non_paren)
                                            last_non_paren
                                          parent))
                  (haskell-ts--stand-alone-parent 1
                                                  (treesit-node-parent parent)
                                                  nil
                                                  (if (string= "parens" type)
                                                      last_non_paren
                                                    parent)
                                                  t))))
      ;; This is an astronomically huge hack.  The kind where if you
      ;; took it you wouldn't be able to walk for several days after,
      ;; no homo
      (let ((adjustments '(("conditional" . 2)
                           ("local_binds" . 1))))
        (if-let* ((offset (assoc-string type adjustments)))
            (+ (cdr offset) res)
          res)
        ))))

(defvar haskell-ts--ignore-types
  (regexp-opt '("comment" "cpp" "haddock" ";"))
  "Node types that will be ignored by indentation.")

(defvar haskell-ts-indent-rules
  (let* ((p-sib
          (lambda (node &optional arg)
            (let* ((func (if arg
                             #'treesit-node-prev-sibling
                           #'treesit-node-next-sibling))
                   (n (funcall func node)))
              (while (and n (string-match haskell-ts--ignore-types
                                          (treesit-node-type n)))
                (setq n (funcall func n)))
              n)))
         (p-prev-sib
          (lambda (node &optional _ _) (treesit-node-start (funcall p-sib node t))))
         (p-n-prev (lambda (node) (funcall p-sib node t)))
         (parent-first-child (lambda (_ parent _)
                               (treesit-node-start (treesit-node-child parent 0)))))
    `((haskell
       ((node-is "^cpp$") column-0 0)
       ((parent-is "^comment$") column-0 0)
       ((parent-is "^haddock$") column-0 0)
       ((parent-is "^imports$") column-0 0)
       ;; Infix
       ((n-p-gp nil "infix" "infix")
        (lambda (_ node _)
          (let ((first-inf nil))
            (while (string= "infix"
                            (treesit-node-type
                             (setq node (treesit-node-parent node))))
              (setq first-inf node))
            (funcall ,parent-first-child nil first-inf nil)))
        2)
       ((parent-is "^infix$") parent 2)
       ((node-is "^infix$") standalone-parent 2)

       ;; Lambda
       ((parent-is "^lambda$") haskell-ts--stand-alone-parent 2)

       ((parent-is "^class_declarations$") prev-sibling 0)

       ((node-is "^where$") parent 2)

       ;; in
       ((node-is "^in$") parent 1)

       ((parent-is "qualifiers") parent 0)

       ;; list
       ((node-is "^]$") parent 0)
       ((parent-is "^list$") standalone-parent 2)

       ;; Parens
       ((node-is "^)$") parent 0)

       ;; Structs
       ((parent-is "^field$") standalone-parent 2)
       ((node-is "^}$")
        (lambda (_ parent bol)
          (let ((sib (treesit-node-child parent 0)))
            (while (and sib (not (string= (treesit-node-type sib)
                                          "{"))) ; } Srry for ocd
              (setq sib (treesit-node-next-sibling sib)))
            (if sib
                (treesit-node-start sib)
              bol)))
        0)

       ((parent-is "^apply$") haskell-ts--stand-alone-parent 2)
       ((node-is "^quasiquote$") grand-parent 2)
       ((parent-is "^quasiquote_body$") (lambda (_ _ c) c) 0)
       ((lambda (node parent bol)
          (when-let ((n (treesit-node-prev-sibling node)))
            (while (string= "comment" (treesit-node-type n))
              (setq n (treesit-node-prev-sibling n)))
            (string= "do" (treesit-node-type n))))
        haskell-ts--stand-alone-parent
        2)
       ((parent-is "^do$") ,p-prev-sib 0)

       ((parent-is "^alternatives$") ,p-prev-sib 0)

       ;; prev-adaptive-prefix is broken sometimes
       (no-node
        (lambda (_ _ _)
          (save-excursion
            (goto-char (line-beginning-position 0))
            (back-to-indentation)
            (if (looking-at "\n")
                0
              (point))))
        0)

       ((node-is "^data_constructors$") parent 4)
       ((node-is "^data_constructor$") parent 0)
       ((n-p-gp "^\|$" "^data_constructors$" nil) parent -2)

       ;; where
       ((node-is "local_binds") ,p-prev-sib 2)
       
       ((parent-is "local_binds\\|instance_declarations") ,p-prev-sib 0)

       ;; Conditionals This builds up on the hackiness of what happens
       ;; in haskell-ts--stand-alone-parent
       ((node-is "^then$") parent 2)
       ((node-is "^else$") parent 2)
       ((parent-is "^conditional$") parent 4)

       ;; let.  It is important this one is in the bottom.
       ((lambda (_ p _)
          (let ((gp "let_in"))
            (or (string= gp (treesit-node-type p))
                (string= gp (treesit-node-type (treesit-node-parent p))))))
        haskell-ts--stand-alone-parent 2)

       
       ;; Match
       ((lambda (node _ _)
          (and (string= "match" (treesit-node-type node))
               (string-match (regexp-opt '("patterns" "variable"))
                             (treesit-node-type (funcall ,p-n-prev node)))))
        parent 2)

       ((node-is "^match$") ,p-prev-sib 0)
       ((parent-is "^match$") haskell-ts--stand-alone-parent 2)

       ((parent-is "^haskell$") column-0 0)
       ((parent-is "^declarations$") column-0 0)

       ((parent-is "^record$") standalone-parent 2)

       ((parent-is "^exports$")
        (lambda (_ b _) (treesit-node-start (treesit-node-prev-sibling b)))
        0)
       ((n-p-gp nil "signature" "foreign_import") grand-parent 3)
       ((parent-is "^\\(lambda_\\)?case$") haskell-ts--stand-alone-parent 2)
       ((node-is "^alternatives$")
        (lambda (_ b _)
          (treesit-node-start (treesit-node-child b 0)))
        2)
       ((node-is "^comment$")
        (lambda (node parent _)
          (pcase node
            ;; (relevent means type not it haskell-ts--ignore-types)
            ;; 1. next relevent sibling if exists
            ((app ,p-sib (and (pred (not null)) n))
             (treesit-node-start n))
            ;; 2. previous relevent sibling if exists
            ((app ,p-prev-sib (and (pred (not null)) n))
             n)
            ;; 3. parent
            (_ (treesit-node-start parent))))
        0)

       ;; TODO: I reckon this needs a variable
       ((node-is "^|$") parent 0)

       ;; Signature
       ((n-p-gp nil "function" "function\\|signature") parent 0)

       ;; Backup
       (catch-all parent 2))))
  "\"Simple\" treesit indentation rules for haskell.")

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

(defun haskell-ts-sexp (node)
  "Returns non-nil on a sexp node."
  (let ((node-text (treesit-node-text node 1)))
    (and
     (not (member node-text '( "{" "}" "[" "]" "(" ")" ";")))
     (not (and (string= "operator" (treesit-node-field-name node))
               (= 1 (length node-text)))))))

(defvar haskell-ts-thing-settings
  `((haskell
     (sexp haskell-ts-sexp)
     (sentence "match")
     (string "string")
     (text "string")))
  "`treesit-thing-settings' for `haskell-ts-mode'.")

;; TODO make into a currying function
(defmacro haskell-ts-imenu-name-function ()
  `(lambda (node)
     (let ((nn (treesit-node-child node 0 t)))
       (if (string= (treesit-node-type nn) "infix")
           (treesit-node-text (treesit-node-child nn 1))
         (haskell-ts-defun-name node)))))

(defvar-keymap  haskell-ts-mode-map
  :doc "Keymap for haskell-ts-mode."
  "C-c C-c" #'haskell-ts-compile-region-and-go
  "C-c C-l" #'haskell-ts-load-file
  "C-c C-r" #'run-haskell)

;;;###autoload
(define-derived-mode haskell-ts-mode prog-mode "haskell ts mode"
  "Major mode for Haskell files using tree-sitter."
  :table haskell-ts-mode-syntax-table
  (unless (treesit-ready-p 'haskell)
    (error "Tree-sitter for Haskell is not available"))
  (setq treesit-primary-parser (treesit-parser-create 'haskell))
  (setq treesit-language-at-point-function
        (lambda (&rest _) 'haskell))
  ;; Indent
  (when haskell-ts-use-indent
    (setq-local treesit-simple-indent-rules haskell-ts-indent-rules)
    (setq-local indent-tabs-mode nil)
    (setq-local electric-indent-functions '(haskell-ts-indent-after-newline)))
  ;; Comment
  (setq-local comment-start "-- ")
  (setq-local comment-use-syntax t)
  (setq-local comment-start-skip "\\(?: \\|^\\)--+")
  ;; Electric
  (setq-local electric-pair-pairs
              '((?` . ?`) (?\( . ?\)) (?{ . ?}) (?\" . ?\") (?\[ . ?\])))
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
                     ,(haskell-ts-imenu-name-function))
                ("Signatures.." "signature" haskell-ts-imenu-sig-node-p
                 ,(haskell-ts-imenu-name-function))
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
  (treesit-major-mode-setup))

(defun haskell-ts-indent-after-newline (c)
  "Indent a freshly inserted line to the previous line's indentation.
Intended as an `electric-indent-functions' entry; C is the just
inserted character and is acted on only when it is a newline."
  (when (eq c ?\n)
    (let ((previous-indent
           (save-excursion
             (forward-line -1)
             (back-to-indentation)
             (current-column))))
      (insert (make-string previous-indent ?\s))))
  nil)

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

(defun haskell-ts-imenu-func-node-p (node)
  (haskell-ts-imenu-node-p "function\\|bind" node))

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
    (save-window-excursion (run-haskell)))
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
Start a session with `run-haskell' if none is running, save the
buffer first so GHCi reads the contents you see on disk, and
display the REPL without leaving the current buffer.

The file is loaded by its absolute path.  Relative `import's are
resolved by GHCi against its working directory, which `run-haskell'
sets to the project root (see `haskell-ts--cabal-project-root'), so
sibling modules are normally found.  When the session was started
with `cabal repl' the project's dependencies and default language
extensions are in scope as well; see `haskell-ts-use-cabal'."
  (interactive)
  (unless buffer-file-name
    (user-error "Buffer is not visiting a file"))
  (save-buffer)
  ;; Capture the path before (possibly) starting GHCi, since
  ;; `run-haskell' makes the inferior buffer current.
  (let* ((file buffer-file-name)
         (proc (haskell-ts-show-repl)))
    (comint-send-string proc (format ":load \"%s\"\n" file))))

(define-derived-mode haskell-ts-inferior-mode comint-mode "Inferior Haskell"
  "Major mode for the inferior Haskell (GHCi) process started by `run-haskell'.

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
(defun run-haskell ()
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
