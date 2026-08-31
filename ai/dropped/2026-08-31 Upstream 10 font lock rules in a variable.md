# Upstream 10 "Small fixes + cleaned up font lock rules a bit" — dropped

Reviewed 2026-08-31. Upstream issue/PR 10 (Martinsos, 2025-01-15),
<https://codeberg.org/pranshu/haskell-ts-mode/issues/10>.

## What it proposed

Split the font-lock rules into a plain quoted list
(`haskell-ts-font-lock-rules`) and apply `treesit-font-lock-rules` to it, per
Mastering Emacs' advice, so users can amend the rules instead of copying the
whole form. pranshu first objected on performance grounds, then withdrew that
objection (the cost is one extra variable), and declined on a different ground:
built-in modes (`c-ts-mode`, `ruby-ts-mode`) do it the direct way, and knowing
that pattern transfers to every other `*-ts-mode`. Martinsos reverted the part;
the rest of the PR (whitespace, `:anchor` instead of `.`, typo fixes) was
cosmetic and is long since overtaken by the @tek retarget.

## Verdict here

Decline, same reasoning, plus one this fork has that upstream did not: the rules
now carry custom fontification *functions* (`haskell-ts--fontify-arg`,
`-params`, `-type`) and four detail levels wired to
`haskell-ts-font-lock-feature-list`. An "amend the raw list" customization story
would have to stay coherent with that feature list — two variables that must be
edited in lockstep, which is the single-source-of-truth problem the split is
supposed to solve, not create.

Users who need to change fontification already have two supported levers:
`haskell-ts-font-lock-level` / `haskell-ts-font-lock-feature-list` to turn
features off, and appending to the buffer-local `treesit-font-lock-settings` in
a mode hook to add rules. If anything is owed here it is a README paragraph
showing the second one — fold that into whatever documentation work the faces
item (`ai/todo/2026-08-31 Upstream 16 dedicated faces.md`) produces, rather than
reviving this issue.
