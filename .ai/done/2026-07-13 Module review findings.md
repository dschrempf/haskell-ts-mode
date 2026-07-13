# Module review — findings and action items

Detailed review of the three source modules done 2026-07-13, per `TODO.org`
"Review navigation/REPL/main module" (which linked `.ai/review.md`; the review
prompt actually lives at `.ai/prompt/Review.md`). Reviewed against that prompt's
areas: quality, architecture, tests/docs, performance, security.

## Headline

All three modules are mature, carefully edge-cased, and unusually
well-documented. **No correctness bugs found.** Findings are refinements plus
one architectural theme — the package advises several globally-used functions.

## Findings by module

### Navigation (`haskell-ts-navigation.el`)
- Global advice on hot primitives is the one real architectural smell — see
  "Global advice" below.
- `haskell-ts--node-glued-p` (l.480) docstring says "NODE's boundary at POS" but
  the function takes `(pos dir)` — there is no `NODE` argument.
- `haskell-ts--forward-sentence-in-code` (l.399-401) catches `(error nil)`
  broadly; it only means to absorb `beginning-of-buffer`/`end-of-buffer`, which
  the sibling at l.464 already narrows to. Broad catch can mask real bugs.

### REPL (`haskell-ts-repl.el`)
- `haskell-ts-compile-region-and-go` (l.251-256): the `interactive` spec computes
  `(point-min)`/`(point-max)` for the no-region case, but the body re-checks
  `region-active-p` and sends `:r`, ignoring those bounds — dead work that
  misleads the reader. Collapse to `(interactive)` + branch in the body.
- The `"λ"` prompt branch (l.91-97) is documented-dead (redundant under the
  default `case-fold-search`). Already noted in source; the `.ai/done` test
  review flagged it too. Leave as-is.
- `haskell-ts-send-line` (l.258-267) sends any line verbatim, incl. a bare `:}`,
  which `haskell-ts--send-region` guards against. Harmless (just a GHCi error,
  no hang); a one-line docstring note would round out the contrast. Low priority.

### Main (`haskell-ts-mode.el`)
- `haskell-ts-font-lock-feature-list` (l.83) has **no docstring**, unlike every
  sibling `defvar`. Confirmed `checkdoc` does *not* flag it, so `make check`
  stays green — which is exactly why it slipped.
- Trailing whitespace on l.137. `make format` uses `indent-region`, which does
  not strip it, so CI won't catch it.
- `treesit-defun-type-regexp` predicate (l.333) uses `string-match` purely as a
  boolean but mutates global match-data; use `string-match-p`.
- `haskell-ts--imenu-node-name` (l.273-277) is a pure pass-through to
  `haskell-ts-defun-name`; keep only if a divergence is planned (add a `;;`
  note), else inline.

## Action items

Quick wins — all applied 2026-07-13 (`make check` green):
- [x] Added a docstring to `haskell-ts-font-lock-feature-list` (what the four
      sublists mean; order maps to `haskell-ts-font-lock-level` 1-4).
- [x] Stripped trailing whitespace on `haskell-ts-mode.el`.
- [x] `string-match` → `string-match-p` in the `treesit-defun-type-regexp`
      predicate.
- [x] Simplified `haskell-ts-compile-region-and-go` to `(interactive)` + a body
      branch (dropped the unused whole-buffer bounds).
- [x] Resolved the stale `TODO.org` links by removing the three now-done
      "Review … module" items (the review is complete; this file is the record).
- [x] Narrowed the `(error nil)` catch in `haskell-ts--forward-sentence-in-code`
      to `(beginning-of-buffer end-of-buffer)`, matching the scratch-buffer motion.
- [x] Fixed the `haskell-ts--node-glued-p` docstring (no `NODE` argument).
- [x] Docstring note on `haskell-ts-send-line`'s unguarded `:}`.

## Global advice on widely-used functions

The package advises functions used well outside `haskell-ts-mode`:

| Function | Scope | Purpose |
|---|---|---|
| `forward-paragraph`, `start-of-paragraph-text` | **always** | confine paragraph motion to a glued comment |
| `newline` | **always** | continue `--` comments on RET / `open-line` |
| `kill-region` | **always** | marker-aware `kill-sentence` |
| `kill-sentence`, `backward-kill-sentence` | **always** | (the commands themselves) |
| `delete-region` | evil-only *(now)* | marker-aware `evil-delete` |
| `evil-*` (select-object, paragraph motion, insert-newline, delete) | evil-only | evil integration |

**Constraint (why we can't just make them buffer-local):** Emacs advice on a
*named function* is inherently global — the Elisp manual's own answer for
per-mode behaviour is to have the advice test a buffer-local/dynamic condition,
which is exactly what the guards (`derived-mode-p 'haskell-ts-mode`,
`haskell-ts--sentence-deletion-active`) already do. There is no
`forward-paragraph-function`/`kill-region-function` hook to set buffer-locally,
so true "advise only in this mode" is not available for these primitives. What
we *can* do is (a) shrink the set advised globally and (b) install advice only
when it can ever fire.

Applied 2026-07-13:
- [x] **`delete-region` advice moved under `with-eval-after-load 'evil`.**
      Verified it only ever fires via `evil-delete`: the sole other setter of
      `haskell-ts--sentence-deletion-active` is `kill-sentence`, whose
      `kill-region` deletes via `delete-and-extract-region`, never
      `delete-region`. Non-evil sessions now leave this hot primitive
      completely unadvised. 119/119 tests still pass.

Remaining options (behaviour tradeoffs — decide deliberately, verify against the
evil/prose tests, which have regressed three times before; see `NOTES.org`):
- [ ] **`newline` → local RET binding.** Bind RET (and maybe `C-o`) in
      `haskell-ts-mode-map` to a wrapper that does the continuation, dropping the
      global `newline` advice. Cost: loses continuation for *other* `newline`
      callers (`open-line` and anything programmatic) unless separately handled.
- [ ] **`kill-region` → local kill-sentence commands.** Reimplement
      `kill-sentence`/`backward-kill-sentence` as local commands (bound to `M-k`)
      that call `haskell-ts--marker-aware-delete` directly, removing the global
      `kill-region` advice *and* the two `kill-sentence` advices. Cost: `M-x
      kill-sentence` (invoked as a command, not via the key) would not be
      marker-aware.
- [ ] **`forward-paragraph`/`start-of-paragraph-text`: keep global + guarded.**
      No buffer-local hook exists and non-evil comment confinement needs the
      primitive itself intercepted; rebinding `M-}`/`M-{` would miss programmatic
      callers. Recommend documenting the deliberate global footprint in the
      module commentary instead.
- [x] Added a note to `haskell-ts-navigation.el`'s Commentary (2026-07-13) that
      the package installs global advice on `newline`/`kill-region`/paragraph
      motion (each no-op outside the mode), so the footprint is discoverable.
      Also documented in `CLAUDE.md`'s architecture section.

### Opinion

Keep the guarded-global approach; it is the idiomatic Emacs mechanism and the
guards already make the advice inert elsewhere. The high-value, low-risk move
was scoping `delete-region` to evil (done). `newline` and `kill-region` *can* be
de-globalized via local key bindings, but each trades away coverage of
non-interactive/other-command callers and pokes fragile machinery, so they are
worth doing only as their own small, test-guarded change — not folded into
unrelated work. `forward-paragraph`/`start-of-paragraph-text` have no clean
alternative and should stay global, guarded, and documented.
