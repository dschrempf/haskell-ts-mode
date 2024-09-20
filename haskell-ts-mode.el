;;; haskell-ts-mode.el --- A treesit based major mode for haskell -*- lexical-binding:t -*-

;; Copyright (C) 2024  Pranshu Sharma


;; Author: Pranshu Sharma <pranshusharma366 at gmail>
;; URL: https://codeberg.org/pranshu/haskell-ts-mode
;; Package-Requires: ((emacs "29.3"))
;; Version: 1
;; Keywords: languages, haskell

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

;;; Code:

(require 'comint)
(require 'treesit)

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

(defvar haskell-ts-font-lock-feature-list
  `((comment str pragma parens)
    (type definition function args)
    (match keyword)
    (otherwise signature type-sig)))

(defcustom haskell-ts-use-indent t
  "Set to non-nil to use the indentation provided by haskell-ts-mode"
  :group 'haskell-ts-mode
  :type 'boolean)

(defcustom haskell-ts-font-lock-level 4
  "Level of font lock, 1 for minimum highlghting and 4 for maximum."
  :group 'haskell-ts-mode
  :type 'integer)

(defvar haskell-ts-prettify-symbols-alist
  '(("\\" . "λ")
    ("/=" . "≠")
    ("->" . "→")
    ("=>" . "⇒")
    ("<-" . "←")
    ("<=" . "≥")
    (">=" . "≤")))

(defvar haskell-ts-font-lock
  (treesit-font-lock-rules
   :language 'haskell
   :feature 'keyword
   `(["module" "import" "data" "let" "where" "case" "type"
      "if" "then" "else" "of" "do" "in" "instance" "class"]
     @font-lock-keyword-face)
   :language 'haskell
   :feature 'otherwise
   :override t
   `(((match (guards guard: (boolean (variable) @font-lock-keyword-face)))
      (:match "otherwise" @font-lock-keyword-face)))
   :language 'haskell
   :feature 'type-sig
   "(signature (binding_list (variable) @font-lock-doc-markup-face))
    (signature (variable) @font-lock-doc-markup-face)"
   :language 'haskell
   :feature 'args
   :override 'keep
   (concat
    "(function (infix left_operand: (_) @haskell-ts--fontify-arg))"
    "(function (infix right_operand: (_) @haskell-ts--fontify-arg))"
    "(generator . (_) @haskell-ts--fontify-arg)"
    "(bind (as (variable) . (_) @haskell-ts--fontify-arg))"
    "(patterns) @haskell-ts--fontify-arg")
   :language 'haskell
   :feature 'type
   `((type) @font-lock-type-face
     (constructor) @font-lock-type-face)
   :language 'haskell
   :override t
   :feature 'signature
   `((signature (function) @haskell-ts--fontify-type)
     (context (function) @haskell-ts--fontify-type))
   :language 'haskell
   :feature 'match
   `((match ("|" @font-lock-doc-face) ("=" @font-lock-doc-face))
     (list_comprehension ("|" @font-lock-doc-face
			  (qualifiers (generator "<-" @font-lock-doc-face))))
     (match ("->" @font-lock-doc-face)))
   :language 'haskell
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
   `(["(" ")" "[" "]"] @font-lock-operator-face
     (infix operator: (_) @font-lock-operator-face))
   :language 'haskell
   :feature 'function
   :override t
   `((function name: (variable) @font-lock-function-name-face)
     (function (infix (operator)  @font-lock-function-name-face))
     (declarations (type_synomym (name) @font-lock-function-name-face))
     (bind (variable) @font-lock-function-name-face)
     (function (infix (infix_id (variable) @font-lock-function-name-face)))
     (bind (as (variable) @font-lock-function-name-face))))
  "A function that returns the treesit font lock lock settings for haskell.")

(defun haskell-ts--stand-alone-parent (_ parent bol)
  (save-excursion
    (goto-char (treesit-node-start parent))
    (let ((type (treesit-node-type parent)))
	(if (and (looking-back "^[ \t]*" (line-beginning-position))
		 (not (seq-some
		       (lambda (kw) 
			 (string= type kw))
		       '("when" "where" "do" "let"))))
	(treesit-node-start parent)
	(haskell-ts--stand-alone-parent 1 (funcall
					   (if bol 'treesit-node-parent 'identity)
					   (treesit-node-parent parent))
					nil)))))

(defvar haskell-ts--ignore-types
  '("comment" "cpp" "haddock")
  "Node types that will be ignored by indentation.")

(defvar haskell-ts-indent-rules
  (let* ((p-sib
	 (lambda (node arg)
	   (let* ((func (if arg
			   'treesit-node-prev-sibling
			 'treesit-node-next-sibling))
		 (n (funcall func	 node)))
	     (while (and n (string-match (regexp-opt haskell-ts--ignore-types)
					 (treesit-node-type n)))
	       (setq n (funcall func n)))
	     n)))
	 (p-prev-sib
	  (lambda (node _ _) (treesit-node-start (funcall p-sib node t))))
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
	0)
       ((node-is "^infix$") ,parent-first-child 0)
       
       ;; Lambda
       ((parent-is "^lambda$") standalone-parent 2)

       ((parent-is "^class_declarations$") prev-sibling 0)

       ((node-is "^where$") parent 2)
       
       ;; in
       ((node-is "^in$") parent 0)
       
       ;; list
       ((node-is "^]$") parent 0)
       ((parent-is "^list$") standalone-parent 2)
       
       ;; If then else
       ((node-is "^then$") parent 2)
       ((node-is "^else$") parent 2)

       ((parent-is "^apply$") haskell-ts--stand-alone-parent 1)
       ((node-is "^quasiquote$") grand-parent 2)
       ((parent-is "^quasiquote_body$") (lambda (_ _ c) c) 0)
       ((lambda (node parent bol)
	  (when-let ((n (treesit-node-prev-sibling node)))
	    (while (string= "comment" (treesit-node-type n))
	      (setq n (treesit-node-prev-sibling n)))
	    (string= "do" (treesit-node-type n))))
	haskell-ts--stand-alone-parent
	3)
       ((parent-is "^do$") ,p-prev-sib 0)

       ((parent-is "^alternatives$") ,p-prev-sib 0)

       ;; prev-adaptive-prefix is broken sometimes
       (no-node
	(lambda (_ _ _)
	  (save-excursion
	    (goto-char (line-beginning-position 0))
	    (back-to-indentation)
	    (point)))
	0)
       
       ((parent-is "^data_constructors$") parent 0)

       ;; where
       ((lambda (node _ _)
	  (let ((n (treesit-node-prev-sibling node)))
	    (while (string= "comment" (treesit-node-type n))
	      (setq n (treesit-node-prev-sibling n)))
	    (string= "where" (treesit-node-type n))))
	
	(lambda (_ b _)
	  (+ 1 (treesit-node-start (treesit-node-prev-sibling b))))
	3)
       ((parent-is "local_binds\\|instance_declarations") ,p-prev-sib 0)
	
       ;; Match
       ((lambda (node _ _)
	  (and (string= "match" (treesit-node-type node))
	       (string-match (regexp-opt '("patterns" "variable"))
			     (treesit-node-type (funcall ,p-n-prev node)))))
	standalone-parent 2
	)
       
       ;; ((lambda (_ _ _) (message "HERE") nil))
       ;; ((node-is "match") ,p-prev-sib 0)
       ;; ((parent-is "match") standalone-parent 2)
       ((parent-is "^haskell$") column-0 0)
       ((parent-is "^declarations$") column-0 0)
       
       ((parent-is "^record$") standalone-parent 2)

       ((parent-is "^exports$")
	(lambda (_ b _) (treesit-node-start (treesit-node-prev-sibling b)))
	0)
       ((n-p-gp nil "signature" "foreign_import") grand-parent 3)
       ((parent-is "^case$") standalone-parent 4)
       ((node-is "^alternatives$")
	(lambda (_ b _)
	  (treesit-node-start (treesit-node-child b 0)))
	2)
       ((node-is "^comment$")
	;; Indenting comments by priorites:
	;; 1. next relevent sibling if exists
	;; 2. previous relevent sibling if exists
	;; 3. parent
	;; (relevent means type not it haskell-ts--ignore-types)
	(lambda (node parent _)
	   (if-let ((next-sib (funcall ,p-sib node nil)))
	       (treesit-node-start next-sib)
	     (if-let ((prev-sib (funcall ,p-prev-sib node nil nil)))
	       prev-sib
	     (treesit-node-start parent))))
	0)
       ;; Backup
       (catch-all parent 2)))))

;; Copied from haskell-tng-mode, changed a bit
(defvar haskell-ts-mode-syntax-table
  (let ((table (make-syntax-table)))
    (map-char-table
     (lambda (k v)
       ;; reset the (surprisingly numerous) defaults
       (let ((class (syntax-class v)))
         (when (seq-contains-p '(1 4 5 6 9) class)
           (modify-syntax-entry k "_" table))))
     (char-table-parent table))
    ;; whitechar
    (mapc
     (lambda (it) (modify-syntax-entry it " " table))
     (string-to-list "\r\n\f\v \t"))
    ;; ascSymbol
    (mapc
     (lambda (it) (modify-syntax-entry it "_" table))
     (string-to-list "!#$%&*+./<=>?\\^|-~:"))
    (modify-syntax-entry ?_ "_" table)
    ;; some special (treated like punctuation)
    (mapc
     (lambda (it) (modify-syntax-entry it "." table))
     (string-to-list ",;@"))
    ;; apostrophe as a word, not delimiter
    (modify-syntax-entry ?\' "w" table)
    ;; string delimiter
    (modify-syntax-entry ?\" "\"" table)
    ;; parens and pairs (infix functions)
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    (modify-syntax-entry ?\[ "(]" table)
    (modify-syntax-entry ?\] ")[" table)
    (modify-syntax-entry ?\` "$`" table)

    ;; comments (subsuming pragmas)
    (modify-syntax-entry ?\{  "(}1nb" table)
    (modify-syntax-entry ?\}  "){4nb" table)
    (modify-syntax-entry ?-  "_ 123" table)
    (mapc
     (lambda (it) (modify-syntax-entry it ">" table))
     (string-to-list "\r\n\f\v"))
    table))

(defmacro haskell-ts-imenu-name-function (check-func)
  `(lambda (node)
     (let ((nn (treesit-node-child node 0 node)))
	 (if (funcall ,check-func node)
	 (if (string= (treesit-node-type nn) "infix")
	     (treesit-node-text (treesit-node-child nn 1))
	     (haskell-ts-defun-name node))
       nil))))

(defun haskell-ts-indent-defun (pos)
  "Indent the current function."
  (interactive "d")
  (let ((node (treesit-node-at pos)))
    (while (not (string-match
		 "^declarations$\\|haskell"
		 (treesit-node-type (treesit-node-parent node))))
      (setq node (treesit-node-parent node)))
    (indent-region (treesit-node-start node) (treesit-node-end node))))

(defvar haskell-ts-mode-map
  (let ((km (make-sparse-keymap)))
    (define-key km (kbd "C-c C-c") 'haskell-ts-compile-region-and-go)
    (define-key km (kbd "C-c C-r") 'haskell-ts-run-haskell)
    (define-key km (kbd "C-M-q") 'haskell-ts-indent-defun) ; For those who don't have emacs 30
    km)
  "Map for haskell-ts-mode.")

;;;###autoload
(define-derived-mode haskell-ts-mode prog-mode "haskell ts mode"
  "Major mode for Haskell files using tree-sitter."
  (unless (treesit-ready-p 'haskell)
    (error "Tree-sitter for Haskell is not available"))
  (treesit-parser-create 'haskell)
  (setq-local treesit-defun-type-regexp "\\(?:\\(?:function\\|struct\\)_definition\\)")
  ;; Indent
  (when haskell-ts-use-indent
    (setq-local treesit-simple-indent-rules haskell-ts-indent-rules)
    (setq-local indent-tabs-mode nil))
  ;; Comment
  (setq-local comment-start "-- ")
  (setq-local comment-use-syntax t)
  (setq-local comment-start-skip "\\(?: \\|^\\)-+")
  ;; Elecric
  (setq-local electric-pair-pairs
	      '((?` . ?`) (?\( . ?\)) (?{ . ?}) (?\" . ?\") (?\[ . ?\])))
  ;; Nav
  (setq-local treesit-defun-name-function 'haskell-ts-defun-name)
  (setq-local treesit-defun-type-regexp
	      ;; Since haskell is strict functional, any 2nd level
	      ;; entity is defintion
	      (cons ".+"
		    (lambda (node)
		      (string= "declarations" (treesit-node-type (treesit-node-parent node))))))
  (setq-local prettify-symbols-alist haskell-ts-prettify-symbols-alist)
  ;; Imenu
  (setq-local treesit-simple-imenu-settings
	      `((nil haskell-ts-imenu-func-node-p nil
		     ,(haskell-ts-imenu-name-function #'haskell-ts-imenu-func-node-p))
		("Signatures.." haskell-ts-imenu-sig-node-p nil
		 ,(haskell-ts-imenu-name-function #'haskell-ts-imenu-sig-node-p))
		("Data..." haskell-ts-imenu-data-type-p nil
		 (lambda (node)
		   (treesit-node-text (treesit-node-child node 1))))))
  ;; font-lock
  (setq-local treesit-font-lock-level haskell-ts-font-lock-level)
  (setq-local treesit-font-lock-settings haskell-ts-font-lock)
  (setq-local treesit-font-lock-feature-list
	      haskell-ts-font-lock-feature-list)
  (treesit-major-mode-setup))

(defun haskell-ts--fontify-arg (node &optional _ _ _)
  (if (string= "variable" (treesit-node-type node))
      (put-text-property
       (treesit-node-start node)
       (treesit-node-end node)
       'face font-lock-variable-name-face)
    (mapc 'haskell-ts--fontify-arg (treesit-node-children node))))

(defun haskell-ts--fontify-type (node &optional _ _ _)
  (let ((last-child (treesit-node-child node -1)))
    (if (string= (treesit-node-type last-child) "function")
	(haskell-ts--fontify-type last-child)
      (put-text-property
       (treesit-node-start last-child)
       (treesit-node-end last-child)
       'face font-lock-variable-name-face))))

(defun haskell-ts-imenu-node-p (regex node)
  (and (string-match-p regex (treesit-node-type node))
       (string= (treesit-node-type (treesit-node-parent node)) "declarations")))

(defun haskell-ts-imenu-func-node-p (node)
  (haskell-ts-imenu-node-p "function\\|bind" node))

(defun haskell-ts-imenu-sig-node-p (node)
  (haskell-ts-imenu-node-p "signature" node))

(defun haskell-ts-imenu-data-type-p (node)
  (haskell-ts-imenu-node-p "data_type" node))

(defun haskell-ts-defun-name (node)
  (treesit-node-text (treesit-node-child node 0)))

(defun haskell-ts-compile-region-and-go (start end)
  "Compile the text from START to END in the haskell proc."
  (interactive "r")
  (let ((hs (haskell-ts-haskell-session)))
    (comint-send-string hs ":{\n")
    (comint-send-region hs start end)
    (comint-send-string hs "\n:}\n")))

(defun haskell-ts-run-haskell()
  (interactive)
  (pop-to-buffer-same-window
   (if (comint-check-proc "*haskell*")
       "*haskell*"
     (make-comint "haskell" "ghci" nil buffer-file-name))))

(defun haskell-ts-haskell-session ()
  (get-buffer-process "*haskell*"))

(defvar eglot-server-programs)

(defun haskell-ts-setup-eglot()
  (add-to-list 'eglot-server-programs
	       '(haskell-ts-mode . ("haskell-language-server-wrapper" "--lsp"))))

(when (treesit-ready-p 'haskell)
  (add-to-list 'auto-mode-alist '("\\.hs\\'" . haskell-ts-mode)))

(provide 'haskell-ts-mode)

;;; haskell-ts-mode.el ends here
