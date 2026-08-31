# Upstream #15 "Add more/better coloring" — close the measured gaps

Source: <https://codeberg.org/pranshu/haskell-ts-mode/issues/15> (open, Martinsos,
2025-01-25; comments from SKyletoft and pranshu). Analysed 2026-08-31 against the
current fork + dschrempf grammar.

Priority: B — the namesake feature, and every gap below is a one-query fix. Do
`2026-08-31 Upstream 16 dedicated faces.md` first; same queries.

The issue's own list is stale — the keyword half was fixed upstream (pranshu,
2025-05-01) and the @tek retarget changed node types since. What follows is a
**measured** gap list: a probe buffer fontified with `haskell-ts-font-lock-level`
4 under the flake's grammar, reading the `face` property token by token.

## Measured gaps (2026-08-31)

Uncolored (face `nil`) where coloring is plainly wanted:

| Construct | Sample | Note |
| --- | --- | --- |
| Number literals | `42`, `3.14` | grammar nodes `integer`, `float`; `font-lock-number-face` exists since Emacs 29 |
| `\|` between data alternatives | `data D = Foo \| Bar` | the `match` feature's `\|` is guards only |
| Record braces, fields, `::` | `Rec { recA :: Int }` | `{`/`}` are not in the `parens` bracket list; field names get nothing |
| Strictness annotation | `!Double` | |
| `cases` keyword | `\cases` | `\case` works (`case` is in the keyword list); `cases` is a separate anonymous keyword in `_exp_lambda_cases` |
| Lambda `\` and its `->` | `\y -> y * 2` | `function arrow:` covers equations, not `lambda` |
| `type family` name | `type family F a` → `F` | `data_type`/`newtype`/`type_synonym` names are covered, family names are not |
| `class` name | `class C a where` → `C` | |
| Import-list names | `import M hiding (empty)` → `empty` | |
| Export-list names | `module M (foo, Bar(..))` → `foo`, `Bar` | even the constructor is bare — export items are not `constructor` nodes |

Deliberately uncolored, **do not "fix"**: variable and function *usages*
(`g`, `a`, `b` in `f a b = g (a + b)`). Fontifying only actually-bound variables
is this mode's signature behaviour (`haskell-ts--fontify-*`); issue #15 asks for
usage coloring, and the answer is no. Say so in the README rather than silently
diverging.

Semantically wrong rather than missing (`->`/`=`/`|` in matches painted with
`font-lock-doc-face`, signature name with `font-lock-doc-markup-face`, last type
of a signature with `font-lock-variable-name-face`): those are face-choice
problems, handled in `2026-08-31 Upstream 16 dedicated faces.md`. Do that one
first if both are done in one go — the queries touched here are the same ones.

## Plan

1. Re-run the probe after every step. Keep it as a scratch script, not a test;
   the assertions belong in `tests/haskell-ts-mode-tests.el` (the font-lock
   coverage suite from `ai/done/2026-07-12 01 Font lock coverage.md` is the
   pattern: one ERT test per construct, asserting `get-text-property … 'face`).
2. Cheap and uncontroversial, one commit each with a test:
   - `integer`/`float` → `font-lock-number-face` in a new `literal` feature
     (put it in feature-list level 1 or 2 next to `str`).
   - `cases` into the `keyword` list.
   - `{`/`}` into the `parens` bracket list; record field names via the
     `record`/`field` node (check the grammar's actual field names first —
     `grammar/data.js` in the fork).
   - `|` in `data_constructors`, lambda `\` and `->`.
   - `type family`/`class`/`instance` head names → `font-lock-type-face`.
3. Judgement calls, decide explicitly and record the decision in `CHANGELOG.org`:
   - Import/export list names. Martinsos suggests treating them like arguments;
     pranshu's open question (2025-05-01) is what to do with operators in
     `import M (x, y, (+))`. Recommendation: types/constructors get their normal
     type/constructor face, plain names get `font-lock-variable-name-face`,
     operators keep `font-lock-operator-face` — no special import face.
   - Strictness `!`: operator face.
4. Compare against nvim-treesitter's `queries/haskell/highlights.scm`
   (<https://github.com/nvim-treesitter/nvim-treesitter/tree/master/queries/haskell>,
   the reference the issue points at) for anything the probe missed. Use it as a
   checklist, not a source to copy: it is
   written against @tek's node types, which is exactly our grammar, so the node
   names transfer directly — but its face taxonomy (`@variable.parameter` etc.)
   does not map onto `font-lock-*` one-to-one.

## Risks

- `:override` interactions. Several features already run with `:override t`
  (`type`, `constructors`, `signature`); a new rule in a later feature silently
  wins. Every added rule needs a test that fixes the *observed* face, otherwise a
  later reordering flips it unnoticed.
- Feature-list placement changes what level 1–3 users see. New features default
  to a level; putting a noisy one at level 1 is a visible regression for anyone
  running a low `haskell-ts-font-lock-level`.
