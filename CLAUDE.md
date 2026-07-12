# Project summary

## Project Overview

`haskell-ts-mode` is an Emacs major mode for Haskell using Tree-sitter for syntax highlighting and structural navigation. It is an Emacs Lisp package split across `haskell-ts-mode.el` (font lock, imenu, mode definition, REPL) and `haskell-ts-navigation.el` (sexp/prose navigation and text objects, required by `haskell-ts-mode.el`), targeting Emacs 30.1+ with the built-in `treesit` module (bumped from 29.3 once `package-lint` caught that navigation.el's prose motion already required 30+ unconditionally — see `CHANGELOG.org`, "Unreleased"). It does not provide indentation — a Tree-sitter indent rule set existed but was removed as an unmaintainable hack that was disabled by default anyway (see `CHANGELOG.org`, "Unreleased").

> **Note:** `CLAUDE.md` and the `.ai/` directory **are tracked by git** (as of commit `825e19a`, "Track AI stuff with git"), so edits here *do* show up in `git status`/`git diff` and become part of commits — treat them like any other source file. The one exception is `.ai/agent-shell/`, which stays gitignored (see `.gitignore`).

## Development Commands

`make check` (compile + format + checkdoc + package-lint + ERT suite) is the CI gate; see `Makefile` and `tests/haskell-ts-mode-tests.el`. `checkdoc` is strict (`HASKELL_TS_CHECKDOC_STRICT=1`) only under `make check`; standalone `make checkdoc` stays informational (see `tests/checkdoc.el`). `make package-lint` needs `epkgs.package-lint` on `load-path` (provided by the flake's dev shell); see `tests/package-lint.el` for how it derives `haskell-ts-navigation.el`'s expected prefix/dependencies from the main file and suppresses the `with-eval-after-load` check (intentional, for optional `evil` integration). The grammar-dependent tests need @tek's grammar, provided by `flake.nix` via `HASKELL_TS_GRAMMAR_PATH` (run under `nix develop` or `nix flake check`) — otherwise they're skipped, not failed.

- **Load the mode**: `M-x load-file RET haskell-ts-mode.el RET` in Emacs (loads `haskell-ts-navigation.el` via `require`)
- **Byte-compile check**: `make compile` (or `emacs --batch -L . -f batch-byte-compile haskell-ts-navigation.el haskell-ts-mode.el`)
- **Run tests**: `make test` (depends on `clean`, so it removes stale `.elc` first — see below)
- **Test manually**: Open a `.hs` file with the mode active and verify highlighting/navigation behavior

> **Stale `.elc` trap:** `require`/`load` prefer an existing `.elc` over newer source (they only *warn* "source newer … using older file", then load the stale object). A leftover `.elc` from a previous `make compile`/`make check` therefore silently shadows just-edited source, so both `make test` and any ad-hoc `emacs -Q --batch -L . -l …` run the old code. `make test`/`make check` now `clean` first to avoid this; when loading the mode by hand after editing, byte-compile or `make clean` first.

The Tree-sitter Haskell grammar must be installed before the mode works:
```emacs-lisp
(add-to-list 'treesit-language-source-alist
  '(haskell . ("https://github.com/tree-sitter/tree-sitter-haskell" "v0.23.1")))
(treesit-install-language-grammar 'haskell)
```

## Architecture

Split across two files. `haskell-ts-navigation.el` holds sexp/prose navigation and is `require`d by `haskell-ts-mode.el`, which holds everything else. Major sections in order:

1. **Font lock** (`haskell-ts-font-lock`, in `haskell-ts-mode.el`): Tree-sitter font lock rules across 4 detail levels. Custom fontification functions (`haskell-ts--fontify-func`, `haskell-ts--fontify-arg`, `haskell-ts--fontify-params`, `haskell-ts--fontify-type`) walk the AST to highlight only actually-bound variables — not all occurrences.

2. **Navigation** (`haskell-ts-navigation.el`, all of it: `haskell-ts-sexp`, `haskell-ts-thing-settings`): Configures `forward-sexp`/`backward-sexp` using Tree-sitter node types. Emacs 30+ only.

   **Prose motion inside comments/strings** (`haskell-ts--forward-sentence`, wired as `forward-sentence-function`): a `--`/Haddock comment spanning several lines is *one* tree-sitter node — every continuation line repeats the `--` marker as ordinary text inside the node's `content` field, not as a separate node — so running `forward-sentence-default-function` on the raw buffer text misses paragraph breaks (a marker-only line isn't a blank *buffer* line) and lets a sentence that wraps onto a continuation line swallow that line's marker. The fix (`haskell-ts--text-node-segments` → `haskell-ts--comment-line-segments`) builds a dedented copy of the node's text with each continuation line's marker stripped, runs prose motion on that copy in a scratch buffer, then maps the result back onto the real buffer via `haskell-ts--virtual-text-and-table`/`haskell-ts--real-to-virtual`/`haskell-ts--virtual-to-real`. This fixes paragraph detection and sentence *bounds*, but not deletion across a marker: `d a s`/`kill-sentence` on a sentence that itself spans a continuation line still removes that line's marker, since motion only returns a point and the real text between two points includes whatever's there — see `NOTES.org`.

   **Evil paragraph text objects confined to a comment** (`haskell-ts--confine-paragraph-motion`, advised onto `forward-paragraph`/`start-of-paragraph-text`; `haskell-ts--confine-evil-paragraph-object`, advised onto `evil-select-an-object`/`evil-select-inner-object`): a `--`/Haddock comment glued directly to code (no blank line above/below) has no `paragraph-start`/`paragraph-separate` line to stop paragraph motion at, so `a p`/`i p` would otherwise spill into the surrounding code. `haskell-ts--node-forward-clamp`/`haskell-ts--node-backward-clamp` compute where to stop when a boundary is glued (`haskell-ts--node-glued-p`); the per-call advice clamps ordinary motion, while `evil-select-an-object`/`-inner-object` additionally narrow the buffer for the whole call (`haskell-ts--confining-evil-paragraph-object` suppresses the per-call clamp during that narrowing) since Evil detects "no more paragraph" via a round-trip motion that a mere per-call clamp would fool at a glued boundary.

   **Comment continuation on `RET`** (`haskell-ts--newline`, advised onto `newline`, plus a separate advice on `evil-insert-newline-above`/`-below` for Evil's `o`/`O`): breaking the line inside a `--`/Haddock comment repeats the marker (and leading indentation) on the new line via `haskell-ts--comment-continuation-prefix`, rather than leaving the comment or stripping a bare marker's trailing space.

3. **Imenu** (`haskell-ts-imenu-*-p` predicates, in `haskell-ts-mode.el`): Predicate functions identify functions, type signatures, data type declarations, and type aliases for the imenu outline. `haskell-ts--imenu-node-name` extracts display names.

4. **Mode definition** (`haskell-ts-mode`, in `haskell-ts-mode.el`): Derives from `prog-mode`; on Emacs 30+ additionally derives from `haskell-mode` for compatibility. No indentation support is configured — `treesit-simple-indent-rules` is left unset, so Emacs falls back to its default behavior.

5. **REPL** (`haskell-ts-run`, `haskell-ts-compile-region-and-go`, `haskell-ts-load-file`, in `haskell-ts-mode.el`): `comint`-based GHCi integration. An active region is sent verbatim wrapped in GHCi's `:{`/`:}` multiline delimiters (guarding against a standalone `:}` line, which GHCi cannot escape); with no region, `:r` reloads. `haskell-ts-load-file` (`C-c C-l`) loads the current buffer's file: it starts a session if none is running, saves the buffer, and sends `:load "<absolute-path>"`.

   `cabal repl` support (landed `4eebc8e`): `haskell-ts-run` starts the inferior process in the buffer's cabal project root — found by `haskell-ts--cabal-project-root` (walks up for `cabal.project`, else a `*.cabal` file) — so relative imports and the module search path resolve from there. `haskell-ts-use-cabal` (`auto`/`t`/`nil`, default `auto`) decides whether to launch via `haskell-ts-cabal` + `haskell-ts-cabal-switches` (default `("repl")`) instead of plain `ghci`; `auto` uses cabal when a project is detected and `cabal` is on `exec-path`. `haskell-ts--repl-command` assembles the command and, via `haskell-ts--cabal-file-target` (a `cabal repl --dry-run` probe), passes the current file as the target so cabal opens the owning component — avoiding the Cabal-7076 "no target" error. An ambiguous target (Cabal-7132, file shared by several components) aborts with a `user-error` relaying cabal's candidate list; an interactive component picker for that case is the remaining follow-up (see `TODO.org`). The environment (`process-environment`/`exec-path`) is inherited via `inheritenv` so envrc/direnv toolchains are honoured.

## Key Conventions

- Tree-sitter node type names (strings like `"function"`, `"signature"`) are used as identifiers throughout font lock queries.
- Font lock rules use `treesit-font-lock-rules` with named features; the 4-level feature list in `haskell-ts-font-lock-feature-list` controls which features are active at each level.
- The custom face `haskell-ts-constructor-face` is defined locally; all other faces use standard `font-lock-*` faces.
- This package intentionally has minimal scope — it does not replicate features available via LSP (completion, diagnostics, go-to-definition) or external formatters (Ormolu via Apheleia), and no longer attempts Tree-sitter-based indentation (see `CHANGELOG.org`, "Unreleased").

## Current Branch: `main`

The `@tek`-grammar retarget, `cabal repl` support, and imenu/bug fixes described above landed and shipped as 1.4 (see `CHANGELOG.org`). Development now happens directly on `main`; the "Unreleased" section of `CHANGELOG.org` tracks changes since that release, including the removal of the Tree-sitter indentation support, the comment prose-motion dedenting fix described above, and the split of sexp/prose navigation into `haskell-ts-navigation.el`.

REPL support has since been split into its own file, `haskell-ts-repl.el`, alongside `haskell-ts-navigation.el`.

Open follow-ups live in `TODO.org`; `NOTES.org` is reserved for true retrospective notes with no action item (e.g. why a fix approach turned out fragile) — anything actionable, even a tentative or open-ended one, belongs in `TODO.org` instead.

The `TODO.org` "Review tests" item was addressed by a mutation-tested review (2026-07-12); its findings and concrete follow-up test-writing tasks live, split into per-topic chunks, in the `.ai/todo/` directory (start at `.ai/todo/00-overview.md`). Headline: font lock — the namesake feature, including the `haskell-ts--fontify-*` bound-variable logic — has almost no behavioral coverage (only `keyword`/`doc` faces are ever asserted); see `.ai/todo/01-font-lock-coverage.md`. The other `.ai/todo/*` items cover REPL `:{`/`:}` wrapping, prose-motion edge cases, mode wiring, a dead `"λ"` prompt-regexp branch, and a virtual-text property test. None have been implemented yet.
