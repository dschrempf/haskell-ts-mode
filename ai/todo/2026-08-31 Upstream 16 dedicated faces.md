# Upstream #16 "Introduce intermediary/haskell- faces" — give the odd spots real faces

Source: <https://codeberg.org/pranshu/haskell-ts-mode/issues/16> (open,
Martinsos, 2025-01-25). Analysed 2026-08-31.

Priority: B — small, self-contained, and a prerequisite for the coverage item.

## What the issue asks

Stop painting Haskell-specific constructs with whatever `font-lock-*` face is
visually close, and introduce `haskell-ts-*` faces that inherit from a
`font-lock-*` face by default, so users can retarget them per construct.
Martinsos wants all of them (10–20 faces); pranshu pushed back on a full set but
agreed on three specific ones, and later (2025-05-17) proposed naming them after
`haskell-mode`'s faces so a theme supporting `haskell-mode` covers this mode too.

## Current state (measured 2026-08-31)

Only `haskell-ts-constructor-face` exists. The abuses the issue complains about
are all still there:

- `f` in the signature `f :: Int -> Int` → `font-lock-doc-markup-face`; `f` in
  the equation → `font-lock-function-name-face`. Same name, two faces, neither
  customizable independently.
- The return type of a signature → `font-lock-variable-name-face`
  (`haskell-ts--fontify-type`, hardcoded), other types → `font-lock-type-face`.
- `=`, `|`, `->` in matches, `<-` in list comprehensions and binds →
  `font-lock-doc-face`. pranshu's own words: "definitely … needs to go".

Those three are exactly the spots where a user currently has no lever at all:
`face-remap-add-relative` cannot separate them, because the face is shared with
genuinely-doc-ish text.

## Recommendation

Do the minimal version, not the full 10–20. Add faces only where the current
face is a lie or where two distinct constructs collide on one face:

| New face | Inherits | Replaces |
| --- | --- | --- |
| `haskell-ts-signature-name-face` | `font-lock-function-name-face` | `font-lock-doc-markup-face` on `signature`/`binding_list` variables |
| `haskell-ts-signature-result-face` | `font-lock-type-face` | hardcoded `font-lock-variable-name-face` in `haskell-ts--fontify-type` |
| `haskell-ts-equation-operator-face` | `font-lock-operator-face` | `font-lock-doc-face` on `=`/`\|`/`->`/`<-` in the `match` feature |

Defaulting the signature name to *the same* face as the definition name and the
result type to *the same* face as other types is a visible change: it makes the
default look plainer, and it is what Martinsos asked for. Anyone who liked the
old contrast restores it with one `set-face-attribute`. That trade is the whole
point of the issue — take it, and note it under a "Changed" entry in
`CHANGELOG.org`.

Deliberately **not** doing: a `haskell-ts-*` face for every capture. It is a
maintenance tax with no user gain — where a construct really is a keyword,
`font-lock-keyword-face` is the right answer and `face-remap-add-relative`
already covers per-buffer tweaks.

## On pranshu's "name them like `haskell-mode`" idea

Do not adopt it as stated. `haskell-mode` is not a dependency of this package
(the `derived-mode-add-parents` link is a mode-hierarchy claim, not a load), so
inheriting from `haskell-keyword-face` etc. would either require a hard
dependency or a `with-eval-after-load` that changes faces depending on load
order — a worse outcome than a stable default. Keep `haskell-ts-` names
inheriting from `font-lock-*`, and if theme parity is wanted later, document the
mapping in the README so theme authors can alias, or add an opt-in defcustom
that re-inherits from `haskell-mode`'s faces when that package is loaded.

## Plan

1. Define the three faces next to `haskell-ts-constructor-face`, same
   `:group 'haskell-appearance` convention (checkdoc-clean docstrings).
2. Swap the captures; `haskell-ts--fontify-type` takes the face as a constant it
   reads from one place, not a literal at the `put-text-property` call.
3. Tests: one ERT test per face asserting the new face on a probe buffer, in the
   font-lock section of `tests/haskell-ts-mode-tests.el`.
4. README: a short "Faces" subsection listing the four `haskell-ts-*` faces and
   the customize entry point. `CHANGELOG.org` "Unreleased": Added (three faces),
   Changed (signature name and result type now match their non-signature
   counterparts by default).
5. Sequencing: land this **before** the #15 coverage work — both edit the same
   queries, and #15 adds captures that should be born with the right face.
