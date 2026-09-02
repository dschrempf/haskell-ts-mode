;;; readme.el --- Export README.org to README.md -*- lexical-binding: t -*-

;;; Commentary:

;; Batch Org exporter behind `make readme' and the `readme' step of `make
;; check'.  README.org is the source; README.md is generated and committed,
;; and GitHub shows it in preference to README.org when both exist.
;;
;; The detour exists because GitHub renders Org with org-ruby, which drops
;; `CUSTOM_ID' anchors (so an internal link like `[[#grammar]]' is dead) and
;; does not render markup inside a link description (`[[url][=code=]]' comes
;; out with the equals signs visible).  Exporting sidesteps both.
;;
;; With no arguments the script writes README.md.  With `--check' it exports
;; to a string and fails if the committed README.md differs, which is what
;; keeps the two in sync without anyone remembering to run the export.

;;; Code:

(require 'ox-md)

(defconst haskell-ts-readme-source "README.org"
  "Org file to export.")

(defconst haskell-ts-readme-target "README.md"
  "Markdown file generated from `haskell-ts-readme-source'.")

(defconst haskell-ts-readme-banner
  "<!-- Generated from README.org by `make readme'.  Do not edit. -->\n\n"
  "Header prepended to `haskell-ts-readme-target'.")

(defun haskell-ts-readme--src-block (src-block _contents info)
  "Transcode SRC-BLOCK into a fenced Markdown code block.
The stock Markdown back end indents source blocks by four spaces, which
drops the language and with it GitHub's syntax highlighting.  INFO is a
plist holding contextual information."
  (format "```%s\n%s```"
          (or (org-element-property :language src-block) "")
          (org-export-format-code-default src-block info)))

(defun haskell-ts-readme--link (link contents info)
  "Transcode LINK, leaving a link to another Org file pointing at it.
The stock Markdown back end rewrites `CHANGELOG.org' to `CHANGELOG.md',
which does not exist -- only the README is exported.  Emacs 31 and newer
have `org-md-link-org-files-as-md' for this; doing it here keeps the
export identical on the Emacs 30 the flake pins.  CONTENTS is the link
description, INFO a plist holding contextual information."
  (let ((path (org-element-property :path link)))
    (if (and (string= (org-element-property :type link) "file")
             (equal (file-name-extension path) "org"))
        (format "[%s](%s)" (or contents path) path)
      (org-md-link link contents info))))

(org-export-define-derived-backend 'haskell-ts-readme-md 'md
  :translate-alist '((link . haskell-ts-readme--link)
                     (src-block . haskell-ts-readme--src-block)))

(defun haskell-ts-readme-export ()
  "Return `haskell-ts-readme-source' exported to Markdown, as a string.
Every headline needs a `CUSTOM_ID': the back end anchors headlines it has
no id for with a freshly generated one, which would make the export differ
from run to run and the `--check' comparison meaningless."
  (let ((coding-system-for-read 'utf-8)
        (enable-local-variables nil)
        (org-export-with-toc nil))
    (with-current-buffer (find-file-noselect haskell-ts-readme-source)
      (let ((exported (concat haskell-ts-readme-banner
                              (org-export-as 'haskell-ts-readme-md))))
        ;; Anything the back end has to name itself gets an `orgXXXXXXX'
        ;; reference, freshly generated on every run -- so `--check' would
        ;; fail at random, and a fuzzy headline link (`[[*Heading]]') ends
        ;; up pointing at an anchor that is never emitted.  Both mean the
        ;; headline wants a `CUSTOM_ID' and the link wants to use it.
        (when (string-match "\\borg[0-9a-f]\\{7\\}\\b" exported)
          (princ (format "%s: generated reference `%s' -- give the headline \
a CUSTOM_ID and link to that\n"
                         haskell-ts-readme-source (match-string 0 exported)))
          (kill-emacs 1))
        exported))))

;; This script runs while Emacs is still processing its command line, so
;; `command-line-args-left' holds the arguments after `-l tests/readme.el'.
;; Clear them, or Emacs resumes processing once the load returns and chokes
;; on `--check' as an unknown option.
(let ((args (prog1 command-line-args-left
              (setq command-line-args-left nil)))
      (exported (haskell-ts-readme-export))
      (coding-system-for-write 'utf-8-unix))
  (if (member "--check" args)
      (let ((committed (and (file-exists-p haskell-ts-readme-target)
                            (with-temp-buffer
                              (let ((coding-system-for-read 'utf-8))
                                (insert-file-contents haskell-ts-readme-target))
                              (buffer-string)))))
        (unless (equal committed exported)
          (princ (format "%s is out of date, run `make readme'\n"
                         haskell-ts-readme-target))
          (kill-emacs 1)))
    (with-temp-file haskell-ts-readme-target
      (insert exported))
    (message "Wrote %s" haskell-ts-readme-target)))

;;; readme.el ends here
