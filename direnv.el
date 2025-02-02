;;; direnv.el --- Support for direnv -*- lexical-binding: t; -*-

;; Copyright (c) 2017  wouter bolsterlee

;; Author: wouter bolsterlee <wouter@bolsterl.ee>
;; Version: 2.2.0
;; Package-Requires: ((emacs "25.1") (dash "2.12.0"))
;; Keywords: direnv, environment, processes, unix, tools
;; URL: https://github.com/wbolster/emacs-direnv

;; This file is not part of GNU Emacs.
;;
;; All rights reserved.
;;
;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions
;; are met:
;;
;; * Redistributions of source code must retain the above copyright
;;   notice, this list of conditions and the following disclaimer.
;;
;; * Redistributions in binary form must reproduce the above copyright
;;   notice, this list of conditions and the following disclaimer in
;;   the documentation and/or other materials provided with the
;;   distribution.
;;
;; * Neither the name of the author nor the names of the contributors
;;   may be used to endorse or promote products derived from this
;;   software without specific prior written permission.
;;
;; This software is provided by the copyright holders and contributors
;; "as is" and any express or implied warranties, including, but not
;; limited to, the implied warranties of merchantability and fitness
;; for a particular purpose are disclaimed. In no event shall the
;; copyright holder or contributors be liable for any direct,
;; indirect, incidental, special, exemplary, or consequential damages
;; (including, but not limited to, procurement of substitute goods or
;; services; loss of use, data, or profits; or business interruption)
;; however caused and on any theory of liability, whether in contract,
;; strict liability, or tort (including negligence or otherwise)
;; arising in any way out of the use of this software, even if advised
;; of the possibility of such damage.

;;; Commentary:

