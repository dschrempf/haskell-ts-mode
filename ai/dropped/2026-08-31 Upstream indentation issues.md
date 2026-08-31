# Upstream 53, 31, 29, 26 (indentation) — dropped, the feature is gone

Reviewed 2026-08-31. Four open upstream issues, all about Tree-sitter
indentation, which this fork **removed** as an unmaintainable hack that was
disabled by default anyway (`CHANGELOG.org`, "Unreleased").

- **53 "Fix the indentation"** (pranshu, 2025-09-22) — a menu of four approaches
  (style-guide-driven rules, delegate to `hi2`/`hyai`, imitate `haskell-mode`,
  adaptive like `python-mode`). No work was done. pranshu's own point 3 names the
  reason this is hard with Tree-sitter: each indentation attempt can change the
  parse tree the rules are reading.
- **31 "Indentation behavior with electric-indent-mode"** (Netsu, 2025-04-30) —
  RET after a `->` continuation line re-indented the *previous* line. Upstream
  patched it twice and the reporter still saw it.
- **29 "adding custom offset for indentation"** (pranshu) — the PR implementing
  `haskell-ts-indent-offset`, for 26.
- **26 "Allow custom indentation offset"** (kristianan, 2025-04-23) — wants 4
  spaces, to match `fourmolu`.

## Why dropped rather than deferred

Without `treesit-simple-indent-rules`, `indent-line-function` is Emacs's default
`indent-relative` (measured), which copies the previous line's indentation. That
is a reasonable default for a layout-sensitive language, and it makes 29/26 moot
— there is no offset to configure — and 31's exact repro now behaves as the
reporter wanted:

```
myFunction
  :: Argument1
  -> Argument2
  ▮            ← RET puts point here, previous line untouched
```

53 would mean reintroducing the removed feature. If it is ever revisited, it
starts from the `CHANGELOG.org` rationale for removal, not from this issue.

The README already states the stance and points at Apheleia/Ormolu for
formatting (`README.org`, Features → "Indentation"), which is what 26 actually
needed. Nothing to add.

## Only loose end

`indent-relative` is inherited, not chosen. If TAB behaviour is ever surprising
in practice, the decision to make is "leave the default or set
`indent-line-function` explicitly", and it belongs in its own note — not in
these four issues.
