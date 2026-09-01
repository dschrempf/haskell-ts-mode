# Make the REPL work over TRAMP

Written 2026-09-01, out of the `inheritenv` check (`TODO.org`). Nothing
implemented; the list below is an audit, not a verified plan.

Font lock, navigation and imenu are pure buffer operations and already work on a
remote file. Only `haskell-ts-repl.el` runs processes, and it is remote-unaware
in four places.

## Gaps

1. **`call-process` is local-only** (`haskell-ts-repl.el:239`, the
   `cabal repl --dry-run` probe in `haskell-ts--cabal-file-target`). With a
   remote `default-directory` it runs the *local* `cabal` against a path that
   does not exist there. Fix: `process-file`, which honours the remote
   `default-directory` the surrounding `let` already binds.
2. **`executable-find` is local-only** (`haskell-ts-repl.el:311`, the
   `haskell-ts-use-cabal` = `auto` decision). Needs its second argument:
   `(executable-find haskell-ts-cabal (file-remote-p root))` — note it must
   test the *project root*'s remoteness, not the current buffer's.
3. **`:load` is sent a TRAMP file name** (`haskell-ts-repl.el:396-398`). GHCi
   gets `/ssh:host:/home/me/Foo.hs`; it needs `(file-local-name file)`.
   Same for any other path handed to the inferior process.
4. **One global REPL buffer** (`haskell-ts-ghci-buffer-name`). A remote and a
   local session, or two hosts, collide in the same buffer. Probably wants the
   host (and maybe the project root) in the name — a behaviour change for the
   local case too, so decide deliberately.

Already fine, do not touch:

- `make-comint-in-buffer` uses `start-file-process` (`comint.el:920`, Emacs
  30.2), so starting GHCi on the remote host works once the command and the
  directory are right.
- `locate-dominating-file` / `directory-files` / `expand-file-name` /
  `file-relative-name` / `save-buffer` are all TRAMP-transparent, so
  `haskell-ts--cabal-project-root` and `haskell-ts--cabal-components` need no
  change.
- `inheritenv` also propagates `tramp-remote-path` and
  `tramp-remote-process-environment`, so the remote `exec-path` equivalent is
  carried into the comint buffer for free.

## Testing

No TRAMP test exists today and a real one is heavy. Cheapest useful split:
unit-test the pure path munging (gap 3, and the buffer-name scheme from gap 4)
locally, and verify the rest manually over `/ssh:localhost:`. Emacs's own suite
uses the `/mock:` method (`tramp-tests.el`) if a hermetic test is ever wanted;
check whether `nix flake check`'s sandbox can run it before relying on it.

## Scope question to settle first

Is remote Haskell development in scope at all? The grammar still has to be
installed *locally* (the parser runs in Emacs), and a user on a remote host is
just as likely to run Emacs there. If the answer is no, gaps 1-3 are still worth
fixing as correctness (they are one-liners and today fail confusingly), and gap 4
can be dropped.
