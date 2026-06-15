# Makefile for haskell-ts-mode.
#
#   make compile   byte-compile, treating warnings as errors
#   make test      run the ERT test suite
#   make check     compile + test (the CI gate)
#   make checkdoc  run checkdoc (informational; does not fail the build)
#   make clean     remove byte-compiled files
#
# The grammar-dependent integration tests need @tek's tree-sitter-haskell
# grammar.  It is provided by the flake: run the suite inside the dev
# shell (`nix develop -c make check', or just `make check' under direnv),
# or headlessly with `nix flake check'.  Without the grammar those tests
# are skipped, not failed.

EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -L .

EL      = haskell-ts-mode.el
TESTS   = tests/haskell-ts-mode-tests.el

.PHONY: all check compile checkdoc test clean

all: check

check: compile test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	         -f batch-byte-compile $(EL)

checkdoc:
	$(BATCH) -l tests/checkdoc.el $(EL)

test:
	$(BATCH) -l $(TESTS) -f ert-run-tests-batch-and-exit

clean:
	rm -f $(EL:.el=.elc) $(TESTS:.el=.elc)
