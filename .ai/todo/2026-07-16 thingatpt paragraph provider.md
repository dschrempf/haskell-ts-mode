# Replace the Evil paragraph-object advice with a thingatpt provider

Detailed plan for Point 1 of the navigation refactor's optional follow-ups
(`.ai/done/2026-07-14 Navigation bounds refactor.md`, action item "thingatpt
provider + evil text-object remap"). Point 2 (dropping the confinement) was
rejected — confining `a p`/`i p`/`}`/`{` to a glued comment stays.

Written 2026-07-16. This is a **behaviour-preserving** change: the 12
`haskell-ts-test-evil-*paragraph*` tests (tests lines ~2101–2320) plus the
`evil-*sentence*` tests are the spec and must stay green at every step.

## The discovery that reframes this work

The original sketch (and `NOTES.org`) assumed Evil computes a paragraph object
by calling `forward-paragraph`/`start-of-paragraph-text` and re-probing from
intermediate positions, with **no buffer-local hook** to intercept it — so the
only lever was global advice that narrows the whole Evil call. That was true of
the Evil/Emacs the code was written against; it is **no longer true** on the
package's Emacs 30.1 floor. Verified against upstream source (fetched
2026-07-16, since neither is distributed as plain text on this system — the gap
`NOTES.org` calls out):

- **Evil routes through thingatpt.** `evil-select-an-object` and
  `evil-select-inner-object` (evil-common.el) obtain the base object via
  `(bounds-of-thing-at-point thing)`, enlarge for a count via
  `(forward-thing thing cnt)`, and add surrounding whitespace via
  `evil-bounds-of-not-thing-at-point` — which is itself just paired
  `forward-thing` calls. The `}`/`{` motions `evil-forward-paragraph`/
  `evil-backward-paragraph` call `evil-forward-end`/`evil-backward-beginning`,
  both `forward-thing`. So *every* paragraph path bottoms out in
  `bounds-of-thing-at-point` and `forward-thing` on the `evil-paragraph` thing.
- **Emacs 30.1 made both overridable buffer-locally.** `etc/NEWS` (emacs-30
  branch): "The new variables `bounds-of-thing-at-point-provider-alist` and
  `forward-thing-provider-alist` now allow defining custom implementations."
  `bounds-of-thing-at-point` consults its alist first (thingatpt.el: `seq-some`
  over the alist before the `bounds-of-thing-at-point` property and the default
  end-op/beginning-op machinery). `forward-thing` consults its alist **before**
  falling back to `forward-op` (`(if (assq thing forward-thing-provider-alist)
  ... )`). Both docstrings say they are meant to be "appended to buffer-locally
  by modes."

That is exactly the buffer-local hook constraint 2 of the refactor said did not
exist — it just lives one layer up, at the thing layer, and only serves callers
that go through `forward-thing`/`bounds-of-thing-at-point` (Evil, and any
thingatpt-based command), **not** the low-level `forward-paragraph`/`M-}`.

**Consequence:** the fragile piece — the whole-call narrowing and its
re-probe-consistency flag — can be deleted outright and replaced by two small,
buffer-local, pure-ish provider functions backed by `haskell-ts--prose-bounds`.
No `derived-mode-p` guards (the alist is only installed in our buffers), no
advice on Evil internals.

## Scope

- **In scope: the paragraph thing only.** Register buffer-local providers for
  `evil-paragraph`. This covers `a p`, `i p`, `}`, `{`.
- **Out of scope: sentences.** Evil sentence objects (`a s`/`i s`) already work
  correctly through the buffer-local `forward-sentence-function`
  (`haskell-ts--forward-sentence`): `bounds-of-thing-at-point 'evil-sentence`
  and `forward-thing 'evil-sentence` fall to `evil-sentence`'s `forward-op`
  `forward-evil-sentence`, which uses `forward-sentence` = ours. The
  `evil-*sentence*` tests pass today with no sentence advice at all. The
  sketch's "remap sentence" was redundant; do not add a sentence provider.
  Marker-aware sentence *deletion* (`d a s`) is a separate mechanism and is
  untouched.
- **Undecided (resolve in Phase 4): the plain-Emacs `forward-paragraph`/
  `start-of-paragraph-text` clamp.** Providers do **not** cover plain `M-}`/
  `M-{` (`forward-paragraph`/`backward-paragraph` call `forward-paragraph`
  directly, never `forward-thing`). So `haskell-ts--confine-paragraph-motion`
  and its two `advice-add`s stay unless we decide plain-Emacs confinement is not
  worth keeping. There is currently **no test** for plain-Emacs paragraph
  confinement — every paragraph-confinement test is `evil-*`. See Phase 4.

