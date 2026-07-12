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

;;; Code:

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

(defun haskell-ts--adjacent-comment-edge (dir)
  "Return the code-side edge of the nearest own-line comment in DIR, or nil.
DIR is +1 (forward: the end of the code line just above the comment)
or -1 (backward: the start of the code line just below it).  Point is
assumed to be in code, not already inside a comment.  A comment on its
own line is a paragraph boundary even when glued directly to code with
no blank line between, which `forward-sentence-default-function' does
not see; the edge is line-based (like the blank-line boundary) so the
clamped sentence excludes the newline adjoining the comment.

Only a comment that begins a line qualifies: an inline trailing
comment (`f = x -- note') is part of its code line, not a paragraph
break, and `treesit-forward-sentence' already stops at the equation's
end before it.  Strings are excluded for the same reason -- inline
code, not prose."
  (let* ((node (treesit-node-at (point)))
         (found (and node (treesit-search-forward
                           node haskell-ts--comment-node-regexp (< dir 0)))))
    (when found
      (save-excursion
        (goto-char (treesit-node-start found))
        (when (bolp)                    ; own-line comment only
          (if (> dir 0)
              (and (not (bobp)) (1- (point)))
            (goto-char (treesit-node-end found))
            (unless (bolp) (forward-line 1))
            (point)))))))

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
and the nearest glued comment edge (`haskell-ts--adjacent-comment-edge'):
a code sentence must not cross either."
  (let ((blank (haskell-ts--code-blank-line-limit dir))
        (comment (haskell-ts--adjacent-comment-edge dir)))
    (if comment
        (if (> dir 0) (min blank comment) (max blank comment))
      blank)))

