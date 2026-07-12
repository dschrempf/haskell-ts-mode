;;; haskell-ts-mode.el --- A treesit based major mode for haskell -*- lexical-binding:t -*-

;; Copyright (C) 2024, 2025 Pranshu Sharma
;; Copyright (C) 2026 Dominik Schrempf

;; Author: Pranshu Sharma <pranshu@bauherren.ovh>
;;         Dominik Schrempf <dominik.schrempf@gmail.com>
;; Maintainer: Dominik Schrempf <dominik.schrempf@gmail.com>
;; URL: https://codeberg.org/pranshu/haskell-ts-mode
;; Package-Requires: ((emacs "30.1") (inheritenv "0.1"))
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

(require 'treesit)
(require 'haskell-ts-navigation)
(require 'haskell-ts-repl)

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

(defgroup haskell-ts nil
  "Customization group for `haskell-ts-mode'."
  :group 'langs)

(defcustom haskell-ts-font-lock-level 4
  "Level of font lock, 1 for minimum highlighting and 4 for maximum."
  :type '(choice (const :tag "Minimal Highlighting" 1)
                 (const :tag "Low Highlighting" 2)
                 (const :tag "High Highlighting" 3)
                 (const :tag "Maximum Highlighting" 4))
  :group 'haskell-ts)

(defcustom haskell-ts-prettify-symbols nil
  "Prettify some symbol combinations to unicode symbols.
This will concat `haskell-ts-prettify-symbols-alist' to
`prettify-symbols-alist' in `haskell-ts-mode'."
  :type 'boolean
  :group 'haskell-ts)

(defcustom haskell-ts-prettify-words nil
  "Prettify some words to unicode symbols.
This will concat `haskell-ts-prettify-words-alist' to
`prettify-symbols-alist' in `haskell-ts-mode'."
  :type 'boolean
  :group 'haskell-ts)

(defface haskell-ts-constructor-face
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
      "if" "then" "else" "of" "do" "in" "instance" "class" "newtype"
      "forall" "pattern" "via" "stock" "anyclass"
      "infix" "infixl" "infixr" "mdo" "rec"]
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
   '((constructor) @haskell-ts-constructor-face
     (data_constructor
      (prefix field: (_) @haskell-ts--fontify-arg))
     (type_params (_) @font-lock-variable-name-face)
     (type_synonym (name) @font-lock-type-face)
     (data_type name: (name) @font-lock-type-face)
     (newtype name: (name) @font-lock-type-face)
     (deriving "deriving" @font-lock-keyword-face
               classes: (_) @haskell-ts-constructor-face)
     (deriving_instance "deriving" @font-lock-keyword-face
                        name: (_) @haskell-ts-constructor-face))

   :language 'haskell
   :feature 'match
   `((match ("|" @font-lock-doc-face) ("=" @font-lock-doc-face))
     (list_comprehension ("|" @font-lock-doc-face
                          (qualifiers (generator "<-" @font-lock-doc-face))))
     (match ("->" @font-lock-doc-face))
     (bind arrow: _ @font-lock-doc-face))

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
Delegates to `haskell-ts-defun-name', which already reduces an
operator definition (`a <+> b = ...') to just the operator."
  (haskell-ts-defun-name node))

(defun haskell-ts--imenu-data-type-name (node)
  "Return the name imenu should display for `data_type'/`newtype' NODE.
Reads the `name' field rather than assuming a fixed child index,
since the @tek grammar aliases productions with a different number of
leading keywords (plain `data'/`newtype' vs. the `TypeData' extension's
`type data', vs. a `data instance'/`newtype instance' family instance)
to the same node types."
  (treesit-node-text (treesit-node-child-by-field-name node "name") t))

(defvar-keymap  haskell-ts-mode-map
  :doc "Keymap for haskell-ts-mode."
  "C-c C-c" #'haskell-ts-compile-region-and-go
  "C-c C-l" #'haskell-ts-load-file
  "C-c C-r" #'haskell-ts-run
  "C-c C-e" #'haskell-ts-send-line
  "C-M-x"   #'haskell-ts-send-defun)

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
                     haskell-ts--imenu-data-type-name)
                (nil "type_synonym" haskell-ts-imenu-typealias-type-p
                     (lambda (node)
                       (treesit-node-text (treesit-node-child node 1) t)))))
  ;; font-lock
  (setq-local treesit-font-lock-level haskell-ts-font-lock-level)
  (setq-local treesit-font-lock-settings haskell-ts-font-lock)
  (setq-local treesit-font-lock-feature-list
              haskell-ts-font-lock-feature-list)
  (treesit-major-mode-setup)
  (setq-local forward-sexp-function #'haskell-ts--forward-sexp)
  (setq-local forward-sentence-function #'haskell-ts--forward-sentence))

(defun haskell-ts--fontify-func (node face)
  "Apply FACE to every `variable' leaf under NODE, recursing otherwise."
  (if (string= "variable" (treesit-node-type node))
      (put-text-property
       (treesit-node-start node)
       (treesit-node-end node)
       'face face)
    (mapc (lambda (n) (haskell-ts--fontify-func n face))
          (treesit-node-children node))))

(defun haskell-ts--fontify-arg (node &optional _ _ _)
  "Treesit font-lock function fontifying NODE as a bound variable."
  (haskell-ts--fontify-func node 'font-lock-variable-name-face))

(defun haskell-ts--fontify-params (node &optional _ _ _)
  "Treesit font-lock function fontifying NODE as a bound function name."
  (haskell-ts--fontify-func node 'font-lock-function-name-face))

(defun haskell-ts--fontify-type (node &optional _ _ _)
  "Treesit font-lock function fontifying the type variable at the end of NODE.
Recurses into NODE's last child when it is itself a `function' type
node, so a curried type's outermost return type is what gets
fontified."
  (let ((last-child (treesit-node-child node -1)))
    (if (string= (treesit-node-type last-child) "function")
        (haskell-ts--fontify-type last-child)
      (put-text-property
       (treesit-node-start last-child)
       (treesit-node-end last-child)
       'face 'font-lock-variable-name-face))))

(defun haskell-ts-imenu-node-p (regex node)
  "Return non-nil if NODE is a top-level declaration matching REGEX.
Top-level means NODE's parent is a `declarations' node, or NODE is a
`data_type'/`newtype' node wrapped in a `data_instance' node (a
`data instance'/`newtype instance' family instance) whose own parent
is `declarations'."
  (and (string-match-p regex (treesit-node-type node))
       (let ((parent (treesit-node-parent node)))
         (or (string= (treesit-node-type parent) "declarations")
             (and (string= (treesit-node-type parent) "data_instance")
                  (string= (treesit-node-type (treesit-node-parent parent))
                           "declarations"))))))

(defun haskell-ts--imenu-earlier-equation-p (node)
  "Return non-nil if an earlier top-level sibling shares NODE's name.
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
  "Return non-nil if NODE is a top-level function/binding imenu entry.
Only the first equation of a multi-equation function qualifies; see
`haskell-ts--imenu-earlier-equation-p'."
  (and (haskell-ts-imenu-node-p "function\\|bind" node)
       ;; Collapse a function's multiple equations into a single entry.
       (not (haskell-ts--imenu-earlier-equation-p node))))

(defun haskell-ts-imenu-sig-node-p (node)
  "Return non-nil if NODE is a top-level type signature imenu entry."
  (haskell-ts-imenu-node-p "signature" node))

(defun haskell-ts-imenu-data-type-p (node)
  "Return non-nil if NODE is a top-level `data'/`newtype' imenu entry."
  (haskell-ts-imenu-node-p "data_type\\|newtype" node))

(defun haskell-ts-imenu-typealias-type-p (node)
  "Return non-nil if NODE is a top-level type synonym imenu entry."
  (haskell-ts-imenu-node-p "type_synonym" node))

(defun haskell-ts-defun-name (node)
  "Return the name of declaration NODE for `treesit-defun-name-function'.
For an operator definition, whose left-hand side is an `infix' node
\(as in `a <+> b = ...'), this is just the operator (`<+>'), not the
whole `a <+> b' pattern; otherwise it is the text of NODE's first
child."
  (let ((child (treesit-node-child node 0 t)))
    (if (equal (treesit-node-type child) "infix")
        (treesit-node-text (treesit-node-child child 1))
      (treesit-node-text (treesit-node-child node 0)))))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.hs\\'" . haskell-ts-mode))

(provide 'haskell-ts-mode)

;; derive from `haskell-mode' on emacs v30+
(when (functionp 'derived-mode-add-parents)
  (derived-mode-add-parents 'haskell-ts-mode '(haskell-mode)))

;;; haskell-ts-mode.el ends here
