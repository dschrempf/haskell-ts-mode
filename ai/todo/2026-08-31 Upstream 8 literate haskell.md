# Upstream #8 "Support for literal mode?" — literate Haskell (`.lhs`)

Source: <https://codeberg.org/pranshu/haskell-ts-mode/issues/8> (open,
Martinsos, 2025-01-11; long thread with pranshu, plus casouri's advice relayed
from Reddit). Analysed 2026-08-31.

Priority: C — recommendation is to defer the feature and spend one README line
stating so, which is what the issue asked for as its fallback.

## Where the thread landed

pranshu's first answer ("technically impossible: the code is not one contiguous
range") was wrong, and the thread corrects it. casouri: *"A tree-sitter parser
can have multiple disjoint ranges … It'll work as long as you set the ranges for
a single parser, rather than using an individual parser for each line."* He
recommended writing a trivial literate-Haskell host grammar anyway, to avoid
"uncharted territory" (his warning: highlighting may not update on edit without a
host parser). The thread then parked on "somebody should write a grammar", and
pranshu noted `treesit` injections were unstable at the time
(<https://lists.gnu.org/archive/html/emacs-devel/2025-01/msg00219.html>).

## What changed since

- `treesit-range-settings` on Emacs 30.2 (this package's floor is 30.1 — check
  the entry exists there too before relying on it) documents a **function** entry
  form: called with START and END, it "should ensure parsers' ranges are correct
  in the region between START and END". That is the supported, non-hacky version
  of casouri's fallback: recompute the code ranges on change and hand them to one
  Haskell parser. Verified from the installed Emacs's docstring, 2026-08-31.
- We already ship a **grammar fork** (`dschrempf/tree-sitter-haskell`, pinned in
  `flake.nix`) and build it in the flake. "Somebody has to write a grammar" is
  therefore a much smaller obstacle here than it was upstream: a
  literate-Haskell host grammar is ~40 lines (the thread's own example:
  `tree-sitter-perl/tree-sitter-pod`) and we have the packaging path for it. But
  it also means a *second* grammar to pin, build, install and document — the
  README already has to explain why the official Haskell grammar does not work.

## Scope reality check

Font lock is the smallest part. A usable `literate-haskell-ts-mode` also needs:
`.lhs` in `auto-mode-alist`; both literate styles (bird tracks `> `, and
LaTeX-style `\begin{code}`/`\end{code}`, plus the highlight-only `<`/`\begin{spec}`
variants Martinsos found); prose (non-code) lines treated as text, not code, by
the sexp/prose navigation layer, which currently assumes the whole buffer is
Haskell with comment islands — the exact inverse; imenu over code lines only; and
the REPL commands sending regions that contain `> ` prefixes.

## Recommendation

**Defer, and say so in the README** — which is what the issue asked for as the
fallback ("if it is out of scope, it might be worth mentioning that explicitly").
Literate Haskell is rare enough that this cannot outrank #15/#16 (font-lock
coverage and faces), let alone the open navigation work. Recording the decision
costs one README line and closes a five-year-old question for users.

If it is ever picked up, the cheapest viable order is:

1. **Spike, no grammar.** A `literate-haskell-ts-mode` deriving from
   `haskell-ts-mode`, with a range-setting *function* that scans the buffer for
   bird-track and `\begin{code}` regions and calls
   `treesit-parser-set-included-ranges` with the marker-stripped ranges of the
   primary parser. Measure: does highlighting survive editing (casouri's
   warning), and how does it behave on a 1000-line file?
2. **Only if the spike shows re-ranging is the problem**, write the trivial host
   grammar and switch to a query-based `treesit-range-rules` with `:embed
   'haskell :host 'literate-haskell`. Note the `OFFSET` argument of
   `treesit-range-rules` — `(START-OFFSET . END-OFFSET)` shifts every queried
   range, which is exactly how a fixed-width `> ` prefix gets stripped.
3. Navigation and prose motion: decide deliberately whether prose lines get the
   same sentence/paragraph treatment comments get today, or plain `text-mode`
   behaviour. `haskell-ts--region-at` classifies positions as
   `code`/`comment`/`haddock`/`string`; literate prose would be a fifth kind, and
   that is the point where this stops being a font-lock change.

## Cross-reference

`2026-08-31 Upstream 17 haddock code highlighting.md` shares the mechanism
(disjoint marker-stripped ranges into one parser). If both are ever done for
real, do the literate one first: no nesting inside comment nodes, so the range
math is visible in isolation.
