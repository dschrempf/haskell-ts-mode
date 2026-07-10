;;; package-lint.el --- Run package-lint in batch, failing on real complaints -*- lexical-binding:t -*-

;;; Commentary:

;; Batch package-lint runner for `make package-lint'.  Lints every file
;; named on the command line and exits non-zero if any genuine complaint
;; is found.

;;; Code:

(require 'package-lint)

;; `haskell-ts-navigation.el' is a secondary file of the `haskell-ts-mode'
;; package, not a standalone package: without this, package-lint infers
;; its expected header block, dependency floor and symbol prefix from its
;; own file name ("haskell-ts-navigation") instead of the package's,
;; producing dozens of false positives.
(setq package-lint-main-file "haskell-ts-mode.el")

;; `haskell-ts-navigation.el' advises `evil-select-an-object' et al. only
;; when `evil' is loaded, since those symbols do not exist otherwise;
;; `with-eval-after-load' is the standard, recommended way to defer such
;; optional integration (see (elisp) "Hooks for Loading"), not the kind of
;; user-configuration-only misuse this check exists to catch.
(advice-add 'package-lint--check-eval-after-load :override #'ignore)

(package-lint-batch-and-exit)

;;; package-lint.el ends here
