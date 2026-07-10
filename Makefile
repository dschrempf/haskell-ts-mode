# Makefile for haskell-ts-mode.
#
#   make compile       byte-compile, treating warnings as errors
#   make format        format source files
#   make test          run the ERT test suite
#   make check         compile + format + checkdoc + package-lint + test (the CI gate)
#   make checkdoc      run checkdoc, failing on any complaint under `make check';
#                       standalone (`make checkdoc') stays informational
#   make package-lint  lint package headers/dependencies/naming (needs
#                       epkgs.package-lint on `load-path', e.g. via the flake's
#                       dev shell)
#   make clean         remove byte-compiled files
#
# The grammar-dependent integration tests need @tek's tree-sitter-haskell
# grammar.  It is provided by the flake: run the suite inside the dev
# shell (`nix develop -c make check', or just `make check' under direnv),
# or headlessly with `nix flake check'.  Without the grammar those tests
# are skipped, not failed.
#
# `make check' banners each step and colours its pass/fail marker.
# Colour is on only when make's own stdout is a terminal (GNU Make sets
# `MAKE_TERMOUT' in that case), so piped/logged runs (CI, `nix flake
# check') get plain text instead of raw escape codes.

EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -L .

EL     = haskell-ts-navigation.el haskell-ts-mode.el
TESTS  = tests/haskell-ts-mode-tests.el

ifdef MAKE_TERMOUT
BOLD   := \033[1m
BLUE   := \033[34m
GREEN  := \033[32m
RED    := \033[31m
RESET  := \033[0m
else
BOLD   :=
BLUE   :=
GREEN  :=
RED    :=
RESET  :=
endif

# $(call step,NAME,COMMAND): print a banner for NAME, run COMMAND, then
# print a coloured pass/fail marker -- COMMAND's own failure still fails
# the enclosing recipe (and hence `make check').
step = printf '$(BOLD)$(BLUE)==> %s$(RESET)\n' "$(1)"; \
       $(2) && printf '$(BOLD)$(GREEN)+ %s$(RESET)\n\n' "$(1)" \
             || { printf '$(BOLD)$(RED)x %s$(RESET)\n\n' "$(1)"; exit 1; }

.PHONY: all check compile format checkdoc package-lint test clean

all: check

# Target-specific variables are inherited by a target's prerequisites (and
# their own prerequisites), so this only tightens `checkdoc' when it runs
# as part of `check' -- standalone `make checkdoc' is unaffected.
check: export HASKELL_TS_CHECKDOC_STRICT = 1
check: compile format checkdoc package-lint test
	@printf '$(BOLD)$(GREEN)All checks passed$(RESET)\n'

compile:
	@$(call step,compile,$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(EL))

# Formats $(EL) and $(TESTS) files.
#
# Remove stale byte-compiled files first: `load' prefers an existing
# .elc over newer source even when given an explicit ".el" filename, so
# a leftover .elc from a previous `make compile' would silently shadow
# just-edited source and this would check formatting of code that is no
# longer there. Same reasoning applies to `test' below.
format: clean
	@$(call step,format,$(BATCH) -l tests/format.el $(EL) $(TESTS))

checkdoc:
	@$(call step,checkdoc,$(BATCH) -l tests/checkdoc.el $(EL))

package-lint:
	@$(call step,package-lint,$(BATCH) -l tests/package-lint.el $(EL))

test: clean
	@$(call step,test,$(BATCH) -l $(TESTS) -f ert-run-tests-batch-and-exit)

clean:
	@rm -f $(EL:.el=.elc) $(TESTS:.el=.elc)