## Design

Two provider functions in `haskell-ts-navigation.el`, both derived from the
existing `haskell-ts--region-at` / `haskell-ts--prose-bounds` primitives:

1. `haskell-ts--paragraph-bounds-at-point` → `(BEG . END)` or nil.
   For `bounds-of-thing-at-point-provider-alist`. Compute the region's
   confinement edges with `(haskell-ts--prose-bounds (point) 'paragraph)`,
   `save-restriction` + `narrow-to-region` to them, then run stock
   `forward-paragraph`/`start-of-paragraph-text` (unadvised, inside the
   narrowing) to get the *inner* paragraph — the mode's extended
   `paragraph-start`/`paragraph-separate` already splits `--`-only lines inside
   a comment, so the inner split is free; the narrowing supplies only the outer
   glued comment/code (or buffer) edge. Return those bounds. This is the same
   computation `haskell-ts--confine-evil-paragraph-in-node` did, but returning
   bounds instead of narrowing Evil's whole call.

2. `haskell-ts--forward-paragraph-thing` — takes BACKWARD, moves point once.
   For `forward-thing-provider-alist`. Move to the end of the next paragraph
   (or beginning of the previous, when BACKWARD), confined to the region at
   point via the same narrow-then-stock-motion. **Critical contract:** it must
   never leave point unmoved at a confined boundary. `forward-thing`'s provider
   loop treats a zero-distance move as "jump to `point-min`/`point-max` and
   stop" (thingatpt.el, lines ~120–129) — which at a glued edge would spill to
   the buffer edge. So at the region edge the provider must make a real,
   bounded move *to that edge* rather than returning without moving. This is the
   single subtle invariant of the whole change.

Registration in `haskell-ts-mode` (next to the existing
`forward-sentence-function` setup), unconditionally — the entries are inert
without Evil, since nothing else looks up the `evil-paragraph` thing:

```elisp
(setq-local bounds-of-thing-at-point-provider-alist
            (cons '(evil-paragraph . haskell-ts--paragraph-bounds-at-point)
                  bounds-of-thing-at-point-provider-alist))
(setq-local forward-thing-provider-alist
            (cons '(evil-paragraph . haskell-ts--forward-paragraph-thing)
                  forward-thing-provider-alist))
```

(Optionally also register the plain `paragraph` thing, for non-Evil thingatpt
callers; not required by any current behaviour.)

## What gets deleted vs. added

Deleted from `haskell-ts-navigation.el`:
- `haskell-ts--confine-evil-paragraph-object` (advice on `evil-select-an-object`/
  `evil-select-inner-object`).
- `haskell-ts--confine-evil-paragraph-motion` (advice on `evil-forward-paragraph`/
  `evil-backward-paragraph`).
- `haskell-ts--confine-evil-paragraph-in-node` (the shared narrowing helper).
- `haskell-ts--confining-evil-paragraph-object` (defvar + every reference) — the
  whole re-probe-consistency mechanism disappears, because a provider returns
  confined bounds directly and there is no multi-probe call to keep consistent.
- The four `advice-add` forms for those under `with-eval-after-load 'evil`.

Added:
- `haskell-ts--paragraph-bounds-at-point`, `haskell-ts--forward-paragraph-thing`.
- The two `setq-local` provider registrations in `haskell-ts-mode`.

Simplified:
- `haskell-ts--confine-paragraph-motion` loses its
  `haskell-ts--confining-evil-paragraph-object` guard branch (no Evil path
  triggers it anymore). It survives only for plain `M-}`/`M-{` — pending the
  Phase 4 decision.

Net: three functions + one defvar + four advice installs → two functions + two
buffer-local `setq-local`s. All Evil advice on paragraph motion/selection is
gone; the only remaining paragraph advice is the plain-Emacs clamp (if kept).

## Bonus: the count>1 limitation may resolve for free

`NOTES.org` records that whole-call narrowing caps `2}`/`3ap` at the single
glued node it confines to. Providers step per-thing rather than narrowing the
whole call, so `forward-thing` with a count re-narrows per step and can cross
into the next region. This is a potential *improvement*, not a regression — but
it is a behaviour change, so gate it: add a test pinning the desired `2}`/`3ap`
behaviour and decide deliberately whether to keep the old cap or take the
improvement. Do not let it change silently.

## Migration plan (each phase ends `make check`-green)

