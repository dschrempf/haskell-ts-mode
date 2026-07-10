# Makefile for haskell-ts-mode.
#
#   make compile       byte-compile, treating warnings as errors
#   make format        format source files
#   make test          run the ERT test suite
#   make check         compile + format + test (the CI gate)
#   make checkdoc      run checkdoc (informational; does not fail the build)
#   make clean         remove byte-compiled files
#
# The grammar-dependent integration tests need @tek's tree-sitter-haskell
# grammar.  It is provided by the flake: run the suite inside the dev
# shell (`nix develop -c make check', or just `make check' under direnv),
# or headlessly with `nix flake check'.  Without the grammar those tests
# are skipped, not failed.

EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -L .

EL     = haskell-ts-navigation.el haskell-ts-mode.el
TESTS  = tests/haskell-ts-mode-tests.el

.PHONY: all check compile format checkdoc test clean

all: check

check: compile format test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)'\
	         -f batch-byte-compile $(EL)

# Formats $(EL) and $(TESTS) files.
#
# Remove stale byte-compiled files first: `load' prefers an existing
# .elc over newer source even when given an explicit ".el" filename, so
# a leftover .elc from a previous `make compile' would silently shadow
# just-edited source and this would check formatting of code that is no
# longer there. Same reasoning applies to `test' below.
format: clean
	$(BATCH) -l tests/format.el $(EL) $(TESTS)

checkdoc:
	$(BATCH) -l tests/checkdoc.el $(EL)

test: clean
	$(BATCH) -l $(TESTS) -f ert-run-tests-batch-and-exit

clean:
	rm -f $(EL:.el=.elc) $(TESTS:.el=.elc)
