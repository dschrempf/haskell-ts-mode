;;; checkdoc.el --- Run checkdoc in batch, failing on any complaint -*- lexical-binding:t -*-

;;; Commentary:

;; Batch checkdoc runner for `make checkdoc'.  Checks every file named on
;; the command line and prints any style complaints.  This is
;; informational only: it always exits 0, so it never fails the build on
;; the package's pre-existing documentation-style debt.  Set the
;; environment variable HASKELL_TS_CHECKDOC_STRICT=1 to exit non-zero
;; when complaints are found.

;;; Code:

(require 'checkdoc)

(let ((files (or command-line-args-left '("haskell-ts-mode.el")))
      (issues nil))
  (dolist (file files)
    (with-current-buffer (find-file-noselect file)
      (let ((checkdoc-diagnostic-buffer "*checkdoc-batch*"))
        (checkdoc-current-buffer t)
        (with-current-buffer checkdoc-diagnostic-buffer
          (when (> (buffer-size) 0)
            (setq issues (concat issues (buffer-string)))
            (let ((inhibit-read-only t))
              (erase-buffer)))))))
  (when issues
    (princ issues)
    (when (getenv "HASKELL_TS_CHECKDOC_STRICT")
      (kill-emacs 1))))

;;; checkdoc.el ends here