;; Direnv (https://direnv.net/) integration for Emacs.

;; Enable the global `direnv-mode' minor mode to have inferior shells,
;; linters, compilers, and test runners start with the intended
;; environmental variables.

;; Using the command `direnv-allow' you can mark a ".envrc" as safe
;; (remember to always first check if it trustworthy)

;;; Code:

(require 'dash)
(require 'diff-mode)
(require 'json)
(require 'subr-x)

(defgroup direnv nil
  "Direnv integration for Emacs."
  :group 'environment
  :prefix "direnv-")

(defun direnv--detect ()
  "Detect the direnv executable."
  (executable-find "direnv"))

(defvar direnv--output-buffer-name "*direnv*"
  "Name of the buffer filled with the last direnv output.")

(defvar direnv--executable (direnv--detect)
  "Detected path of the direnv executable.")

(defvar direnv--active-directory nil
  "Name of the directory for which direnv has most recently ran.")

(defvar direnv--hooks '(post-command-hook before-hack-local-variables-hook)
  "Hooks that ‘direnv-mode’ should hook into.")

(defcustom direnv-always-show-summary t
  "Whether to show a summary message of environment changes on every change.

When nil, a summary is only shown when direnv-update-environment is called
interactively."
  :group 'direnv
  :type 'boolean)

(defcustom direnv-show-paths-in-summary t
  "Whether to show directory paths in the summary message."
  :group 'direnv
  :type 'boolean)

(defcustom direnv-use-faces-in-summary t
  "Whether to use custom font faces in the summary message.

When enabled, the summary message uses custom font faces strings
for added, changed, and removed environment variables, which
usually results in coloured output."
  :group 'direnv
  :type 'boolean)

(defcustom direnv-non-file-modes
  '(comint-mode compilation-mode dired-mode eshell-mode magit-mode)
  "Major modes where direnv will update even if the buffer is not a file.

In buffers using these modes, or modes derived from them, direnv will
use `default-directory', since there is no file name (or directory)."
  :group 'direnv
  :type '(repeat (symbol :tag "Major mode")))

(defvar eshell-path-env)

(defun direnv--directory ()
  "Return the relevant directory for the current buffer, or nil."
  (let* ((buffer (or (buffer-base-buffer) (current-buffer)))
         (mode (buffer-local-value 'major-mode buffer))
         (file-name (buffer-file-name buffer))
         (buffer-directory
          (cond (file-name
                 (file-name-directory file-name))
                ((apply #'direnv--provided-mode-derived-p mode direnv-non-file-modes)
                 default-directory))))
    buffer-directory))

(defun direnv--export (directory)
  "Call direnv for DIRECTORY and return the parsed result."
  (unless direnv--executable
    (setq direnv--executable (direnv--detect)))
  (unless direnv--executable
    (user-error "Could not find the direnv executable.  Is `exec-path' correct?"))
  (let ((environment process-environment)
        (stderr-tempfile (make-temp-file "direnv-stderr"))) ;; call-process needs a file for stderr output
    (unwind-protect
        (with-current-buffer (get-buffer-create direnv--output-buffer-name)
          (erase-buffer)
          (let* ((default-directory directory)
                 (process-environment environment)
                 (exit-code (call-process
                             direnv--executable nil
                             `(t ,stderr-tempfile) nil
                             "export" "json")))
            (prog1
                (unless (zerop (buffer-size))
                  (goto-char (point-max))
                  (re-search-backward "^{")
                  (let ((json-key-type 'string)
                        (json-object-type 'alist))
                    (json-read-object)))
              (unless (zerop (direnv--file-size stderr-tempfile))
                (goto-char (point-max))
                (unless (zerop (buffer-size))
                  (insert "\n\n"))
                (insert-file-contents stderr-tempfile))
              (with-temp-buffer
                (unless (zerop exit-code)
                  (insert-file-contents stderr-tempfile)
                  (display-warning
                   'direnv
                   (format-message
                    "Error running direnv (exit code %d):\n%s\nOpen buffer ‘%s’ for full output."
                    exit-code (buffer-string) direnv--output-buffer-name)))))))
      (delete-file stderr-tempfile))))

(defun direnv--file-size (name)
  "Get the file size for a file NAME."
  (let ((attributes (file-attributes name)))
    ;; Note: file-attribute-size is Emacs 26+
    (nth 7 attributes)))

(defun direnv--enable ()
  "Enable direnv mode."
  (--each direnv--hooks
    (add-hook it #'direnv--maybe-update-environment))
  (direnv--maybe-update-environment))

(defun direnv--disable ()
  "Disable direnv mode."
  (--each direnv--hooks
    (remove-hook it #'direnv--maybe-update-environment)))

(defun direnv--maybe-update-environment ()
  "Maybe update the environment."
  (with-current-buffer (window-buffer)
    (let ((directory-name (direnv--directory)))
      (when (and directory-name
                 (not (file-remote-p directory-name))
                 (not (string-equal direnv--active-directory directory-name))
                 (file-directory-p directory-name))
        (direnv-update-directory-environment directory-name)))))

(defun direnv--summarise-changes (items)
  "Create a summary string for ITEMS."
  (string-join
   (--map
    (let* ((name (car it))
           (state (cdr it))
           (face)
           (prefix))
      (pcase state
        (`added   (setq prefix "+" face 'diff-added))
        (`changed (setq prefix "~" face 'diff-changed))
        (`removed (setq prefix "-" face 'diff-removed)))
      (propertize (concat prefix name) 'face face))
    (--sort
     (string-lessp (symbol-name (cdr it)) (symbol-name (cdr other)))
     (--map
      (cons (car it)
            (if (cdr it) (if (getenv (car it)) 'changed 'added) 'removed))
      (--sort
       (string-lessp (car it) (car other))
       (--remove (string-prefix-p "DIRENV_" (car it)) items)))))
   " "))

(defun direnv--format-paths (old-directory new-directory)
  "Format the path component of the summary message.

The string will describe a transition from OLD-DIRECTORY and
NEW-DIRECTORY, but OLD-DIRECTORY can be nil."
  (cond
   ((or (null old-directory)
        (string-equal old-directory new-directory))
    (abbreviate-file-name (directory-file-name new-directory)))
   (t
    (format "%s → %s"
            (abbreviate-file-name (directory-file-name old-directory))
            (abbreviate-file-name (directory-file-name new-directory))))))

(defun direnv--show-summary (summary old-directory new-directory)
  "Show a SUMMARY message.

OLD-DIRECTORY and NEW-DIRECTORY are the directories before and afther
the environment changes."
  (let ((summary
         (if (string-empty-p summary) "no changes" summary))
        (paths
         (when direnv-show-paths-in-summary
           (direnv--format-paths old-directory new-directory))))
    (unless direnv-use-faces-in-summary
      (setq summary (substring-no-properties summary)))
    (if paths
        (message "direnv: %s (%s)" summary paths)
      (message "direnv: %s" summary))))

(defun direnv--provided-mode-derived-p (mode &rest modes)
  "Non-nil if MODE is derived from one of MODES.

Same as ‘provided-mode-derived-p’ which is Emacs 26.1+ only."
  (while (and (not (memq mode modes))
              (setq mode (get mode 'derived-mode-parent))))
  mode)

(when (fboundp 'provided-mode-derived-p)
  (defalias 'direnv--provided-mode-derived-p 'provided-mode-derived-p))

;;;###autoload
(defun direnv-update-environment (&optional file-name force-summary)
  "Update the environment for FILE-NAME.

See `direnv-update-directory-environment' for FORCE-SUMMARY."
  (interactive)
  (when (called-interactively-p 'interactive)
    (setq force-summary t))
  (direnv-update-directory-environment
   (if file-name (file-name-directory file-name) (direnv--directory))
   force-summary))

;;;###autoload
(defun direnv-update-directory-environment (&optional directory force-summary)
  "Update the environment for DIRECTORY.

When FORCE-SUMMARY is non-nil or when called interactively, show a summary message."
  (interactive)
  (let ((directory (or directory default-directory))
        (old-directory direnv--active-directory)
        (items)
        (summary)
        (show-summary (or force-summary (called-interactively-p 'interactive))))
    (when (file-remote-p directory)
      (user-error "Cannot use direnv for remote files"))
    (setq direnv--active-directory directory
          items (direnv--export direnv--active-directory)
          summary (direnv--summarise-changes items))
    (when (and direnv-always-show-summary (not (string-empty-p summary)))
      (setq show-summary t))
    (when show-summary
      (direnv--show-summary summary old-directory direnv--active-directory))
    (dolist (pair items)
      (let ((name (car pair))
            (value (cdr pair)))
        (setenv name value)
        (when (string-equal name "PATH")
          (setq exec-path (append (parse-colon-path value) (list exec-directory)))
          ;; Prevent `eshell-path-env` getting out-of-sync with $PATH:
          (when (derived-mode-p 'eshell-mode)
            (setq eshell-path-env value)))))))

;;;###autoload
(defun direnv-allow ()
  "Run ‘direnv allow’ and update the environment afterwards."
  (interactive)
  (call-process (direnv--detect) nil 0 nil "allow")
  (direnv-update-environment))

;;;###autoload
(define-minor-mode direnv-mode
  "Global minor mode to automatically update the environment using direnv.

When this mode is active, the environment inside Emacs will be
continuously updated to match the direnv environment for the currently
visited (local) file."
  :global t
  (if direnv-mode
      (direnv--enable)
    (direnv--disable)))

;;;###autoload
(define-derived-mode direnv-envrc-mode
  sh-mode "envrc"
  "Major mode for .envrc files as used by direnv.

Since .envrc files are shell scripts, this mode inherits from `sh-mode'.
\\{direnv-envrc-mode-map}")

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.envrc\\'" . direnv-envrc-mode))

(provide 'direnv)

;;; direnv.el ends here