(defun haskell-ts--forward-sentence-in-code (arg)
  "Move point by ARG sentences in code, confined to the current paragraph.
`treesit-forward-sentence' treats a function equation (`match' node)
as a sentence and hunts for the next/previous one across any number of
blank lines and comments; on its own it lets a code \"sentence\" -- and
so `evil''s `a s' text object -- run from one paragraph clear into the
next (e.g. from a `data' declaration down past a blank line and a
comment into the following binding).  Each step is therefore clamped
to the current paragraph (`haskell-ts--code-paragraph-limit'): a run
of consecutive non-blank code lines, bounded by a blank line or a
comment glued to it, within which treesit's equation-level granularity
is kept.  (The paragraph limit is used rather than
`forward-sentence-default-function' so that, with
`sentence-end-double-space' nil, a period inside a string literal --
which that function would treat as a sentence end -- does not split an
equation.)  When the clamp alone would leave point put -- treesit
found no equation to move to, or point already sits at the paragraph
boundary -- `forward-sentence-default-function' is used to progress
into the next/previous paragraph instead of sticking."
  (let ((step (if (< arg 0) -1 1)))
    (dotimes (_ (abs arg))
      (let* ((start (point))
             (limit (haskell-ts--code-paragraph-limit step))
             (ts (save-excursion (treesit-forward-sentence step) (point)))
             (moved (if (> step 0) (> ts start) (< ts start)))
             (res (if (> step 0)
                      (min (if moved ts limit) limit)
                    (max (if moved ts limit) limit))))
        (when (= res start)             ; nothing left in this paragraph
          (setq res (save-excursion
                      (condition-case nil
                          (forward-sentence-default-function step)
                        (error nil))
                      (point))))
        (goto-char res)))))

(defun haskell-ts--forward-sentence (&optional arg)
  "`forward-sentence-function' for `haskell-ts-mode'.
Move point by ARG sentences (`forward-sentence-default-function''s
convention: negative for backward).  In code this steps by
`treesit-forward-sentence' (function equations) but stays within the
current paragraph, per `haskell-ts--forward-sentence-in-code'.  When
point is at or inside a `text' node (a comment or a string), prose
motion instead runs over a dedented copy of that node's text --
continuation markers stripped, per `haskell-ts--text-node-segments' --
in a scratch buffer, and the result is mapped back onto the real
buffer.

Two problems follow from running `forward-sentence-default-function'
on the raw buffer text instead.  It falls back to
`paragraph-start'/`paragraph-separate' to bound a sentence search when
it finds no sentence end, and `prog-mode' does not treat a comment
glued to code (no blank line above or below) as its own paragraph, so
motion overruns the comment; dedenting fixes this by making a
marker-only line -- meant to separate paragraphs within one multi-line
comment -- read as an actual blank line, which it is not in the real
buffer.  And a comment's marker is otherwise just text: left in, a
comment's first sentence starts at `--' itself.

Dedenting does *not*, however, stop a single sentence that itself
spans a continuation line from including that line's marker once
mapped back to the real buffer: motion only returns a point, and the
region between two such points is whatever real text sits between
them, markers included.  Avoiding that would mean teaching deletion
commands about markers, not sentence motion.

Prose motion runs over the node's text alone, so reaching the node's
first/last sentence and moving again stops at that boundary rather
than continuing into surrounding code (the buffer-edge signal from
the scratch buffer is caught, not propagated).  This keeps text
objects such as `evil''s `d a s' bounded to the comment; letting
plain motion fall through into code is a separate, riskier change
tracked in TODO.org."
  (setq arg (or arg 1))
  (let ((node (haskell-ts--text-node-at (point))))
    (if (not node)
        (haskell-ts--forward-sentence-in-code arg)
      (let* ((segments (haskell-ts--text-node-segments node))
             (text-and-table (haskell-ts--virtual-text-and-table segments))
             (vtext (car text-and-table))
             (table (cdr text-and-table))
             (loc (haskell-ts--real-to-virtual (point) table)))
        (unless (and (< arg 0) (cdr loc))
          (let ((vpoint (car loc)))
            (with-temp-buffer
              (setq-local sentence-end-double-space nil)
              (insert vtext)
              (goto-char vpoint)
              ;; Prose motion signals `beginning-of-buffer'/`end-of-buffer'
              ;; at the virtual text's edge.  The real buffer usually
              ;; continues past the node (a comment glued to code, say),
              ;; so that signal must not escape -- stop at the node
              ;; boundary instead (see the docstring's boundary note).
              (condition-case nil
                  (forward-sentence-default-function arg)
                ((beginning-of-buffer end-of-buffer) nil))
              (setq vpoint (point)))
            (goto-char (haskell-ts--virtual-to-real vpoint table))))))))

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

(defun haskell-ts--node-glued-p (pos dir)
  "Non-nil if NODE's boundary at POS abuts real code, not a blank line.
DIR is the direction the boundary faces: positive for a node's end
\(check the line *after* it), negative for its start (check the line
*before* it).  Used to tell a comment glued directly to code -- no
blank line separating them, so `paragraph-start'/`paragraph-separate'
see nothing there to stop paragraph motion -- from one that already
has a real separating line, where they need no help."
  (save-excursion
    (goto-char pos)
    (if (if (> dir 0) (eobp) (bobp))
        nil
      (forward-line dir)
      (not (looking-at-p paragraph-separate)))))

(defun haskell-ts--node-forward-clamp (node)
  "Return where to stop forward paragraph motion confined to NODE, or nil.
Nil means NODE's end already borders a real separator line, needing
no clamp.  Otherwise this is one past `treesit-node-end', not
`treesit-node-end' itself: a comment node's own text excludes its
trailing newline, but `forward-paragraph' normally stops one line
*below* a paragraph's last line, having consumed that newline as part
of the paragraph -- clamping to the tighter, newline-excluded bound
left point sitting exactly at the comment's last character with
nothing beyond it to move into, which is indistinguishable, to code
like `evil-select-an-object' expecting the usual convention, from
already being past the object's end (see
`haskell-ts--confine-evil-paragraph-object')."
  (and (haskell-ts--node-glued-p (treesit-node-end node) 1)
       (1+ (treesit-node-end node))))

(defun haskell-ts--node-backward-clamp (node)
  "Return where to stop backward paragraph motion confined to NODE, or nil.
Nil means NODE's start already borders a real separator line, needing
no clamp; otherwise `treesit-node-start' itself -- unlike the forward
case, a paragraph's start is not offset by a newline."
  (and (haskell-ts--node-glued-p (treesit-node-start node) -1)
       (treesit-node-start node)))

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
  "Run ORIG-FUN, then clamp point to the `text' node enclosing the start.
DIR is the motion's direction: positive for `forward-paragraph',
negative for `start-of-paragraph-text' (always backward).  Only
intervenes when the relevant boundary is glued to code with no blank
line of its own to stop at (`haskell-ts--node-forward-clamp'/
`haskell-ts--node-backward-clamp' return non-nil); when a real blank
\(or `--'-only) line already borders the node, ORIG-FUN already stops
there unaided, and clamping would be actively wrong -- it would
short-circuit the round trip `evil' uses (moving forward then back,
or vice versa) to detect whitespace *beyond* the node, e.g. between
two comments separated by a blank line, mistaking \"clamped, so no
progress\" for \"nothing further to find\" and swallowing everything up
to `point-max'/`point-min' instead.  Also stays out of the way while
`haskell-ts--confining-evil-paragraph-object' is non-nil, for the same
underlying reason -- see its docstring.
ORIG-FUN runs unmodified outside a comment/string, or at one not
glued to code, adding no behaviour of its own there.  Returns
ORIG-FUN's own result unchanged, even when clamping, so callers that
inspect it (e.g. `evil-motion-loop', via how many paragraphs were
*not* traversed) see the traversal ORIG-FUN actually performed rather
than the buffer position `goto-char' would otherwise return.
ARGS are passed to ORIG-FUN unmodified."
  (let* ((node (and (not haskell-ts--confining-evil-paragraph-object)
                    (derived-mode-p 'haskell-ts-mode)
                    (haskell-ts--text-node-at (point))))
         (clamp (and node
                     (if (> dir 0)
                         (haskell-ts--node-forward-clamp node)
                       (haskell-ts--node-backward-clamp node)))))
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

Binds `haskell-ts--confining-evil-paragraph-object' for the whole
call, node found or not: the object's bounds may end up computed via
an intermediate position far from where this call started (e.g. some
other, unrelated comment elsewhere in the buffer), and any node found
there must not trigger `haskell-ts--confine-paragraph-motion''s own
clamp -- see that variable's docstring for why."
  (if (not (and (derived-mode-p 'haskell-ts-mode) (eq thing 'evil-paragraph)))
      (apply orig-fun thing args)
    (let ((haskell-ts--confining-evil-paragraph-object t)
          (node (haskell-ts--text-node-at (point))))
      (if (not node)
          (apply orig-fun thing args)
        (let ((lo (or (haskell-ts--node-backward-clamp node) (point-min)))
              (hi (or (haskell-ts--node-forward-clamp node) (point-max))))
          (save-restriction
            (narrow-to-region lo hi)
            (apply orig-fun thing args)))))))

(with-eval-after-load 'evil
  (advice-add 'evil-select-an-object :around #'haskell-ts--confine-evil-paragraph-object)
  (advice-add 'evil-select-inner-object :around #'haskell-ts--confine-evil-paragraph-object))

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

(provide 'haskell-ts-navigation)

;;; haskell-ts-navigation.el ends here
