# Adopt the Emacs 31 `treesit-enabled-modes` mode-wiring pattern

Upstream ticket "Replace the existing loading time `treesit-ready-p` check"
(#69) on Pranshu Sharma's `haskell-ts-mode`, pointing at builtin `*-ts-mode`s
such as `rust-ts-mode` as the reference.

Written 2026-08-31. Analysis + plan only; nothing implemented.

Decisions D1-D6 locked 2026-08-31: drop the mode body's `error`, warn clearly
(once per session) naming the fork requirement, fall back to `haskell-mode` when
it is available without ever depending on it, and keep the grammar a manual
install. The unwind path for the last one is in "If the grammar ever becomes
auto-installable".

## What upstream actually asks for

Upstream 1.3.5 (`haskell-ts-mode.el:648`) ends with

```elisp
(when (treesit-ready-p 'haskell)
  (add-to-list 'auto-mode-alist '("\\.hs\\'" . haskell-ts-mode)))
```

The four claimed benefits, checked against this fork:

1. **No top-level (require-time) `treesit-ready-p` check.**
   *Already done here.* This fork's `add-to-list` is unconditional
   (`haskell-ts-mode.el:459-460`), and loading the feature emits nothing:
   `nix develop -c emacs -Q --batch -L . -l haskell-ts-mode` with no grammar on
   `treesit-extra-load-path` prints no warning. Load-time
   `treesit-font-lock-rules` does not compile queries, so it is silent too.
   Nothing left to do for this point.

2. **No spurious "missing treesit lib" warnings from async native-comp under
   `-Q`.** Consequence of (1); also already satisfied. (`treesit-ready-p`
   without `QUIET` calls `display-warning`; the async comp subprocess runs `-Q`,
   so the user's `treesit-extra-load-path` is not in effect and the grammar
   looks missing.)

3. **`treesit-enabled-modes` is simpler to use.** *Not done.* Emacs 31 option;
   `nil` (default) / `t` / list of ts-mode symbols. Its `:set` function copies
   entries out of `treesit-major-mode-remap-alist` into
   `major-mode-remap-alist` (`treesit.el` master, ~5880-5906).

4. **Packages can declare a mode alias via `treesit-major-mode-remap-alist`.**
   *Not done.* That variable is a **C-level** `DEFVAR_LISP` in `src/treesit.c`
   (master ~5502), i.e. it exists only in Emacs ≥ 31 **built with tree-sitter**
   — which is exactly why `rust-ts-mode` guards on `(boundp
   'treesit-major-mode-remap-alist)`. Core's default is `nil`; every ts-mode
   pushes its own `(MODE . TS-MODE)` pair.

So points 1-2 are already fixed in this fork. The substance for us is 3-4, plus
one real bug the pattern fixes (below).

## The real bug this fixes here

Today `.hs` is bound to `haskell-ts-mode` unconditionally, and the mode body
does

```elisp
(unless (treesit-ready-p 'haskell)
  (error "Tree-sitter for Haskell is not available"))
```

Given that this mode needs a grammar that **cannot be installed by
`treesit-install-language-grammar`** (the dschrempf fork ships no generated
`src/parser.c` — verified 2026-08-31: `src/` holds only `grammar.json`,
`node-types.json`, `scanner.c`, `unicode.h`, `tree_sitter/` — and has no release
branch, so `tree-sitter generate` must run first), a fresh install of this
package makes *every* `.hs` file signal an error, with no fallback to
`haskell-mode` even when it is installed. Upstream's guarded `add-to-list` at
least left `.hs` to whoever else claimed it. This fork traded a load-time
warning for a hard failure at file-visit time.

## Reference pattern (`rust-ts-mode`, Emacs master, verified 2026-08-31)

```elisp
;;;###autoload
(define-derived-mode rust-ts-mode prog-mode "Rust"
  ...
  ;; `treesit-ready-p' also checks for buffer size.
  (when (and (treesit-ensure-installed 'rust)
             (treesit-ready-p 'rust))
    (setq treesit-primary-parser (treesit-parser-create 'rust))
    ... everything ...
    (treesit-major-mode-setup)))

(derived-mode-add-parents 'rust-ts-mode '(rust-mode))

;;;###autoload
(defun rust-ts-mode-maybe ()
  "Enable `rust-ts-mode' when its grammar is available. ..."
  (declare-function treesit-language-available-p "treesit.c")
  (if (or (treesit-language-available-p 'rust)
          (eq treesit-enabled-modes t)
          (memq 'rust-ts-mode treesit-enabled-modes))
      (rust-ts-mode)
    (fundamental-mode)))

;;;###autoload
(when (boundp 'treesit-major-mode-remap-alist)
  (add-to-list 'auto-mode-alist '("\\.rs\\'" . rust-ts-mode-maybe))
  ;; To be able to toggle between an external package and core ts-mode:
  (add-to-list 'treesit-major-mode-remap-alist
               '(rust-mode . rust-ts-mode)))
```

Three separable pieces: (a) mode body degrades instead of erroring, (b) an
autoloaded `-maybe` dispatcher in `auto-mode-alist`, (c) a
`treesit-major-mode-remap-alist` entry so `treesit-enabled-modes` can flip
`haskell-mode` → `haskell-ts-mode`.

## Decisions this fork has to make differently

All of D1-D6 are **locked** (2026-08-31). D1 is explicitly provisional on the
grammar staying manually-installed; the unwind path is in "If the grammar ever
becomes auto-installable" below.

### D1. Do **not** call `treesit-ensure-installed` — **locked**

`treesit-ensure-installed` (Emacs 31) offers to run
`treesit-install-language-grammar`, driven by `treesit-auto-install-grammar`
(default `ask`). For us that is worse than useless:

- Core's `treesit-language-source-alist` defaults to `nil` and has **no**
  `haskell` entry, so the prompt leads nowhere useful.
- We cannot supply a working recipe (see above), so registering one would
  produce a prompt that always fails.
- Worse: if some *other* package registers the **official** `haskell` grammar,
  auto-install would silently build the wrong grammar — the one whose node
  types this mode's queries do not match. Silent mis-highlighting, not an error.

So the mode body guard is `(treesit-ready-p 'haskell)` alone. Note in a comment
*why* `treesit-ensure-installed` is deliberately absent, pointing at the unwind
section below — otherwise a future reader will "fix" it back, or a future
maintainer who makes the grammar installable will not realise how much of this
design was contingent on it.

### D2. Fall back to `haskell-mode`, not `fundamental-mode` — **locked**

`rust-ts-mode-maybe` falls back to `fundamental-mode`. For a `.hs` file that is
a poor outcome: `haskell-mode` is a mature mode that many users already have.

```elisp
(cond ((treesit-ready-p 'haskell t) (haskell-ts-mode))
      ((fboundp 'haskell-mode) (haskell-ts--warn-no-grammar) (haskell-mode))
      (t (haskell-ts--warn-no-grammar) (fundamental-mode)))
```

Caveat to weigh: `haskell-mode` may be *autoloadable* but not loaded, so
`fboundp` is unreliable until its autoloads are read — in practice
`package-activate-all` has run by the time a file is visited, so `fboundp` is
true for an installed `haskell-mode`. Alternative that dodges the question:
`(if (and (fboundp 'haskell-mode) ...) ...)` replaced by delegating to
`auto-mode-alist` minus our own entry — more code, not worth it.

Also note: this fork already does `(derived-mode-add-parents 'haskell-ts-mode
'(haskell-mode))`, so calling `haskell-mode` from the fallback is not circular
(that only registers a parent relation for `derived-mode-p`).

Two deliberate deviations from `rust-ts-mode-maybe` in the condition itself:

- **`treesit-ready-p`, not `treesit-language-available-p`.** `treesit-ready-p`
  additionally checks `treesit-max-buffer-size`. With rust's predicate, a huge
  `.hs` file would enter `haskell-ts-mode`, fail the mode body's own
  `treesit-ready-p`, and leave a degraded buffer with **no** fallback. With
  `treesit-ready-p` in the dispatcher, an oversized buffer routes to
  `haskell-mode` like any other not-ready case. Pass `QUIET` = `t` and warn
  ourselves (D5).
- **No `treesit-enabled-modes` branch.** Rust's `(or (treesit-language-available-p
  'rust) (eq treesit-enabled-modes t) (memq 'rust-ts-mode treesit-enabled-modes))`
  exists so that an opted-in user reaches `rust-ts-mode`, whose body then calls
  `treesit-ensure-installed` and *offers to install the grammar*. We reject
  `treesit-ensure-installed` (D1), so for us that branch could only ever produce
  a degraded buffer where `haskell-mode` would have worked. Dropping it means
  `treesit-enabled-modes` governs **only** the `haskell-mode` →
  `haskell-ts-mode` remap, never our own `.hs` entry — document that in the
  README. Trade-off: a user who has the grammar but wants `haskell-mode` cannot
  opt out via `treesit-enabled-modes`; they must drop our `auto-mode-alist`
  entry. `rust-ts-mode` has that same limitation, so this is not a regression
  against the reference.

### D3. Emacs 30.1 floor ⇒ everything is `boundp`-guarded — **locked**

`Package-Requires` is `(emacs "30.1")`. `treesit-enabled-modes`,
`treesit-major-mode-remap-alist` and `treesit-ensure-installed` are all Emacs
31. Consequences:

- Per D2 the dispatcher no longer reads `treesit-enabled-modes` at all, so no
  `bound-and-true-p` is needed there. If that deviation is ever reverted (see
  the unwind section), the reference must be `(bound-and-true-p
  treesit-enabled-modes)`, not bare: the dispatcher is autoloaded and reachable
  via `M-x` even on Emacs 30, where the variable is unbound.
- The `auto-mode-alist` entry must be installed on **both** paths, unlike
  `rust-ts-mode` which can assume a matching Emacs. On Emacs 30 there is no
  `treesit-major-mode-remap-alist`, so guarding the `add-to-list` on it would
  leave `.hs` completely unclaimed — a regression. Structure:

```elisp
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.hs\\'" . haskell-ts-mode-maybe))

;;;###autoload
(when (boundp 'treesit-major-mode-remap-alist)
  (add-to-list 'treesit-major-mode-remap-alist
               '(haskell-mode . haskell-ts-mode)))
```

- `treesit-declare-unavailable-functions` is Emacs 31 too; keep the existing
  explicit `declare-function` lists. Nothing to change.

### D4. Mode body: degrade, do not error — **locked**

`rust-ts-mode` wraps its whole body in the `when`, so without a grammar you get
a plain `prog-mode`-ish buffer. Adopting that here means moving **everything**
inside, including the two lines *after* `treesit-major-mode-setup`:

```elisp
(setq-local forward-sexp-function #'haskell-ts--forward-sexp)
(setq-local forward-sentence-function #'haskell-ts--forward-sentence)
```

Leaving those outside would install parser-dependent motion functions in a
buffer with no parser. Verify `haskell-ts--forward-sexp` /
`haskell-ts--forward-sentence` / `haskell-ts--region-at` behaviour with no
parser before deciding; the safe route is: everything inside the `when`.

Drop the explicit `error` and follow the reference. With D2 in place the
dispatcher already routes grammar-less users away from `haskell-ts-mode`, so the
only remaining way to reach the mode without a grammar is an explicit `M-x
haskell-ts-mode` (or a `treesit-enabled-modes` remap of `haskell-mode`) — and
there, `treesit-ready-p` called **without** `QUIET` already warns with the
actual cause (missing library vs. failed grammar load vs. buffer too large),
which is strictly more informative than the current flat message. A degraded
buffer beats a mode-activation error. Mention this in `CHANGELOG.org` as a
behavior change.

Note the asymmetry with D5: the mode body relies on `treesit-ready-p`'s own
warning (non-quiet), the dispatcher suppresses it and warns itself (quiet).
Deliberate — the dispatcher's warning has to mention the fork, and has to be
throttled because it fires on file visits.

### D5. Where the warning comes from — **locked**

There are two distinct paths into a grammar-less buffer, and only one of them
warns today:

1. **Visiting a `.hs` file.** The dispatcher takes the fallback branch. Nothing
   in Emacs warns here — `treesit-ready-p` is called with `QUIET`. This is the
   path essentially every affected user hits, so it needs our own warning.
2. **Explicit `M-x haskell-ts-mode`.** Reaches the mode body, whose
   `treesit-ready-p` is called **without** `QUIET` and so already warns with the
   precise cause (library missing / grammar failed to load, with the loader's
   error / buffer too large). Nothing to add.

For path 1, write `haskell-ts--warn-no-grammar`:

- Use `display-warning` with type `haskell-ts-mode`, not `message` — a silent
  `*Messages*` line is what leaves people confused about why highlighting is
  missing.
- **Warn at most once per session** (a package-level flag, set on first call).
  A per-visit popup would be hostile to the user who deliberately runs
  `haskell-mode`, and re-introduces exactly the "spurious warnings" complaint
  that motivated the upstream ticket.
- The text must name the *fork* requirement and where the instructions are —
  that is the actual gotcha, and it is what `treesit-ready-p`'s own message
  cannot know. Keep it short and point at the README's grammar section rather
  than restating the build steps (single source of truth); include the fork URL,
  which the Commentary header already carries.
- Say which mode was used instead, so the fallback is not silent magic.

### D6. `.hs` stays claimed unconditionally; `haskell-mode` stays a soft reference — **locked**

Two things that are easy to conflate, both settled here:

- **`haskell-mode` is never a dependency.** No `Package-Requires` entry, no
  `require`, no vendoring, no test dependency. The fallback is an `fboundp`
  check plus a call — the same shape as the existing optional `evil`
  integration, and as the existing `(derived-mode-add-parents 'haskell-ts-mode
  '(haskell-mode))`, which already names the symbol without depending on it.
  Add a `declare-function haskell-mode "haskell-mode"` so byte-compile and
  `package-lint` stay quiet, and stub `haskell-mode` in the fallback tests
  rather than putting it on `load-path`.
- **Our `.hs` → `haskell-ts-mode-maybe` entry is unconditional**, which is what
  keeps the previous point true. The rejected alternative was: on Emacs ≥ 31
  do not claim `.hs` at all, let `haskell-mode` own it, and rely on
  `treesit-major-mode-remap-alist` + `treesit-enabled-modes` for the remap.
  That design only works *if `haskell-mode` is installed* — with only this
  package installed, `.hs` would fall to `fundamental-mode`. It would make
  `haskell-mode` a de-facto hard requirement, which is exactly the outcome
  ruled out. So: unconditional.

Known cost, accepted: when both packages are installed, `auto-mode-alist` load
order decides the winner (`add-to-list` prepends, so whoever loads last wins),
not `treesit-enabled-modes`. Inherently racy; `rust-ts-mode` has the same
property.

## If the grammar ever becomes auto-installable

D1 (and with it D2's dropped `treesit-enabled-modes` branch) is contingent on
one fact only: `treesit-install-language-grammar` runs `cc`, never
`tree-sitter generate`, and the fork ships no generated `src/parser.c` and no
release branch that does. **Trigger:** the fork gains a committed
`src/parser.c`, or a release branch/tag that ships one — mirroring what
`tree-sitter-rust` does. Nothing else about this design needs to change first.

Unwind, in order:

1. **Register a recipe**, keyed to a revision known to match the font-lock
   queries:

   ```elisp
   (add-to-list 'treesit-language-source-alist
                '(haskell "https://github.com/dschrempf/tree-sitter-haskell"
                          :commit "<pinned rev>"))
   ```

   Two traps here:

   - **Do not blindly copy rust's `APPEND` = `t`.** `add-to-list` compares whole
     elements with `equal`, so an entry another package added for the *official*
     grammar does **not** stop ours being added — both end up in the list, and
     `assoc` takes the first. Appending therefore loses to whoever registered
     first, and losing means silently building the grammar whose node types
     these queries do not match. Add only when `(assq 'haskell
     treesit-language-source-alist)` is nil, so a deliberate user entry still
     wins but a drive-by one from another package does not silently hijack us.
   - **Single source of truth for the pin.** `flake.nix` already pins the
     grammar revision (`1ad6077a…` as of 2026-08-31, with a `preBuild` that runs
     `tree-sitter generate`). A second pin in Elisp will drift. Either derive one
     from the other at build time, or state in both places that they must be
     bumped together and add a check to `make check`. Decide this *before*
     adding the recipe, not after.
   - Consider whether the pin needs rust's `treesit-library-abi-version`
     conditional (it selects a different commit below ABI 15). Only if the fork
     ever ships grammar features that need a newer ABI.

2. **Mode body**: `(when (and (treesit-ensure-installed 'haskell)
   (treesit-ready-p 'haskell)) ...)`, i.e. exactly the reference. Remove the D1
   comment explaining the omission.
3. **Dispatcher**: restore rust's opt-in branch, so a user who set
   `treesit-enabled-modes` reaches the mode body and gets the install prompt
   even with no grammar yet:

   ```elisp
   (or (treesit-ready-p 'haskell t)
       (eq treesit-enabled-modes t)
       (memq 'haskell-ts-mode (bound-and-true-p treesit-enabled-modes)))
   ```

   Mind D3: `bound-and-true-p` matters, this file still supports Emacs 30. Note
   this branch reintroduces the case "opted in, install declined" → degraded
   buffer instead of `haskell-mode`; that is the reference's behavior and is
   defensible once declining is a real user choice rather than the only outcome.
4. **Docs**: the README's "Installing the grammar" section stops being a
   mandatory manual step, and D5's warning text (which points at it) needs
   rewording — it should then mention the install prompt.
5. D6 is unaffected: `haskell-mode` stays optional either way.

## Implementation steps

1. **Mode body.** Wrap the whole `haskell-ts-mode` body (from
   `treesit-primary-parser` through the two `setq-local`s after
   `treesit-major-mode-setup`) in `(when (treesit-ready-p 'haskell) ...)`;
   delete the `(unless ... (error ...))`. Leave grammar-independent setup
   (`comment-start`, `paragraph-start`, `electric-pair-pairs`,
   `align-mode-rules-list`, `prettify-symbols-alist`, `sentence-end-double-space`)
   **outside** the `when` — these are useful in a degraded buffer and none of
   them touch the parser. Add the comment explaining D1.
2. **Warning helper.** `haskell-ts--warn-no-grammar` plus its once-per-session
   flag (D5). Keep it next to the dispatcher, not in the mode body — the mode
   body does not use it.
3. **Dispatcher.** New autoloaded `haskell-ts-mode-maybe` implementing D2 + D3.
   Place it after `derived-mode-add-parents` (which must therefore move above
   it, i.e. out of its current position after `provide`) so the file reads in
   dependency order.
4. **Wiring.** Replace the `auto-mode-alist` entry's target with
   `haskell-ts-mode-maybe`; add the guarded `treesit-major-mode-remap-alist`
   entry (D3).
5. **Tests** (`tests/haskell-ts-mode-tests.el`):
   - `haskell-ts-test-auto-mode-alist` currently asserts `.hs` →
     `haskell-ts-mode` (line 102-105). Update to `haskell-ts-mode-maybe`.
   - New: dispatcher picks `haskell-ts-mode` when tree-sitter is ready
     (guard with `skip-unless (treesit-ready-p 'haskell t)`; assert
     `major-mode` in a temp buffer after `(haskell-ts-mode-maybe)`).
   - New: dispatcher falls back to `haskell-mode` when not ready and
     `haskell-mode` is `fboundp`, and to `fundamental-mode` when it is not.
     Grammar-independent: `cl-letf` `treesit-ready-p` to nil, and `cl-letf` a
     stub `haskell-mode` (which must set `major-mode`, or assert via a flag the
     stub sets — a stub that does nothing leaves `major-mode` at
     `fundamental-mode` and the two branches become indistinguishable).
   - New: the fallback warns, and warns only once. Bind the once-flag to nil,
     `cl-letf` `display-warning` to a counter, run the dispatcher twice, assert
     the count is 1. This is the test that pins D5; without it the throttle is
     the kind of detail a later refactor silently drops.
   - New: oversized buffer falls back rather than degrading — the D2 deviation
     from `rust-ts-mode`. Grammar-independent via a small
     `treesit-max-buffer-size` let-binding plus enough buffer text, or by
     `cl-letf`-ing `treesit-ready-p`; the former actually exercises the
     predicate choice, so prefer it (needs the grammar, so `skip-unless`).
   - New: mode activates without erroring when tree-sitter is not ready
     (grammar-independent; `cl-letf` `treesit-ready-p` to nil, assert no error
     and that grammar-independent setup still ran — e.g. `comment-start` is
     `"-- "` — which also pins step 1's "leave these outside the `when`").
   - Do **not** write a `treesit-enabled-modes` dispatcher test: per D2 the
     dispatcher no longer consults it. A `treesit-major-mode-remap-alist`
     assertion is worth having, `skip-unless (boundp ...)` since it is Emacs
     ≥ 31 only (CI Emacs is 30.2 today — confirm in `.github/workflows` and
     `flake.nix`, and expect that test to be skipped, not green, in CI).
6. **Docs.** `README.org` (the grammar section explains the manual install; add
   that without the grammar `.hs` now falls back to `haskell-mode` with a
   warning rather than erroring, and document that on Emacs ≥ 31
   `treesit-enabled-modes` controls only the `haskell-mode` →
   `haskell-ts-mode` remap — per D2 it does not affect our own `.hs` entry).
   `CHANGELOG.org` "Unreleased": the fallback, the warning, the dropped
   `error`, the remap entry.
7. `make check` green (compile + format + checkdoc + package-lint + ERT).
   Watch for: `package-lint` on the new autoload cookies; `checkdoc` on the new
   docstrings; byte-compile warnings for the Emacs-31-only symbols — a bare
   reference inside `(when (boundp ...))` still warns, so use
   `(bound-and-true-p ...)` / `defvar` forward declarations as needed.
   Also re-run the load-silence check from the top of this note
   (`nix develop -c emacs -Q --batch -L . -l haskell-ts-mode` with no grammar
   must stay warning-free) — the whole point of the ticket is not to regress it,
   and the new `add-to-list` forms run at load time.
8. **Report back upstream.** Points 1-2 of the ticket do not apply to a codebase
   that has already dropped the load-time check; points 3-4 do. If a patch is
   offered upstream, note that upstream targets Emacs 29.3, where *all* of
   `treesit-enabled-modes`, `treesit-major-mode-remap-alist` and
   `treesit-ensure-installed` are absent, so the guards matter even more there.

## Remaining notes

D1-D6 are locked; nothing here blocks implementation.

- If `package-lint` objects to the bare `haskell-mode` call despite the
  `declare-function` (D6), the existing `with-eval-after-load` suppression in
  `tests/package-lint.el` is the model for an exemption.
- `.lhs` / other extensions: out of scope, this fork claims only `.hs` today.
- `src/treesit.c` master seeds
  `treesit-languages-require-line-column-tracking` with `haskell`. Unrelated to
  this ticket, but worth knowing: on Emacs ≥ 31 this mode gets line-column
  tracking for free.