0. **Spike (throwaway).** In a scratch `haskell-ts-mode` buffer with Evil
   loaded, `setq-local` the two providers backed by the existing
   `haskell-ts--prose-bounds`, leave the old advice in place, and run the 12
   evil-paragraph tests to observe interaction. Confirms the providers actually
   intercept on the installed Evil before investing in deletion. Discard.
1. **Add the providers, keep the advice.** Implement both functions and register
   them; do **not** remove any advice yet. With both mechanisms active the
   providers win (thingatpt consults the alist first), so this should already be
   green — validating the providers in isolation. If any evil-paragraph test
   goes red here, the provider is wrong; fix before proceeding.
2. **Remove the Evil object advice** (`haskell-ts--confine-evil-paragraph-object`
   + its two installs). Run the `a p`/`i p` tests
   (`-a-paragraph-inside-comment`, `-glued-to-code`, `-glued-to-code-below-only`,
   `-from-code-glued-to-comment`, `-from-code-not-into-multi-para-comment`).
3. **Remove the Evil motion advice** (`haskell-ts--confine-evil-paragraph-motion`
   + its two installs) and delete `haskell-ts--confine-evil-paragraph-in-node`.
   Run the `}`/`{` tests (`-forward-paragraph-*`, `-backward-paragraph-*`,
   `-paragraph-motion-not-glued-unaffected`,
   `-paragraph-motion-glued-edge-no-error`, `-from-code-unaffected`).
4. **Decide the plain-Emacs clamp.** Either (a) keep
   `haskell-ts--confine-paragraph-motion` for `M-}`/`M-{`, dropping only its now-
   dead `haskell-ts--confining-evil-paragraph-object` branch and deleting that
   defvar; or (b) drop the clamp and its two advice installs too, accepting
   default plain-Emacs paragraph motion (no test covers it). Recommendation:
   keep (a) — it is the only lever for `M-}` and is not the fragile part — but
   add an explicit non-Evil `forward-paragraph` confinement test first so the
   behaviour stops being untested either way.
5. **Cleanup + docs.** Update the file Commentary (the global-advice-footprint
   paragraph shrinks dramatically; the paragraph confinement is now a
   buffer-local thingatpt provider, not advice), the `CLAUDE.md` navigation
   section (the "Evil paragraph text objects confined to a comment" and
   "Global-advice footprint" paragraphs), `CHANGELOG.org` "Unreleased", and
   `NOTES.org` (the fragility note now has a resolution: the buffer-local
   provider layer replaces the re-probing fight — record it rather than deleting
   the history).

## Risks

- **The `forward-thing` zero-move-to-limit trap** (Design point 2) is the
  landmine. If the forward provider fails to move at a glued edge,
  `forward-thing` leaps point to `point-min`/`point-max` and Evil's
  `evil-bounds-of-not-thing-at-point` then reports whitespace all the way to the
  buffer edge — a spill. The provider must always make a bounded move to the
  region edge. Verify with `-glued-to-code-below-only` and
  `-from-code-glued-to-comment`, which exercise the one-sided-glue math.
- **`bounds-of-thing-at-point` returning nil re-enters the default path.** If
  the bounds provider returns nil (point genuinely not in a paragraph, e.g. a
  blank line), `bounds-of-thing-at-point` falls through to the default end-op/
  beginning-op machinery, which uses `evil-paragraph`'s `forward-op`
  (`forward-evil-paragraph` → `forward-paragraph`, still advised in options (a)).
  Decide what the provider returns on a blank line and keep the plain clamp
  correct for that fallback; this is why Phase 4 keeps the clamp until proven
  unnecessary.
- **Evil version variance.** The `forward-thing` provider is consulted
  regardless of Evil version (it is Emacs-level and checked before `forward-op`).
  The `bounds-of-thing-at-point` provider is consulted by any Evil whose
  `evil-select-*-object` calls `bounds-of-thing-at-point` — true of current and
  long-standing Evil. Supplying both providers is robust across versions.
- **Do not reintroduce the narrowing strategy.** The whole point is to replace
  it. If a test resists, fix the provider's returned bounds/motion, not by
  wrapping a narrow back around it.

## Recommendation

Proceed. The Emacs 30.1 provider layer is a strictly cleaner lever than the
advice it replaces, removes the most-broken feature's machinery entirely, is
truly buffer-local (no guarded-global advice, no derived-mode-p checks), and may
incidentally fix the count>1 cap. The one real hazard — the `forward-thing`
zero-move-to-limit contract — is local to one small function and fully covered
by the existing 12 tests. Keep the plain-Emacs clamp (option 4a) unless a
deliberate decision retires plain-`M-}` confinement.
