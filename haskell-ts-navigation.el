;;; haskell-ts-navigation.el --- Sexp/prose navigation for haskell-ts-mode -*- lexical-binding:t -*-

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

;; `forward-sexp'/`backward-sexp' and prose motion (sentences,
;; paragraphs, and Evil's `a p'/`i p' text objects) for
;; `haskell-ts-mode', plus the `RET'/Evil `o'/`O' comment-continuation
;; commands that share their notion of what a `--'/Haddock comment's
;; text actually is.  Required by `haskell-ts-mode.el'.
;;
;; Prose motion is built on two pure primitives, the single source of
;; truth for "what region is point in, and where are its bounds":
;; `haskell-ts--region-at' classifies a position as `code', `comment',
;; `haddock' or `string' and returns the region's bounds (and, for a
;; text node, the node itself); `haskell-ts--prose-bounds' returns the
;; bounds of the sentence or paragraph enclosing a position, confined
;; to its region.  Sentence motion (`haskell-ts--forward-sentence'),
;; the paragraph clamps/narrowing, and marker-aware deletion
;; (`haskell-ts--marker-aware-delete') are all thin consumers of these.
;; In-comment prose analysis runs on a dedented, marker-stripped copy
;; of the node's text mapped back onto the buffer -- see
;; `haskell-ts--text-node-segments' and `haskell-ts--virtual-text-and-table'.
;;
;; Several of these features are implemented as `:around' advice on
;; functions used well outside this mode -- `newline', `kill-region',
;; `kill-sentence'/`backward-kill-sentence', and paragraph motion
;; (`forward-paragraph'/`start-of-paragraph-text'), plus Evil's own
;; motion/deletion commands under `with-eval-after-load'.  Emacs advice
;; on a named function is global (there is no buffer-local
;; `forward-paragraph-function' etc. to set instead), so each advice is
;; installed globally but written to be inert outside `haskell-ts-mode':
;; it either checks `derived-mode-p' up front or gates on a dynamic
;; variable (`haskell-ts--sentence-deletion-active') bound only by this
;; package's own commands.  `delete-region', the hottest primitive of
;; the set, is advised only when Evil is loaded, since Evil is the only
;; caller that can ever trigger its marker-aware path.

;;; Code:

(require 'cl-lib)
(require 'treesit)

(declare-function treesit-node-start "treesit.c")
(declare-function treesit-node-parent "treesit.c")
(declare-function treesit-node-end "treesit.c")
(declare-function treesit-node-type "treesit.c")
(declare-function treesit-node-text "treesit.c")
(declare-function treesit-node-field-name "treesit.c")
(declare-function treesit-node-child-by-field-name "treesit.c")
(declare-function treesit-node-match-p "treesit.c")
(declare-function treesit-node-at "treesit.c")
(declare-function treesit-forward-sentence "treesit.c")
(declare-function evil-visual-state-p "evil-states")

(defun haskell-ts-sexp (node)
  "Return non-nil when NODE is a sexp for `forward-sexp'/`backward-sexp'.
The whole-buffer root (`haskell') and the top-level `declarations'
wrapper are excluded: were either a sexp, `forward-sexp' from column
0 of a top-level binding would take the whole run of declarations as
one sexp and jump to the end of the buffer (and `backward-sexp' from
the last binding's end to the start), rather than stepping over one
binding.  A `let'/`where' block's `local_binds' wrapper is excluded
for the same reason: when the block's own bindings start on a new
line (`where' with nothing after it on its line, then each binding
indented below), the leading newline and indentation belong to the
`where'/`let' keyword rather than to `local_binds', so `local_binds'
starts exactly where its first binding does -- the same alignment
that makes `declarations' get picked as the coarse sexp from column 0.
An inline layout (`where a = 1' on one line) does not hit this: the
space between the keyword and the first binding is part of
`local_binds', so its start precedes the first binding's.  Excluding
`local_binds' unconditionally leaves that layout's motion unchanged,
since a nested run is already bounded by its enclosing binding either
way."
  (let ((node-text (treesit-node-text node 1)))
    (and
     (not (member (treesit-node-type node)
                  '("haskell" "declarations" "local_binds")))
     (not (member node-text '( "{" "}" "[" "]" "(" ")" ";")))
     (not (and (string= "operator" (treesit-node-field-name node))
               (= 1 (length node-text)))))))

(defun haskell-ts--sexp-at-end (pos)
  "Return the start of the `sexp' thing whose end is exactly POS, or nil.
Used by `haskell-ts--forward-sexp' in preference to `treesit-thing-prev'
whenever it applies, since the latter gets POS wrong in two related
ways -- see below.  Find it by looking at the node just *before* POS
and walking up through its ancestors for as long as they both match
`sexp' and still end exactly at POS, stopping at (and returning) the
last one before that no longer holds.

`treesit-parent-while', not `treesit-node-top-level' (which
`treesit-thing-prev' uses internally), is what this needs: for a
`where'/`let' block's last local binding, its `local_binds' wrapper is
excluded from `sexp' (see `haskell-ts-sexp') but nonetheless ends at
the same POS, and so -- one level further up still -- does the
enclosing top-level binding, whenever the block is the last content of
either (its own binding, or, when it is itself the file's last
top-level binding, the file).  `treesit-node-top-level' does not stop
at the first non-matching ancestor; it keeps climbing in case a higher
one matches again, which here wrongly latches onto that enclosing
binding instead of the local one -- `treesit-thing-prev''s bug, not
just this package's exclusion of `local_binds' from `sexp'.  Two
distinct symptoms follow, both fixed by using this function's answer
instead: with POS also at the exact end of the buffer, `treesit-node-at'
resolves to the enclosing `declarations'/`local_binds' node rather
than to the binding that actually ends there (the same half-open-range
situation `haskell-ts--text-node-at' already works around for `text'
nodes, one level up the tree), and `treesit-thing-prev' cannot step
backward from it at all, so `backward-sexp' does not move; with more
buffer content following POS instead, `treesit-node-at' resolves fine,
but `treesit-thing-prev' still climbs past `local_binds' to the
enclosing binding, so `backward-sexp' moves too far.  `treesit-parent-while'
stops at the first ancestor that fails, i.e., at `local_binds' --
returning the local binding itself, the last node examined before
that."
  (when (> pos (point-min))
    (let* ((leaf (treesit-node-at (1- pos)))
           (node (and leaf
                      (treesit-parent-while
                       leaf
                       (lambda (n) (and (treesit-node-match-p n 'sexp t)
                                        (<= (treesit-node-end n) pos)))))))
      (and node (= (treesit-node-end node) pos) (treesit-node-start node)))))

(defun haskell-ts--forward-sexp (arg)
  "`forward-sexp-function' for `haskell-ts-mode'.
Delegates to `treesit-forward-sexp', except when ARG is -1 (a plain
`backward-sexp') and point sits exactly at the end of some `sexp'
thing: `haskell-ts--sexp-at-end' then gives the destination directly,
in preference to whatever `treesit-forward-sexp' produces, since the
latter can otherwise stall or overshoot into an enclosing binding --
see that function's docstring.  Left unfixed for other ARG values,
e.g. a repeat count that reaches such a position partway through (see
TODO.org)."
  (setq arg (or arg 1))
  (let ((dest (and (= arg -1) (haskell-ts--sexp-at-end (point)))))
    (if dest
        (goto-char dest)
      (treesit-forward-sexp arg))))

(defun haskell-ts--text-node-parent (node)
  "Resolve NODE to its enclosing `comment'/`haddock' node, or return NODE.
A `comment'/`haddock' node is compound, with a `marker' and (unless
the comment is empty) a `content' child; `treesit-node-at' returns
the innermost node touching a position, which for a position inside a
comment is one of those children rather than the comment/haddock node
itself.  Callers that test a node's own type against `text' (which
matches `comment'/`haddock'/`string', not `marker'/`content') need
the parent instead."
  (if (and node (member (treesit-node-type node) '("marker" "content")))
      (treesit-node-parent node)
    node))

(defun haskell-ts--text-node-at (pos)
  "Return the `text' node touching POS, or nil.
`treesit-node-at' uses a half-open range, so a node's own end
position resolves to whatever follows it (typically an enclosing
node) rather than to the node itself.  Callers that land exactly on
that boundary -- as `bounds-of-thing-at-point' does when it moves
forward to find a thing's end -- would otherwise see POS as \"not
text\" and fall through to `treesit-forward-sentence''s AST-based
`sentence' thing.  That thing only matches `match' nodes (function
equations); a file with no equation before POS (e.g. only bindings,
signatures and comments) has no such node to stop at, so the search
runs all the way to the start of the buffer.

`treesit-node-at' returns the first node after POS when POS sits in
whitespace covered by no node -- e.g. a blank line above a comment --
rather than nil; the first branch below must reject such a node
itself, since it starts after POS rather than at or before it.  It
also returns the *previous* node when POS sits in whitespace covered
by no node and nothing follows to fall forward to -- e.g. a blank
line below a buffer-final comment -- so the first branch must also
reject a node that ends at or before POS."
  (or (let ((node (haskell-ts--text-node-parent (treesit-node-at pos))))
        (and node (<= (treesit-node-start node) pos)
             (< pos (treesit-node-end node))
             (treesit-node-match-p node 'text t) node))
      (let ((node (haskell-ts--text-node-parent
                   (and (> pos (point-min)) (treesit-node-at (1- pos))))))
        (and node (= (treesit-node-end node) pos)
             (treesit-node-match-p node 'text t)
             node))))

(defun haskell-ts--comment-continuation-prefix (pos)
  "Return the text that continues the `--' comment at POS on a new line.
The result is POS's line's leading whitespace, followed by the
comment marker's leading dashes and a single space -- e.g. \"-- \" or,
for an indented Haddock comment \"    -- | ...\", \"    -- \" (the `|'
sigil is not repeated).  Return nil if POS is not inside a `--'
comment (plain or Haddock): a block comment (marker `{-') and a
string both count as `text' too, but neither has a marker starting
with `--'."
  (let* ((node (haskell-ts--text-node-at pos))
         (marker (and node (treesit-node-child-by-field-name node "marker")))
         (marker-text (and marker (treesit-node-text marker t))))
    (when (and marker-text (string-prefix-p "--" marker-text))
      (save-excursion
        (goto-char (treesit-node-start marker))
        (concat (buffer-substring-no-properties (line-beginning-position) (point))
                (progn (string-match "\\`-+" marker-text)
                       (match-string 0 marker-text))
                " ")))))

(defun haskell-ts--comment-line-segments (content)
  "Return CONTENT's per-line prose ranges, continuation markers stripped.
A multi-line `--'/Haddock comment is one CONTENT node spanning every
line: only the first line's marker is its own `marker' field, and
every line after that repeats the marker as ordinary CONTENT text.
Left in, a marker-only line does not read as blank to prose paragraph
detection (so a paragraph break inside a comment is missed), and a
continuation line's marker ends up inside whatever sentence spans
into it.  Stripping it here, before `haskell-ts--forward-sentence'
runs paragraph/sentence detection on the dedented result, fixes both."
  (save-excursion
    (let ((end (treesit-node-end content))
          (pos (progn
                 (goto-char (treesit-node-start content))
                 (skip-chars-forward " \t")
                 (point)))
          segments)
      (while (<= pos end)
        (let ((line-end (min end (progn (goto-char pos) (line-end-position)))))
          (push (cons pos line-end) segments)
          (setq pos (1+ line-end))
          (when (<= pos end)
            (goto-char pos)
            (when (looking-at "[ \t]*--+")
              (goto-char (match-end 0))
              (skip-chars-forward " \t")
              (setq pos (point))))))
      (nreverse segments))))

(defun haskell-ts--text-node-segments (node)
  "Return NODE's prose text as a list of (START . END) buffer ranges.
For a `--'/Haddock comment, one range per physical line with each
continuation line's repeated marker stripped, via
`haskell-ts--comment-line-segments'.  For a `{- -}' block comment, a
single range with the closing `-}' trimmed off -- the grammar folds
it into CONTENT rather than giving it a field of its own.  For a
string, a single range with the surrounding quotes stripped, so its
interior reads as prose the same way a `--' marker is stripped above.
For an empty (marker-only) comment with no CONTENT child at all, the
node's own bounds."
  (let* ((content (treesit-node-child-by-field-name node "content"))
         (marker (treesit-node-child-by-field-name node "marker"))
         (marker-text (and marker (treesit-node-text marker t))))
    (cond
     ((and content marker-text (string-prefix-p "--" marker-text))
      (haskell-ts--comment-line-segments content))
     (content
      (let ((start (save-excursion
                     (goto-char (treesit-node-start content))
                     (skip-chars-forward " \t")
                     (point)))
            (end (- (treesit-node-end content) 2)))
        (list (cons start (max start end)))))
     ((equal (treesit-node-type node) "string")
      (let ((start (1+ (treesit-node-start node)))
            (end (1- (treesit-node-end node))))
        (list (cons start (max start end)))))
     (t
      (list (cons (treesit-node-start node) (treesit-node-end node)))))))

(defun haskell-ts--virtual-text-and-table (segments)
  "Return (VTEXT . TABLE) standing in for SEGMENTS' real buffer text.
VTEXT is SEGMENTS' text joined by newlines: with continuation markers
already stripped by `haskell-ts--text-node-segments', a marker-only
line becomes a blank line in VTEXT, i.e. an ordinary paragraph
separator once `haskell-ts--forward-sentence' runs prose motion on it
in a scratch buffer.  TABLE is a list of (RSTART REND VSTART) triples,
one per segment, giving the real buffer range and where it begins in
VTEXT; `haskell-ts--real-to-virtual'/`haskell-ts--virtual-to-real' use
it to translate points between the two."
  (let ((vstart 1) parts table)
    (dolist (seg segments)
      (let* ((rstart (car seg)) (rend (cdr seg))
             (text (buffer-substring-no-properties rstart rend)))
        (push text parts)
        (push (list rstart rend vstart) table)
        (setq vstart (+ vstart (length text) 1))))
    (cons (mapconcat #'identity (nreverse parts) "\n") (nreverse table))))

(defun haskell-ts--real-to-virtual (pos table)
  "Map real buffer POS to a point in the virtual text described by TABLE.
Return (VPOINT . ON-MARKERP).  ON-MARKERP is non-nil when POS sits on
a stripped marker -- the node's own opening marker (POS before the
first segment) or a continuation line's repeated one (POS between two
segments) -- in which case VPOINT is clamped forward to the marker's
following segment, since the marker itself has no counterpart in the
virtual text at all."
  (catch 'done
    (dolist (entry table)
      (let ((rstart (nth 0 entry)) (rend (nth 1 entry)) (vstart (nth 2 entry)))
        (cond
         ((and (<= rstart pos) (<= pos rend))
          (throw 'done (cons (+ vstart (- pos rstart)) nil)))
         ((< pos rstart)
          (throw 'done (cons vstart t))))))
    (let* ((last (car (last table)))
           (vstart (nth 2 last)))
      (cons (+ vstart (- (nth 1 last) (nth 0 last))) nil))))

(defun haskell-ts--virtual-to-real (vpoint table)
  "Inverse of `haskell-ts--real-to-virtual': map VPOINT back via TABLE.
Every point in the virtual text maps to some segment: TABLE's entries
are built back to back with exactly one joining newline between them,
so consecutive segments' virtual ranges never touch or overlap."
  (catch 'done
    (dolist (entry table)
      (let* ((rstart (nth 0 entry)) (rend (nth 1 entry)) (vstart (nth 2 entry))
             (vend (+ vstart (- rend rstart))))
        (when (<= vstart vpoint vend)
          (throw 'done (+ rstart (- vpoint vstart))))))))

(defconst haskell-ts--comment-node-regexp (regexp-opt '("comment" "haddock"))
  "Regexp matching the tree-sitter node types of a Haskell comment.")

(cl-defstruct (haskell-ts--region
               (:constructor haskell-ts--make-region)
               (:copier nil))
  "A syntactic region of the buffer: its KIND, buffer bounds and node.
KIND is one of `code', `comment', `haddock' or `string'.  BEG and END
are buffer positions delimiting the region.  NODE is the enclosing
`text' node for a comment/string region (its stripped-marker prose
segments back marker-aware deletion) and nil for `code'.  This is the
single classification `haskell-ts--region-at' returns; the
prose/paragraph helpers are being migrated onto it as their one source
of truth for \"what region is point in, and where are its bounds\" --
see the file Commentary and TODO.org's navigation-refactor item."
  kind beg end node)

(defun haskell-ts--code-region-edge (pos dir)
  "Return the code region's edge from POS in DIR (+1 forward, -1 back).
Forward: the end of the code line just above the nearest own-line
comment below POS.  Backward: the start of the code line just below
the nearest own-line comment above POS.  An inline trailing comment or
a `string' node is part of code, not a boundary, so the search skips
past it and keeps looking for an own-line comment.  When none bounds
that side -- no own-line comment at all, or the computed edge falls on
the wrong side of POS (as on a blank line between two comments, where
`treesit-node-at' resolves to the following node) -- the buffer edge
\(`point-max'/`point-min') is returned instead.

This is the code arm of `haskell-ts--region-at'.  It supersedes
`haskell-ts--adjacent-comment-edge', which stopped at the *first*
comment in DIR and yielded no bound when that comment was inline;
continuing past an inline comment to a later own-line one is a
deliberate behaviour change for that corner -- see
`haskell-ts-test-sentence-code-continues-past-inline-comment'."
  (save-excursion
    (let ((node (treesit-node-at pos))
          (back (< dir 0))
          (edge nil))
      (while (and node (not edge)
                  (setq node (treesit-search-forward
                              node haskell-ts--comment-node-regexp back)))
        (goto-char (treesit-node-start node))
        (when (bolp)                    ; own-line comment: a region bound
          (setq edge (if (> dir 0)
                         (and (not (bobp)) (1- (treesit-node-start node)))
                       (goto-char (treesit-node-end node))
                       (unless (bolp) (forward-line 1))
                       (point)))))
      (if (and edge (if (> dir 0) (> edge pos) (< edge pos)))
          edge
        (if (> dir 0) (point-max) (point-min))))))

(defun haskell-ts--region-at (pos)
  "Return the `haskell-ts--region' enclosing POS.
When POS is at or inside a `comment'/`haddock'/`string' `text' node
\(via `haskell-ts--text-node-at'), the region is that node: KIND names
which of the three it is, and BEG/END are its bounds.  Otherwise POS
is in code -- KIND is `code' and the region spans from the nearest
own-line comment above to the nearest one below, or the buffer edges
\(`haskell-ts--code-region-edge').  An inline trailing comment or an
in-line string literal is part of code, not a boundary.

Intentionally pure: it computes and returns, moving neither point nor
match data.  Blank lines that subdivide a code region into paragraphs
are deliberately *not* boundaries here -- that is prose analysis, left
to the sentence/paragraph layer, which intersects its blank-line limit
with this region's bound."
  (let ((node (haskell-ts--text-node-at pos)))
    (if node
        (haskell-ts--make-region
         :kind (pcase (treesit-node-type node)
                 ("string" 'string)
                 ("haddock" 'haddock)
                 (_ 'comment))
         :beg (treesit-node-start node)
         :end (treesit-node-end node)
         :node node)
      (haskell-ts--make-region
       :kind 'code
       :beg (haskell-ts--code-region-edge pos -1)
       :end (haskell-ts--code-region-edge pos 1)))))

(defun haskell-ts--code-blank-line-limit (dir)
  "Return the current code paragraph's blank-line boundary in direction DIR.
DIR is +1 (forward: the end of the last line before the next blank
one) or -1 (backward: the start of the first line after the previous
blank one).  A run of consecutive non-blank lines is one paragraph."
  (save-excursion
    (if (> dir 0)
        (let ((bound (line-end-position)))
          (while (and (zerop (forward-line 1))
                      (not (looking-at-p paragraph-separate)))
            (setq bound (line-end-position)))
          bound)
      (beginning-of-line)
      (let ((bound (point)))
        (while (and (zerop (forward-line -1))
                    (not (looking-at-p paragraph-separate)))
          (setq bound (point)))
        bound))))

(defun haskell-ts--code-paragraph-limit (dir)
  "Return the current code paragraph's boundary in direction DIR.
The nearer of the blank-line boundary (`haskell-ts--code-blank-line-limit')
and the code region's glued-comment/buffer edge
\(`haskell-ts--code-region-edge'): a code sentence must not cross either."
  (let ((blank (haskell-ts--code-blank-line-limit dir))
        (region (haskell-ts--code-region-edge (point) dir)))
    (if (> dir 0) (min blank region) (max blank region))))

(defun haskell-ts--forward-sentence (&optional arg)
  "`forward-sentence-function' for `haskell-ts-mode'.
Move point by ARG sentences (`forward-sentence-default-function''s
convention: negative for backward).  A thin wrapper over
`haskell-ts--prose-bounds': each step goes to the sentence bound it
reports for point -- END forward, BEG backward.

That primitive is the single source of truth for where a sentence
begins and ends, and dispatches on the region at point.  In code it
steps by `treesit-forward-sentence' (function equations) confined to
the current paragraph, so a code \"sentence\" -- and thus `evil''s `a s'
-- cannot run past a blank line or a glued comment into the next
paragraph.  Inside a `text' node (a comment or string) prose motion
runs over a dedented copy of the node's text with continuation markers
stripped, then maps back, so a comment's first sentence excludes its
`--' marker and reaching the node's first/last sentence stops at that
boundary rather than spilling into surrounding code.  See
`haskell-ts--prose-bounds' and the two step helpers under it.

The bounds are point-only: a sentence that itself spans a comment
continuation line still *contains* that line's repeated marker in the
real buffer between the two points, so preserving it across a deletion
is handled separately (`haskell-ts--marker-aware-delete'), not here."
  (setq arg (or arg 1))
  (let ((dir (if (< arg 0) -1 1)))
    (dotimes (_ (abs arg))
      (let ((bounds (haskell-ts--prose-bounds (point) 'sentence)))
        (goto-char (if (> dir 0) (cdr bounds) (car bounds)))))))

(defun haskell-ts--comment-sentence-step (node pos dir)
  "Return where a single prose sentence step from POS lands, toward DIR.
NODE is the `text' node (a `--'/Haddock/block comment or a string)
enclosing POS.  Reproduces one step of `haskell-ts--forward-sentence''s
motion in a scratch buffer: normalize NODE (strip markers, per
`haskell-ts--text-node-segments'), map POS into that copy, run stock
`forward-sentence-default-function' there, and map the result back.  A
backward step from a stripped marker does not move -- there is no
prose before it -- matching that command's own guard."
  (let* ((segments (haskell-ts--text-node-segments node))
         (text-and-table (haskell-ts--virtual-text-and-table segments))
         (vtext (car text-and-table))
         (table (cdr text-and-table))
         (loc (haskell-ts--real-to-virtual pos table)))
    (if (and (< dir 0) (cdr loc))
        pos
      (let ((vpoint (car loc)))
        (with-temp-buffer
          (setq-local sentence-end-double-space nil)
          (insert vtext)
          (goto-char vpoint)
          ;; As in `haskell-ts--forward-sentence': the virtual text's edge
          ;; is the node boundary, not the real buffer's, so its
          ;; buffer-edge signal is caught rather than propagated.
          (condition-case nil
              (forward-sentence-default-function dir)
            ((beginning-of-buffer end-of-buffer) nil))
          (setq vpoint (point)))
        (haskell-ts--virtual-to-real vpoint table)))))

(defun haskell-ts--code-sentence-step (pos dir)
  "Return where a single code sentence step from POS lands, toward DIR.
Step by `treesit-forward-sentence' (function equations) clamped to the
current paragraph (`haskell-ts--code-paragraph-limit'), falling back to
`forward-sentence-default-function' only when the clamp alone would
leave point put -- treesit found no equation to move to, or point
already sits at the paragraph boundary.  The paragraph clamp is used
rather than plain `forward-sentence-default-function' so that, with
`sentence-end-double-space' nil, a period inside a string literal does
not split an equation."
  (save-excursion
    (goto-char pos)
    (let* ((step (if (< dir 0) -1 1))
           (start (point))
           (limit (haskell-ts--code-paragraph-limit step))
           (ts (save-excursion (treesit-forward-sentence step) (point)))
           (moved (if (> step 0) (> ts start) (< ts start)))
           (res (if (> step 0)
                    (min (if moved ts limit) limit)
                  (max (if moved ts limit) limit))))
      (when (= res start)               ; nothing left in this paragraph
        (setq res (save-excursion
                    (condition-case nil
                        (forward-sentence-default-function step)
                      ((beginning-of-buffer end-of-buffer) nil))
                    (point))))
      res)))

(defun haskell-ts--sentence-step (pos dir)
  "Return where a single sentence step from POS lands, toward DIR.
Dispatches on the region at POS: prose inside a `text' node
\(`haskell-ts--comment-sentence-step') or code
\(`haskell-ts--code-sentence-step'), the same split
`haskell-ts--forward-sentence' makes on `haskell-ts--text-node-at'."
  (let ((node (haskell-ts--text-node-at pos)))
    (if node
        (haskell-ts--comment-sentence-step node pos dir)
      (haskell-ts--code-sentence-step pos dir))))

(defun haskell-ts--paragraph-edge (region pos dir)
  "Return REGION's paragraph confinement edge at POS toward DIR.
DIR is +1 (forward) or -1 (backward).  The result is where paragraph
motion must be confined so it does not cross the comment/code boundary
that plain `forward-paragraph'/`start-of-paragraph-text' cannot see --
or the buffer edge (`point-max'/`point-min') when no such boundary
applies on that side, meaning \"no confinement needed, ordinary motion
already stops on its own.\"  So callers narrow or clamp to the returned
point uniformly, glued or not.

For a code REGION, the glued comment edge (`haskell-ts--code-region-edge')
when a comment is glued to the code paragraph -- it bounds the region
short of the buffer edge and is the nearer of the two against the
blank-line limit (`haskell-ts--code-blank-line-limit') -- else the
buffer edge.  For a comment/string REGION, the node's own glued edge
when it abuts a non-separator line: forward, one past `region' END
\(`forward-paragraph' stops one line below a paragraph's last line, and
a comment node excludes its trailing newline, so its own END would
leave point at the last character with nothing beyond to move into --
which `evil-select-an-object' reads as \"already past the object\");
backward, `region' BEG itself (a paragraph's start needs no offset).

Not applying `save-match-data' here: `haskell-ts--prose-bounds' and the
paragraph consumers do not rely on match data across the call."
  (let ((buffer-edge (if (> dir 0) (point-max) (point-min))))
    (if (eq (haskell-ts--region-kind region) 'code)
        (save-excursion
          (goto-char pos)
          (let ((edge (haskell-ts--code-region-edge pos dir))
                (blank (haskell-ts--code-blank-line-limit dir)))
            (if (and (if (> dir 0) (< edge buffer-edge) (> edge buffer-edge))
                     (if (> dir 0) (<= edge blank) (>= edge blank)))
                edge
              buffer-edge)))
      (let* ((node-edge (if (> dir 0) (haskell-ts--region-end region)
                          (haskell-ts--region-beg region)))
             (glued (save-excursion
                      (goto-char node-edge)
                      (and (not (if (> dir 0) (eobp) (bobp)))
                           (progn (forward-line dir)
                                  (not (looking-at-p paragraph-separate)))))))
        (if glued (if (> dir 0) (1+ node-edge) node-edge) buffer-edge)))))

(defun haskell-ts--prose-bounds (pos unit)
  "Return (BEG . END), the bounds of the UNIT enclosing POS.
UNIT is `sentence' or `paragraph'.  BEG and END are computed
independently by stepping backward and forward from POS -- never by
chaining one from the other's result, which can land on a comment
node's end boundary where `treesit-node-at' misresolves (see
`haskell-ts-tests--sentence-at-point').  Motion picks the end for its
direction: forward uses END, backward uses BEG.

For `sentence', prose inside a `text' node runs over a dedented copy
of the node's text and code steps by `treesit-forward-sentence' (see
the step helpers above).  For `paragraph', the bounds are the region's
confinement edges (`haskell-ts--paragraph-edge'): stock paragraph
motion already sees blank lines and -- via the mode's extended
`paragraph-separate' -- a `--'-only line inside a comment, so a
paragraph unit needs only the outer comment/code (or buffer) boundary,
not the normalize-and-map engine the sentence unit uses.

This is the single bounds primitive sentence and paragraph motion run
on; the sentence text-object and marker-aware deletion paths are being
rebuilt on it too -- see the file Commentary and TODO.org's
navigation-refactor item.  It is pure: it computes and returns, moving
neither point nor match data."
  (pcase unit
    ('sentence (cons (haskell-ts--sentence-step pos -1)
                     (haskell-ts--sentence-step pos 1)))
    ('paragraph (let ((region (haskell-ts--region-at pos)))
                  (cons (haskell-ts--paragraph-edge region pos -1)
                        (haskell-ts--paragraph-edge region pos 1))))
    (_ (error "Unsupported `haskell-ts--prose-bounds' unit: %S" unit))))

(defvar haskell-ts-thing-settings
  `((haskell
     (sexp haskell-ts-sexp)
     (sentence "match")
     (text ,(regexp-opt '("comment" "haddock" "string")))))
  "`treesit-thing-settings' for `haskell-ts-mode'.
`text' must include `comment' and `haddock' (not just `string'), or
`haskell-ts--forward-sentence' treats point inside a comment as
\"inside code\" and jumps by the `sentence' thing (a `match' node)
instead of by prose sentence, spilling into surrounding code.")

(defvar haskell-ts--confining-evil-paragraph-object nil
  "Non-nil while `haskell-ts--confine-evil-paragraph-object' runs.
Suppresses `haskell-ts--confine-paragraph-motion''s own, separate
clamp for the duration: `bounds-of-thing-at-point' and `evil''s
whitespace-detection helpers re-probe with `forward-paragraph'/
`start-of-paragraph-text' from intermediate positions found *during*
the very computation of an object's bounds -- e.g. the buffer's very
first comment, visited while computing the bounds of an unrelated
paragraph elsewhere -- which need not have anything to do with where
the object being computed actually starts.  Clamping those to
whatever node they happen to land in mid-probe breaks the invariant
`evil' relies on, that `forward-paragraph' started from any point
within an object's bounds reaches the same end: some probes would be
clamped and others not, depending only on which position they
happened to (re)start from.  `haskell-ts--confine-evil-paragraph-object'
already narrows the buffer once for the whole call, based on the
object's actual start, which is the correct level to confine at; with
that in effect, every probe naturally stays consistent no matter
where it (re)starts from, and this per-call clamp would only add back
the same inconsistency it narrowed to avoid.")

(defun haskell-ts--confine-paragraph-motion (orig-fun args dir)
  "Run ORIG-FUN, then clamp point to the `text' region enclosing the start.
DIR is the motion's direction: positive for `forward-paragraph',
negative for `start-of-paragraph-text' (always backward).  Clamps to
the paragraph edge `haskell-ts--prose-bounds' reports for the region
at point in DIR, which is a real clamp only when that boundary is
glued to code with no blank line of its own to stop at; otherwise it
is `point-max'/`point-min', making the clamp a no-op.  Clamping short
of a real blank (or `--'-only) line would be actively wrong -- it
would short-circuit the round trip `evil' uses (moving forward then
back, or vice versa) to detect whitespace *beyond* the node, e.g.
between two comments separated by a blank line, mistaking \"clamped, so
no progress\" for \"nothing further to find\" and swallowing everything
up to `point-max'/`point-min' instead -- but the buffer-edge value on
a non-glued side avoids that by leaving ORIG-FUN's result untouched.
Only acts inside a comment/string region: code paragraph motion is
left to ORIG-FUN so `}'/`{' from code can cross a glued boundary onto
the blank line beyond.  Also stays out of the way while
`haskell-ts--confining-evil-paragraph-object' is non-nil, for the same
underlying reason -- see its docstring.
ORIG-FUN runs unmodified outside a comment/string, adding no behaviour
of its own there.  Returns ORIG-FUN's own result unchanged, even when
clamping, so callers that inspect it (e.g. `evil-motion-loop', via how
many paragraphs were *not* traversed) see the traversal ORIG-FUN
actually performed rather than the buffer position `goto-char' would
otherwise return.
ARGS are passed to ORIG-FUN unmodified."
  (let* ((region (and (not haskell-ts--confining-evil-paragraph-object)
                      (derived-mode-p 'haskell-ts-mode)
                      (haskell-ts--region-at (point))))
         (clamp (and region
                     (not (eq (haskell-ts--region-kind region) 'code))
                     (let ((bounds (haskell-ts--prose-bounds (point) 'paragraph)))
                       (if (> dir 0) (cdr bounds) (car bounds))))))
    (if (not clamp)
        (apply orig-fun args)
      (let ((result (apply orig-fun args)))
        (if (> dir 0)
            (goto-char (min (point) clamp))
          (goto-char (max (point) clamp)))
        result))))

(defun haskell-ts--confine-forward-paragraph (orig-fun &rest args)
  "Around advice for `forward-paragraph'.
ORIG-FUN and ARGS are passed on to `haskell-ts--confine-paragraph-motion'."
  (haskell-ts--confine-paragraph-motion orig-fun args (if (< (or (car args) 1) 0) -1 1)))

(defun haskell-ts--confine-start-of-paragraph-text (orig-fun &rest args)
  "Around advice for `start-of-paragraph-text'.
ORIG-FUN and ARGS are passed on to `haskell-ts--confine-paragraph-motion'.
Unlike `backward-paragraph' (a thin wrapper that calls
`forward-paragraph' with a negated count, and so needs no advice of
its own), `evil''s `}'/`{' (`evil-forward-paragraph'/
`evil-backward-paragraph') and `a p'/`i p' all reach the beginning of
a paragraph via `start-of-paragraph-text' directly."
  (haskell-ts--confine-paragraph-motion orig-fun args -1))

(advice-add 'forward-paragraph :around #'haskell-ts--confine-forward-paragraph)
(advice-add 'start-of-paragraph-text :around #'haskell-ts--confine-start-of-paragraph-text)

(defun haskell-ts--confine-evil-paragraph-in-node (orig-fun args &optional confine-code)
  "Run ORIG-FUN with ARGS narrowed to the region's paragraph bounds at point.
Shared by `haskell-ts--confine-evil-paragraph-object' (`a p'/`i p') and
`haskell-ts--confine-evil-paragraph-motion' (`}'/`{'): both need the
*whole* call narrowed to a `text' node glued to code, not merely each
individual `forward-paragraph'/`start-of-paragraph-text' call clamped
-- see `haskell-ts--confine-evil-paragraph-object''s docstring for why
clamping call by call is not enough.

With point in a `text' region the narrowing is to that node's glued
side(s), as above.  With CONFINE-CODE non-nil and point instead in
code, it is to the code paragraph's glued-comment boundaries, so a
paragraph text object in code does not spill into a comment glued to
it -- the comment/code boundary is a paragraph boundary in both
directions.  Either way the bounds come from
`haskell-ts--prose-bounds' UNIT `paragraph', which yields the buffer
edge on any side with no glued boundary, i.e. no real narrowing there.
`}'/`{' motions pass CONFINE-CODE nil: unlike the text object they are
cursor motions, free to move across that boundary onto the blank line
beyond, per plain paragraph motion (see
`haskell-ts-test-evil-backward-paragraph-from-code-unaffected').

Binds `haskell-ts--confining-evil-paragraph-object' for the whole
call, in a text region or not: bounds may end up computed via an
intermediate position far from where this call started (e.g. some
other, unrelated comment elsewhere in the buffer), and any node found
there must not trigger `haskell-ts--confine-paragraph-motion''s own
clamp -- see that variable's docstring for why."
  (let* ((haskell-ts--confining-evil-paragraph-object t)
         (in-text (not (eq (haskell-ts--region-kind (haskell-ts--region-at (point)))
                           'code))))
    (if (not (or in-text confine-code))
        (apply orig-fun args)
      ;; With CONFINE-CODE but no glued comment on either side, LO/HI are
      ;; point-min/max, i.e. no real narrowing -- harmless, identical to
      ;; running ORIG-FUN unnarrowed.
      (condition-case nil
          (let* ((bounds (haskell-ts--prose-bounds (point) 'paragraph))
                 (lo (car bounds)) (hi (cdr bounds)))
            (save-restriction
              (narrow-to-region lo hi)
              (apply orig-fun args)))
        ;; Point already sat at the narrowed edge (LO or HI), so
        ;; `evil-signal-at-bob-or-eob' -- run by `evil-forward-paragraph'/
        ;; `evil-backward-paragraph' before any motion, so nothing to
        ;; undo here -- mistook the node's edge for the real buffer's.
        ;; That is not "spilling past the comment" (point was never
        ;; going to move *within* it); fall back to ORIG-FUN unnarrowed,
        ;; which signals for real only if LO/HI also happen to be the
        ;; real buffer edges.
        ((beginning-of-buffer end-of-buffer)
         (apply orig-fun args))))))

(defun haskell-ts--confine-evil-paragraph-object (orig-fun thing &rest args)
  "Around advice for `evil-select-an-object'/`evil-select-inner-object'.
Only `a p'/`i p' (THING `evil-paragraph') are handled; every other
text object runs ORIG-FUN unmodified.

Clamping each individual `forward-paragraph'/`start-of-paragraph-text'
call, as `haskell-ts--confine-paragraph-motion' does, is not enough
for these two: to detect whitespace *beyond* the current paragraph,
`evil' moves forward then back (or vice versa) and compares against
the starting point, falling back to `point-max'/`point-min' when the
round trip does not return further out than where it started -- which
is also what happens when a clamped call is stopped short by a glued
node boundary instead of a real one, and unlike at a genuine buffer
edge, `point-max'/`point-min' there is the wrong fallback: it is the
real buffer's, not the node's.  Narrowing to the glued side(s) of the
enclosing node for the whole call, rather than clamping call by call,
fixes this at the source: within the narrowing, `point-max'/`point-min'
*are* the node's boundary, so the fallback is correct either way.
`haskell-ts--confine-evil-paragraph-in-node' does the narrowing.

Passes CONFINE-CODE non-nil so that `a p'/`i p' from *code* glued to a
comment is likewise confined to the code side of that boundary, not
just from *inside* a comment -- otherwise the object spills up (or
down) into the neighbouring comment paragraph."
  (if (not (and (derived-mode-p 'haskell-ts-mode) (eq thing 'evil-paragraph)))
      (apply orig-fun thing args)
    (haskell-ts--confine-evil-paragraph-in-node orig-fun (cons thing args) t)))

(defun haskell-ts--confine-evil-paragraph-motion (orig-fun &rest args)
  "Around advice for `evil-forward-paragraph'/`evil-backward-paragraph'.
These are the `}'/`{' motions.  ORIG-FUN and ARGS are the advised
function and its arguments.

Unlike `a p'/`i p', which reach `forward-paragraph'/
`start-of-paragraph-text' straight from point, these two commands
first nudge point onto the neighbouring line -- `evil-forward-paragraph'
via `evil-forward-end' stepping one character past the thing's end
before searching (so that starting already at the boundary still
counts as progress), `evil-backward-paragraph' via its own leading
`(forward-line)' before calling `evil-backward-beginning' -- and only
then hands off to `forward-paragraph'/`start-of-paragraph-text'.  When
point started inside a comment glued to code, that nudge alone can
land outside the node (on the glued code line itself), so
`haskell-ts--confine-paragraph-motion''s per-call clamp -- which only
intervenes when point is currently inside a `text' node -- never
triggers, and the motion then runs unconfined from code.  Narrowing
the buffer to the node at the *original* point for the whole call,
the same fix `haskell-ts--confine-evil-paragraph-object' applies to
the text objects, closes this: the nudge can no longer leave the
narrowed buffer."
  (if (not (derived-mode-p 'haskell-ts-mode))
      (apply orig-fun args)
    (haskell-ts--confine-evil-paragraph-in-node orig-fun args)))

(with-eval-after-load 'evil
  (advice-add 'evil-select-an-object :around #'haskell-ts--confine-evil-paragraph-object)
  (advice-add 'evil-select-inner-object :around #'haskell-ts--confine-evil-paragraph-object)
  (advice-add 'evil-forward-paragraph :around #'haskell-ts--confine-evil-paragraph-motion)
  (advice-add 'evil-backward-paragraph :around #'haskell-ts--confine-evil-paragraph-motion))

(defun haskell-ts--continuation-prefix ()
  "Return the `--' comment continuation prefix for point, or nil.
Non-nil only in a `haskell-ts-mode' buffer with point inside a `--'
comment; see `haskell-ts--comment-continuation-prefix'.  Shared by the
`newline' and Evil `o'/`O' advice below."
  (and (derived-mode-p 'haskell-ts-mode)
       (haskell-ts--comment-continuation-prefix (point))))

(defun haskell-ts--newline (orig-fun &rest args)
  "Continue a `--' comment when breaking the line inside one.
`RET' should continue a `--' comment rather than leave it, so
`newline' itself -- not a keymap binding -- is advised, which also
covers any other caller of `newline' (e.g. `open-line').  The
continuation is inserted directly, rather than by delegating to
`default-indent-new-line', because the latter's `delete-horizontal-space'
calls strip a bare marker's trailing space (a comment line with
nothing typed after it yet) before it can be repeated -- see
`haskell-ts--comment-continuation-prefix'.  `newline''s repeat count
\(ARGS' first element) is honoured, so each of the requested lines is
continued.  Outside such a comment, ORIG-FUN runs unchanged with ARGS,
adding no indentation behaviour of its own."
  (let ((prefix (haskell-ts--continuation-prefix)))
    (if prefix
        (dotimes (_ (prefix-numeric-value (car args)))
          (insert "\n" prefix))
      (apply orig-fun args))))

(advice-add 'newline :around #'haskell-ts--newline)

(defun haskell-ts--evil-continue-comment (orig-fun &rest args)
  "Continue a `--' comment for Evil's `o'/`O'.
`evil-insert-newline-above'/`evil-insert-newline-below' insert their
blank line with a plain `insert', bypassing `newline' -- and the
advice on it above -- entirely, so they need this advice of their own
to get the same comment continuation.  ORIG-FUN is called with ARGS
to insert that blank line before the prefix is added."
  (let ((prefix (haskell-ts--continuation-prefix)))
    (apply orig-fun args)
    (when prefix
      (insert prefix))))

(with-eval-after-load 'evil
  (advice-add 'evil-insert-newline-above :around #'haskell-ts--evil-continue-comment)
  (advice-add 'evil-insert-newline-below :around #'haskell-ts--evil-continue-comment))

(defvar haskell-ts--sentence-deletion-active nil
  "Non-nil while the current command's own region removal should be marker-aware.
Bound around `kill-sentence'/`backward-kill-sentence'
\(`haskell-ts--kill-sentence') and, for `evil', around a charwise
`evil-delete' call (`haskell-ts--evil-delete-marker-aware' -- this
also covers `evil-change', which calls `evil-delete' internally).
Left nil everywhere else, so ordinary `kill-region'/`delete-region'
callers -- `kill-line', a manual `C-w', `dd' -- take their usual,
unexamined path; `haskell-ts--marker-aware-delete' additionally
requires the region to actually straddle a stripped continuation
marker before it does anything, so even a same-line sentence kill
inside this dynamic extent still falls through to the normal
deletion.")

(defun haskell-ts--marker-aware-delete (start end kill)
  "Delete the region between START and END, preserving markers it spans.
Return non-nil if handled; nil if [START,END) is not entirely within
one prose region (a `--'/Haddock comment) or does not straddle one of
its continuation markers, in which case the caller must fall back to
its own ordinary deletion.

The region and its bounds come from `haskell-ts--region-at' -- the one
classifier for what syntactic region point is in -- and the pieces to
remove are that region's prose segments (`haskell-ts--text-node-segments',
the same stripped-marker ranges the sentence engine maps motion over)
intersected with [START,END).  The range straddles a continuation
marker exactly when that intersection yields more than one piece; only
those prose pieces -- never a stripped marker or its leading
whitespace -- are removed, so the newline and marker on any line the
deleted text continues onto survive, leaving that line a validly marked
comment line rather than merged into the one above.  When KILL is
non-nil, the removed pieces are joined with a newline (mirroring how
`haskell-ts--virtual-text-and-table' represents them) and pushed onto
the kill ring -- a plain `kill-new', not `kill-region''s
consecutive-kill append behaviour, since this path only runs for the
rare case of a kill straddling a marker."
  (when (> start end)
    (let ((tmp start)) (setq start end end tmp)))
  (let* ((region (haskell-ts--region-at start))
         (pieces nil))
    (when (and (not (eq (haskell-ts--region-kind region) 'code))
               (<= (haskell-ts--region-beg region) start)
               (<= end (haskell-ts--region-end region)))
      (dolist (seg (haskell-ts--text-node-segments (haskell-ts--region-node region)))
        (let ((s (max start (car seg))) (e (min end (cdr seg))))
          (when (< s e) (push (cons s e) pieces))))
      (setq pieces (nreverse pieces)))
    (when (> (length pieces) 1)
      (when kill
        (kill-new (mapconcat (lambda (p) (buffer-substring-no-properties (car p) (cdr p)))
                             pieces "\n")))
      (dolist (p (reverse pieces))
        (delete-region (car p) (cdr p)))
      t)))

(defun haskell-ts--kill-region-marker-aware (orig-fun beg end &rest args)
  "Around advice for `kill-region', used by `kill-sentence' and friends.
Delegates BEG and END to `haskell-ts--marker-aware-delete' while
`haskell-ts--sentence-deletion-active'; otherwise, or when that
function declines because the region does not straddle a marker,
ORIG-FUN runs on BEG, END and ARGS unchanged."
  (or (and haskell-ts--sentence-deletion-active
           (haskell-ts--marker-aware-delete beg end t))
      (apply orig-fun beg end args)))

(advice-add 'kill-region :around #'haskell-ts--kill-region-marker-aware)

(defun haskell-ts--kill-sentence (orig-fun &rest args)
  "Around advice for `kill-sentence'/`backward-kill-sentence'.
Both compute their endpoint via `forward-sentence' --
`haskell-ts--forward-sentence' in this mode -- then call `kill-region'
on point and that endpoint; binding `haskell-ts--sentence-deletion-active'
around the call to ORIG-FUN with ARGS lets the `kill-region' advice
above make that particular kill marker-aware."
  (if (derived-mode-p 'haskell-ts-mode)
      (let ((haskell-ts--sentence-deletion-active t))
        (apply orig-fun args))
    (apply orig-fun args)))

(advice-add 'kill-sentence :around #'haskell-ts--kill-sentence)
(advice-add 'backward-kill-sentence :around #'haskell-ts--kill-sentence)

(defun haskell-ts--delete-region-marker-aware (orig-fun beg end)
  "Around advice for `delete-region', which is used by `evil-delete'.
See `haskell-ts--kill-region-marker-aware', its `kill-region'
counterpart: delegates BEG and END the same way, falling back to
ORIG-FUN on BEG and END otherwise.

Installed only alongside the `evil-delete' advice below (under
`with-eval-after-load' `evil'), never for plain Emacs.
`haskell-ts--sentence-deletion-active' -- the gate this checks -- is
bound in only two places: `haskell-ts--kill-sentence', whose
`kill-region' path is served by the `kill-region' advice and never
reaches `delete-region' (`kill-region' deletes via
`delete-and-extract-region'), and `haskell-ts--evil-delete-marker-aware'.
So a non-`evil' session has no path that both sets the gate and calls
`delete-region', and advising this hot primitive globally there would
only add a per-call check that can never fire."
  (or (and haskell-ts--sentence-deletion-active
           (haskell-ts--marker-aware-delete beg end nil))
      (funcall orig-fun beg end)))

(defun haskell-ts--evil-delete-marker-aware (orig-fun beg end type &rest args)
  "Around advice for `evil-delete', called with BEG, END, TYPE and ARGS.
`d a s'/`d i s' (and `c a s'/`c i s', via `evil-change' calling
`evil-delete' internally) reach here with a charwise TYPE
\(`inclusive'/`exclusive'); binding `haskell-ts--sentence-deletion-active'
around the call to ORIG-FUN lets the `delete-region' advice above make
its own deletion marker-aware.  Left unbound for a linewise/block TYPE
\(`dd', a visual block delete, ...), where deleting a straddled marker
along with the rest of the line is exactly what is wanted.

Also left unbound for a delete issued from visual state (`v'-then-`x'/
`d'): there the region is exactly what the user selected and saw
highlighted, so it is removed verbatim -- marker included -- rather
than second-guessed.  Marker awareness is meant only for the sentence
*text objects* (`d a s' and friends, run from operator-pending, not
visual, state), whose range is computed by `haskell-ts--forward-sentence'
and can land past a continuation marker the user never pointed at."
  (if (and (derived-mode-p 'haskell-ts-mode)
           (memq type '(inclusive exclusive))
           (not (evil-visual-state-p)))
      (let ((haskell-ts--sentence-deletion-active t))
        (apply orig-fun beg end type args))
    (apply orig-fun beg end type args)))

(with-eval-after-load 'evil
  ;; `delete-region' is advised here, not globally: it is a hot editing
  ;; primitive, and the only path that both sets
  ;; `haskell-ts--sentence-deletion-active' and reaches it is
  ;; `evil-delete' -- see `haskell-ts--delete-region-marker-aware'.
  (advice-add 'delete-region :around #'haskell-ts--delete-region-marker-aware)
  (advice-add 'evil-delete :around #'haskell-ts--evil-delete-marker-aware))

(provide 'haskell-ts-navigation)

;;; haskell-ts-navigation.el ends here
