# 07 — Design observations (no action required)

`TODO.org` "Review tests" asks: are the features good/useful, are some tests
awkward or testing un-features, do we miss features? These are judgment calls
for the maintainer, logged for the record — none is a defect.

## Marker-aware sentence deletion — cost/benefit

`haskell-ts--marker-aware-delete` + advice on `kill-region` / `delete-region` /
`evil-delete` + the `haskell-ts--sentence-deletion-active` dynamic flag is a
large, clever machine for a niche need: preserving a continuation `--` when a
*sentence* deletion happens to span a comment line.

- It is well-tested (6 tests; the pieces>0/pieces>1 threshold mutation was
  caught) and the scoping is disciplined (only sentence deletion, only charwise
  evil types, only when a marker is actually straddled — verified by
  `-kill-region-manual-not-marker-aware` and `-evil-delete-line-not-marker-aware`).
- Open question purely of proportion: how often does anyone `d a s` / `kill-sentence`
  across a `--` line boundary vs. the maintenance surface (3 advices + a
  dynamic var reaching into `kill-region`/`delete-region` globally)? Not a
  recommendation to remove — a flag for the maintainer.

## Evil paragraph-object confinement — the imbalance, restated

The `a p`/`i p` and `}`/`{` glued-comment confinement (`~30` tests, narrowing +
suppression var + 4 advices, "broken three times" per `NOTES.org`) has genuinely
excellent coverage; each test pins a specific failure mode. **No change.** It is
mentioned only because the *ratio* of this investment to font-lock coverage (see
`01-font-lock-coverage.md`) is the imbalance worth correcting — by adding
font-lock tests, not by removing these.

## Test goals: sound

Overall the suite's goals are sound and its regression discipline is the best in
the repo. The one structural critique is the coverage/prominence inversion above
(fragile corner over-covered, everyday highlighting under-covered), addressed by
items 01–04.

## Features not missing that might look missing

- No indentation tests — correct: indentation was deliberately removed
  (`CHANGELOG.org` "Unreleased"); there is nothing to test.
- No LSP/completion/formatter tests — correct: out of scope by design
  (`CLAUDE.md` "minimal scope").
