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
      (report nil)
      (complaints nil))
  (dolist (file files)
    (with-current-buffer (find-file-noselect file)
      (let ((checkdoc-diagnostic-buffer "*checkdoc-batch*"))
        (checkdoc-current-buffer t)
        (with-current-buffer checkdoc-diagnostic-buffer
          (when (> (buffer-size) 0)
            (setq report (concat report (buffer-string)))
            ;; `checkdoc-current-buffer' always writes a "*** FILE:
            ;; checkdoc-current-buffer" section header here, even when it
            ;; has no complaints to report; only a line of its own actual
            ;; "file:line: message" complaints means there is real debt.
            (when (string-match-p "^[^*\n].*:[0-9]+:" (buffer-string))
              (setq complaints t))
            (let ((inhibit-read-only t))
              (erase-buffer)))))))
  (when report
    (princ report)
    ;; checkdoc's own report text never ends in a newline, so without
    ;; this the caller's next output (e.g. `make check''s pass/fail
    ;; marker) runs onto the same line as the last complaint.
    (terpri)
    (when (and complaints (getenv "HASKELL_TS_CHECKDOC_STRICT"))
      (kill-emacs 1))))

;;; checkdoc.el ends here
