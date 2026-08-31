# No highlighting in `lsp-ui-doc` popups and `markdown-mode` code fences

Source: dschrempf's comments in
<https://codeberg.org/pranshu/haskell-ts-mode/issues/17> (2025-04-11 and
2025-09-03, the latter with a screenshot and the note "this warrants its own
issue"). Split out here because it has nothing to do with Haddock.

Priority: B — starts with a 15-minute experiment, and the likely fix is a README
recipe.

## Symptom

Haskell shown *inside another mode's buffer* is unhighlighted:

- `lsp-ui-doc` popups (e.g. with `(setopt lsp-ui-doc-include-signature t)`) —
  type signatures render plain.
- `markdown-mode` fenced code blocks tagged `haskell`, with
  `markdown-fontify-code-blocks-natively` on.

Reported as also affecting `java-ts-mode`
(<https://github.com/emacs-lsp/lsp-ui/issues/689>,
<https://github.com/jrblevin/markdown-mode/issues/824>), where installing the
non-ts `java-mode` is the known workaround — which points at *mode lookup*, not
at tree-sitter parsing.

## Hypotheses, in the order worth testing

1. **Mode lookup.** Both packages resolve a fence/doc language string to a major
   mode by interning `<lang>-mode`. `haskell-mode` is not defined here (the
   `derived-mode-add-parents` call declares a hierarchy, it does not define the
   function), so the lookup fails and the text stays plain. Recent
   `markdown-mode` also tries `<lang>-ts-mode` when the grammar is available;
   check the installed version's `markdown-get-lang-mode` before assuming.
2. **Fontification in a non-displayed buffer.** These packages fontify in a temp
   buffer and copy `face` properties back. Tree-sitter font lock needs the parser
   set up and `font-lock-ensure` to actually run; if the caller uses a
   `font-lock-fontify-buffer`/`jit-lock` path, or fontifies before
   `treesit-major-mode-setup` has run in that buffer, nothing lands.
3. **Property mismatch.** If the caller copies `font-lock-face` rather than
   `face`, treesit's `face` properties are dropped.

## Plan

1. Reproduce minimally, one at a time, and record which hypothesis holds:
   - markdown: `emacs -Q`, markdown-mode + this mode, a fenced `haskell` block,
     `markdown-fontify-code-blocks-natively` on; then inspect
     `(markdown-get-lang-mode "haskell")`.
   - lsp-ui: harder to isolate; approximate it by fontifying a Haskell string in
     a temp buffer the way `lsp-ui-doc--extract`/`lsp--fontlock-with-mode` does
     and checking whether `face` properties appear.
2. If hypothesis 1 holds — likely — the fix is **documentation**, not code: a
   README subsection showing
   `(add-to-list 'markdown-code-lang-modes '("haskell" . haskell-ts-mode))`
   and the equivalent for `lsp-ui`/`lsp-mode`. Do **not** define a `haskell-mode`
   alias in this package: it would shadow the real `haskell-mode` for anyone who
   has both, which is a much worse failure than a missing fence color.
3. If hypothesis 2 or 3 holds, the fix is upstream in `markdown-mode`/`lsp-ui`;
   file it there, and record the finding here with the repro so the next reader
   does not redo the bisect.

## Priority

Low code risk, decent user-visible payoff, and it is dschrempf's own itch. The
first step is a 15-minute experiment; do that before deciding it deserves more.
