# Upstream 63 and 68 (hosting, search visibility) — dropped, they are about the old repo

Reviewed 2026-08-31.

- **68 "Migrate to github?"** — this fork already lives at
  <https://github.com/dschrempf/haskell-ts-mode>. Whether pranshu's repo moves is
  their call, not a work item here.
- **63 "Search engine preference in google"** (pranshu, 2026-03-25) — the
  Codeberg repo does not surface on Google for "haskell-ts-mode" unless
  "codeberg" is added; dschrempf confirmed in the thread that this fork ranked
  above it. An indexing problem on someone else's host, with no lever on this
  side.

## The one thing worth carrying over

63's underlying concern — people cannot find the package — does apply here, in a
different form: `README.org` notes that `:ensure t` installs *pranshu's*
`haskell-ts-mode` from MELPA, not this fork, so anyone following the usual
recipe silently gets the other package with the incompatible grammar
expectations. That is a packaging/naming question (MELPA presence, or a distinct
package name), not a search-engine question, and it deserves its own note if it
is ever picked up. Not opening one now — the README warning covers the immediate
hazard.
