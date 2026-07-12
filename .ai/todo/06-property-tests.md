# 06 — Property tests (opportunity)

`TODO.org` "Review tests" asks whether property tests are worth adding. One
strong candidate.

## Virtual-text mapping

`haskell-ts--virtual-text-and-table` + `haskell-ts--real-to-virtual` +
`haskell-ts--virtual-to-real` are pure, self-contained, and operate on plain
`(START . END)` buffer ranges — no parser, no grammar. They are currently
tested with **one** hand-built two-segment fixture
(`-virtual-text-and-table-roundtrip`); the >2-segment case is never exercised.

Clean invariants to generate over:
- **Round-trip identity:** for any in-segment real point `p`,
  `virtual-to-real(car(real-to-virtual(p))) = p`, and `on-marker` is nil.
- **Monotonicity:** `real-to-virtual` is order-preserving across segments.
- **Gap points:** a point strictly between two segments flags `on-marker`
  non-nil and clamps forward to the next segment's start.

## Sketch

No dependency needed beyond a hand-rolled generator (ERT has no built-in
quickcheck; keep it simple and deterministic — avoid `random` for
reproducibility, or seed it and print the seed on failure):

```elisp
(ert-deftest haskell-ts-test-virtual-mapping-roundtrip-property ()
  "Random ascending segment lists round-trip every in-segment point."
  (dolist (segments (haskell-ts-tests--gen-segment-lists)) ; e.g. 1..5 segments
    (with-temp-buffer
      (insert (make-string 200 ?x))
      (let* ((tt (haskell-ts--virtual-text-and-table segments))
             (table (cdr tt)))
        (dolist (seg segments)
          (cl-loop for p from (car seg) to (cdr seg) do
            (let ((loc (haskell-ts--real-to-virtual p table)))
              (should-not (cdr loc))
              (should (= p (haskell-ts--virtual-to-real (car loc) table))))))))))
```

Generator: build a handful of fixed segment lists (2, 3, 5 non-touching
ascending ranges) rather than truly random input — deterministic, still far
stronger than the single existing fixture, and covers the >2 case that survives
today.

## Lesser candidates (not worth it now)

- `align` idempotence — already asserted once; a property adds little.
- sexp "forward then backward returns near start" — hard to state cleanly
  across the exclusion edge cases; the targeted regression tests are better.
