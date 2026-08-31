# Upstream #17 "Add coloring for code inside haddock comments"

Source: <https://codeberg.org/pranshu/haskell-ts-mode/issues/17> (open,
Martinsos, 2025-01-25). Analysed 2026-08-31.

Priority: C — real payoff, but it adds a hand-written markup scanner to the one
part of the mode that currently has none. Closely related to
`2026-08-31 Upstream 8 literate haskell.md` — same mechanism, different wrapper.

## What the issue asks

Haddock has code blocks (`@ … @`), bird-track examples (`> …`) and REPL examples
(`>>> …` plus expected output). Today the whole thing is one flat
`font-lock-doc-face` blob. The issue concludes a Haddock tree-sitter grammar is a
prerequisite and parks the work there. **That conclusion no longer holds**, for
two reasons found on 2026-08-31:

1. Our grammar fork already splits a Haddock comment into `marker:` and
   `content:` fields, and `haskell-ts--text-node-segments` /
   `haskell-ts--comment-line-segments` (navigation.el) already return the
   per-line, **marker-stripped** buffer ranges of that content. The hard part of
   "find the prose, minus the `--`" is done and tested.
2. Emacs 30.2's `treesit-range-settings` accepts a *function* entry, called with
   START and END, free to call `treesit-parser-set-included-ranges` itself
   (verified from the variable's docstring on the installed Emacs). Disjoint
   ranges handed to one parser are parsed as one unit — casouri's advice in the
   #8 thread. So no host grammar is needed to embed Haskell inside comment text.

## Two levels of ambition — pick the first

**(a) Haddock markup faces, no Haskell parsing.** A fontification function
attached to the existing `(haddock)` capture walks the node's segments and
applies faces by regexp: code spans/blocks (`@ … @`, lines starting `> `/`>>> `),
plus the cheap markup (`'ident'`, `"Module"`, `[link]`, `/emphasis/`, `__bold__`,
section headings `= `/`== `, bullet lists). Code gets one dedicated, muted face
(`haskell-ts-haddock-code-face`, inheriting `font-lock-constant-face` or a
slightly toned variant of doc face) — Martinsos explicitly said full-strength
code coloring inside a comment would look wrong.

Cost: one function plus faces, no new parser, no range machinery, no grammar.
Risk: regexps over comment text, contained entirely inside a `haddock` node.

**(b) Real Haskell highlighting inside the code blocks.** Register a range-setting
function that computes marker-stripped ranges for `@ … @` / `> …` regions inside
`haddock` nodes and sets them as the included ranges of a second `haskell`
parser, then let the ordinary font-lock rules paint them.

Cost and risk are much higher: two parsers of the same language in one buffer,
`treesit-font-lock-settings` keyed by language (not by parser), the `comment`
feature running with `:override t` over the very ranges we just painted, and
incremental re-ranging on every edit inside a comment. Also, a code block in a
doc comment is frequently *not* parseable standalone (`>>> foo 1` followed by its
expected output line `2`, `spec`-style fragments), so error nodes are the normal
case, not the exception.

**Recommendation: do (a).** It delivers what the issue wants visually, at a
fraction of the cost, and does not perturb the parser setup that everything else
in the mode depends on. Revisit (b) only if (a) proves insufficient in daily use
— and if (b) is ever attempted, do #8 (literate) first, since it exercises the
same range machinery in a simpler setting (no host-comment nesting).

## Plan for (a)

1. New faces (align with `2026-08-31 Upstream 16 dedicated faces.md`, land that
   first): `haskell-ts-haddock-code-face` and one markup face — resist a face per
   markup kind; two is enough to start.
2. A `haskell-ts--fontify-haddock` function in the `comment` feature's rules,
   replacing the flat `(haddock) @font-lock-doc-face` capture with
   `(haddock) @haskell-ts--fontify-haddock`, which paints the base doc face then
   overlays code/markup spans. Reuse `haskell-ts--text-node-segments` for the
   marker-stripped ranges — do not re-derive comment structure (single source of
   truth); if that helper needs to move or be made public for use from
   `haskell-ts-mode.el`, do that as its own step.
3. Tests: probe buffers with `@…@`, a `> ` block, a `>>> ` example with output,
   and a plain paragraph, asserting the face at chosen offsets. Include a
   negative test that a `>` inside ordinary code is untouched.
4. Check the interaction with prose navigation: nothing in the sexp/prose layer
   reads faces, so this should be inert there — confirm by running the full suite,
   not by reasoning.
5. `CHANGELOG.org` + README (a line under the feature list).

## Also in this thread, but a different bug

dschrempf's comments (2025-04-11, 2025-09-03) report that Haskell is not
highlighted in `lsp-ui-doc` popups or `markdown-mode` code fences. That is
unrelated to Haddock parsing; it is tracked separately in
`2026-08-31 Upstream 17 highlighting in other buffers.md`.
