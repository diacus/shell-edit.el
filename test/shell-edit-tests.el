;;; shell-edit-tests.el --- Tests for shell-edit -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Diacus Magnuz

;; Author: Diacus Magnuz
;; Keywords: processes, terminals, comint
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; ERT suite for `shell-edit'.  The comint and eshell backends are
;; exercised on plain buffers dressed up the way the shells dress
;; theirs: a live, silent inferior process with `process-mark' parked
;; after the prompt text, and, for eshell, the `prompt' field on the
;; text right before `eshell-last-output-end'.  What needs a real pty
;; -- the vterm backend and term's char mode, where only readline or
;; zle can reach the line -- is not covered here.

;;; Code:

(require 'ert)
(require 'comint)
(require 'term)

(defconst se-test--project-root
  (expand-file-name ".." (file-name-directory load-file-name))
  "Directory holding `shell-edit.el', this suite's parent directory.")

(add-to-list 'load-path se-test--project-root)
(require 'shell-edit)

;; The eshell backend reads this special variable; the suite provides
;; it wherever it stands in for a real eshell buffer.
(defvar eshell-last-output-end)

;;;; Fixtures

(defun se-test--silent-process (buffer)
  "Start a live, silent inferior process for BUFFER."
  (let ((process (start-process "shell-edit-test" buffer "sleep" "60")))
    (set-process-query-on-exit-flag process nil)
    process))

(defun se-test--comint-buffer (&optional pending)
  "Return a comint buffer with a live shell and prompt.
PENDING is the pending command line sitting after the prompt."
  (let ((buffer (generate-new-buffer " *se-test-comint*")))
    (with-current-buffer buffer
      (comint-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "user@host:~$ ")
        (set-marker (process-mark (se-test--silent-process buffer))
                    (point))
        (setq comint-accum-marker (copy-marker (point)))
        (when pending
          (insert pending))
        (goto-char (point-max))))
    buffer))

(defun se-test--eshell-buffer (&optional pending prompt-field)
  "Return a buffer dressed up as an idle eshell.
The text before `eshell-last-output-end' is the prompt, carrying
PROMPT-FIELD on it as eshell does while input is pending; PENDING
is the command line after the prompt."
  (let ((buffer (generate-new-buffer " *se-test-eshell*")))
    (with-current-buffer buffer
      (erase-buffer)
      (insert (propertize "user@host:~$ " 'field prompt-field))
      (setq-local eshell-last-output-end (copy-marker (point)))
      (when pending
        (insert pending)))
    buffer))

(defun se-test--term-line-buffer (&optional pending)
  "Return a line-mode-like term buffer, PENDING after the prompt.
`term-in-char-mode' is false here, so the term backend reads and
writes the plain buffer text around `process-mark', the way the
comint backend does."
  (let ((buffer (generate-new-buffer " *se-test-term*")))
    (with-current-buffer buffer
      (term-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "user@host:~$ ")
        (set-marker (process-mark (se-test--silent-process buffer))
                    (point))
        (when pending
          (insert pending))
        (goto-char (point-max))))
    buffer))

(defun se-test--kill (buffer)
  "Delete BUFFER's inferior process when any, then BUFFER itself."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((process (get-buffer-process buffer)))
        (when (and process (process-live-p process))
          (delete-process process))))
    (kill-buffer buffer)))

;;;; Shared machinery

(ert-deftest shell-edit-test-open-edit-buffer ()
  "`shell-edit--open' opens a fresh edit buffer for SOURCE.
The buffer carries the line, the buffer-locals of the put-back
contract, and point at the end of the line."
  (let* ((source (generate-new-buffer " *se-test-source*"))
         (edit (shell-edit--open source "echo hello" #'ignore)))
    (unwind-protect
        (with-current-buffer edit
          (should (string-prefix-p "*shell edit " (buffer-name)))
          (should (equal (buffer-string) "echo hello"))
          (should (eq shell-edit--source source))
          (should (eq shell-edit--put-back #'ignore))
          (should (= (point) (point-max))))
      (kill-buffer edit)
      (kill-buffer source))))

(ert-deftest shell-edit-test-accept-calls-put-back ()
  "`shell-edit-accept' hands the trimmed text to the put-back.
The edit buffer dies first, and the shell buffer lives on."
  (let* ((source (generate-new-buffer " *se-test-source*"))
         (seen 'no-call)
         (edit (shell-edit--open
                source "echo hello\n"
                (lambda (src text) (setq seen (list src text))))))
    (unwind-protect
        (with-current-buffer edit
          (shell-edit-accept))
      (se-test--kill edit)
      (kill-buffer source))
    (should (equal seen (list source "echo hello")))
    (should-not (buffer-live-p edit))))

(ert-deftest shell-edit-test-accept-dead-source ()
  "`shell-edit-accept' discards the edit when the shell is gone.
Nothing reaches the put-back, and the edit buffer still dies."
  (let* ((source (generate-new-buffer " *se-test-source*"))
         (seen 'no-call)
         (edit nil))
    (kill-buffer source)
    (setq edit (shell-edit--open
                source "echo hi" (lambda (&rest _) (setq seen t))))
    (unwind-protect
        (with-current-buffer edit
          (shell-edit-accept))
      (se-test--kill edit))
    (should (eq seen 'no-call))
    (should-not (buffer-live-p edit))))

(ert-deftest shell-edit-test-accept-and-abort-refuse-outside ()
  "The accept and abort commands refuse outside an edit buffer.
Both are plain interactive commands, reachable with `M-x' in any
buffer: without the contract buffer-locals they must refuse with a
`user-error' rather than take the current buffer down with them."
  (let ((victim (generate-new-buffer " *se-test-victim*")))
    (unwind-protect
        (with-current-buffer victim
          (should-error (shell-edit-accept) :type 'user-error)
          (should-error (shell-edit-abort) :type 'user-error)
          ;; The refusals left the buffer untouched.
          (should (buffer-live-p victim)))
      (kill-buffer victim))))

(ert-deftest shell-edit-test-abort-kills-the-edit ()
  "`shell-edit-abort' kills the edit buffer, the source untouched."
  (let* ((source (generate-new-buffer " *se-test-source*"))
         (edit (shell-edit--open source "echo hi" #'ignore)))
    (unwind-protect
        (with-current-buffer edit
          (shell-edit-abort))
      (se-test--kill edit))
    (should-not (buffer-live-p edit))
    (should (buffer-live-p source))
    (kill-buffer source)))

(ert-deftest shell-edit-test-close-display-noop-when-nowhere ()
  "`shell-edit--close-display' is a no-op without anything to clean.
The buffer here was never displayed and holds no frame, so the
hook has no windows to quit and no frame to delete."
  (let ((edit (generate-new-buffer " *se-test-edit-undisplayed*")))
    (with-current-buffer edit
      (should (null shell-edit--frame))
      (shell-edit--close-display)
      (should (buffer-live-p edit)))
    (kill-buffer edit)))

(ert-deftest shell-edit-test-close-display-quits-the-window ()
  "A created editor window dies with the edit buffer, any exit path.
Accepting through \\<shell-edit-edit-map>\\[shell-edit-accept],
aborting through \\[shell-edit-abort], and a plain `kill-buffer'
-- the way `C-x k' reaches it -- all leave no window behind
showing the edit buffer, and the window count is back to what it
was before the editor was displayed."
  (let ((source (generate-new-buffer " *se-test-source*")))
    (dolist (kill-with '("accept" "abort" "plain kill"))
      (let* ((windows-before (window-list nil 'never))
             (edit (shell-edit--open source "echo hi" #'ignore))
             (kill-command
              (pcase kill-with
                (`"accept" #'shell-edit-accept)
                (`"abort" #'shell-edit-abort)
                (`"plain kill" (lambda () (kill-buffer))))))
        (unwind-protect
            (progn
              (should (get-buffer-window edit t))
              (should (equal (length (window-list nil 'never))
                             (1+ (length windows-before))))
              (with-current-buffer edit
                (funcall kill-command))
              (should-not (get-buffer-window edit t))
              (should-not (buffer-live-p edit))
              (should (equal (length (window-list nil 'never))
                             (length windows-before))))
          (se-test--kill edit)
          (kill-buffer source))))))

(ert-deftest shell-edit-test-close-display-restores-borrowed-window ()
  "A borrowed editor window is restored rather than deleted.
When the display only reused one of the shell's windows -- the
way `display-buffer' behaves with `pop-up-windows' nil -- the
window survives the quit and goes back to some other buffer."
  (let* ((shell-edit-display-style 'window)
         (pop-up-windows nil)
         (source (generate-new-buffer " *se-test-source*"))
         edit)
    (unwind-protect
        (let ((baseline (length (window-list nil 'never))))
          (setq edit (shell-edit--open source "echo hi" #'ignore))
          ;; The display borrowed an existing window: the count did
          ;; not grow, and the window holding the edit buffer is
          ;; there.
          (should (get-buffer-window edit t))
          (should (equal (length (window-list nil 'never)) baseline))
          (with-current-buffer edit
            (shell-edit-abort))
          ;; The window survives the quit: same count, no window
          ;; showing the edit buffer anywhere.
          (should (equal (length (window-list nil 'never)) baseline))
          (should-not (get-buffer-window edit t)))
      (se-test--kill edit)
      (kill-buffer source))))

(ert-deftest shell-edit-test-edit-map-keys ()
  "The edit buffer map binds the accept and abort commands.
\\<shell-edit-edit-map>\\[shell-edit-accept] accepts the edit and
\\[shell-edit-abort] discards it."
  (should (eq (lookup-key shell-edit-edit-map (kbd "C-c C-c"))
              #'shell-edit-accept))
  (should (eq (lookup-key shell-edit-edit-map (kbd "C-c C-k"))
              #'shell-edit-abort)))

(ert-deftest shell-edit-test-display-style-window ()
  "The `window' style, the default, displays per the ordinary rules.
No frame is involved, and the buffer still ends up displayed."
  (let* ((shell-edit-display-style 'window)
         (source (generate-new-buffer " *se-test-source*"))
         (edit (shell-edit--open source "echo hi" #'ignore)))
    (unwind-protect
        (with-current-buffer edit
          (should (null shell-edit--frame))
          (should (get-buffer-window edit)))
      (kill-buffer edit)
      (kill-buffer source))))

(ert-deftest shell-edit-test-display-style-frame-falls-back-on-tty ()
  "On a text terminal the `frame' style falls back to the window rules."
  (skip-unless (not (display-graphic-p)))
  (let* ((shell-edit-display-style 'frame)
         (source (generate-new-buffer " *se-test-source*"))
         (edit (shell-edit--open source "echo hi" #'ignore)))
    (unwind-protect
        (with-current-buffer edit
          (should (null shell-edit--frame))
          (should (get-buffer-window edit)))
      (kill-buffer edit)
      (kill-buffer source))))

(ert-deftest shell-edit-test-display-style-auto-on-tty ()
  "On a text terminal the `auto' style uses the window rules."
  (skip-unless (not (display-graphic-p)))
  (let* ((shell-edit-display-style 'auto)
         (source (generate-new-buffer " *se-test-source*"))
         (edit (shell-edit--open source "echo hi" #'ignore)))
    (unwind-protect
        (with-current-buffer edit
          (should (null shell-edit--frame))
          (should (get-buffer-window edit)))
      (kill-buffer edit)
      (kill-buffer source))))

(ert-deftest shell-edit-test-display-style-function ()
  "A function value of the style decides how the buffer is displayed.
The edit buffer keeps what the function returned on
`shell-edit--frame', whatever it happens to be."
  (let* ((seen nil)
         (shell-edit-display-style
          (lambda (buffer) (setq seen buffer) 'my-fake-frame))
         (source (generate-new-buffer " *se-test-source*"))
         (edit (shell-edit--open source "echo hi" #'ignore)))
    (unwind-protect
        (with-current-buffer edit
          (should (eq seen edit))
          (should (eq shell-edit--frame 'my-fake-frame)))
      (kill-buffer edit)
      (kill-buffer source))))

;;;; Comint

(ert-deftest shell-edit-test-comint-input-start ()
  "`shell-edit--comint-input-start' rests on `process-mark'."
  (let ((buffer (se-test--comint-buffer "echo hi")))
    (unwind-protect
        (with-current-buffer buffer
          (should (equal (shell-edit--comint-input-start)
                         (process-mark (get-buffer-process buffer)))))
      (se-test--kill buffer))))

(ert-deftest shell-edit-test-comint-read-line ()
  "`shell-edit-comint-read-line' returns the pending, promptless input."
  (let ((buffer (se-test--comint-buffer "echo hi")))
    (unwind-protect
        (with-current-buffer buffer
          (should (equal "echo hi" (shell-edit-comint-read-line))))
      (se-test--kill buffer))))

(ert-deftest shell-edit-test-comint-put-back ()
  "`shell-edit-comint-put-back' replaces the pending input.
The prompt and earlier output survive, the accumulation state is
reset, and point rests at the end of the new pending input."
  (let ((buffer (se-test--comint-buffer "echo old")))
    (unwind-protect
        (progn
          (shell-edit-comint-put-back buffer "echo new")
          (with-current-buffer buffer
            (should (equal "user@host:~$ echo new"
                           (buffer-substring-no-properties
                            (point-min) (point-max))))
            (should (= (point) (point-max)))
            (should (markerp comint-accum-marker))
            (should-not (marker-position comint-accum-marker))))
      (se-test--kill buffer))))

(ert-deftest shell-edit-test-comint-put-back-empty ()
  "An empty edit empties the pending input, leaving the prompt."
  (let ((buffer (se-test--comint-buffer "echo old")))
    (unwind-protect
        (progn
          (shell-edit-comint-put-back buffer "")
          (with-current-buffer buffer
            (should (equal "user@host:~$ "
                           (buffer-substring-no-properties
                            (point-min) (point-max))))
            (should (= (point) (point-max)))))
      (se-test--kill buffer))))

(ert-deftest shell-edit-test-comint-put-back-dead-shell ()
  "The comint put-back discards the edit when the shell has exited."
  (let ((buffer (se-test--comint-buffer "echo hi")))
    (unwind-protect
        (with-current-buffer buffer
          (delete-process (get-buffer-process buffer))
          (should-not (get-buffer-process buffer))
          (shell-edit-comint-put-back buffer "echo new")
          ;; The edit never arrived, and the pending input the exit
          ;; notification sits behind is untouched.
          (should-not
           (string-match-p "echo new" (buffer-string)))
          (should (string-suffix-p "echo hi" (buffer-string))))
      (se-test--kill buffer))))

(ert-deftest shell-edit-test-comint-refuses-without-shell ()
  "`shell-edit-comint' refuses when there is no running shell."
  (let ((buffer (generate-new-buffer " *se-test-comint*")))
    (unwind-protect
        (with-current-buffer buffer
          (comint-mode)
          (should-error (shell-edit-comint) :type 'user-error))
      (se-test--kill buffer))))

(ert-deftest shell-edit-test-comint-round-trip ()
  "Editing and accepting places the new line on the shell's prompt."
  (let ((buffer (se-test--comint-buffer "echo old")))
    (unwind-protect
        (let ((edit (with-current-buffer buffer (shell-edit-comint))))
          (with-current-buffer edit
            (erase-buffer)
            (insert "echo new")
            (shell-edit-accept))
          (with-current-buffer buffer
            (should (equal "user@host:~$ echo new"
                           (buffer-substring-no-properties
                            (point-min) (point-max))))
            (should (= (point) (point-max)))
            (should-not (buffer-live-p edit))))
      (se-test--kill buffer))))

;;;; Eshell

(ert-deftest shell-edit-test-eshell-prompting-p ()
  "`shell-edit--eshell-prompting-p' tells input apart from output."
  (let ((idle (se-test--eshell-buffer "echo hi" 'prompt))
        (busy (se-test--eshell-buffer "echo hi" nil)))
    (unwind-protect
        (progn
          (with-current-buffer idle
            (should (shell-edit--eshell-prompting-p))
            ;; output streaming: the marker left the buffer text
            (set-marker eshell-last-output-end (+ (point-max) 5))
            (should-not (shell-edit--eshell-prompting-p)))
          ;; a command still running: the prompt field is gone
          (with-current-buffer busy
            (should-not (shell-edit--eshell-prompting-p))))
      (se-test--kill idle)
      (se-test--kill busy))))

(ert-deftest shell-edit-test-eshell-read-line ()
  "`shell-edit-eshell-read-line' returns the input after the prompt."
  (let ((buffer (se-test--eshell-buffer "echo hi\n" 'prompt)))
    (unwind-protect
        (with-current-buffer buffer
          (should (equal "echo hi\n" (shell-edit-eshell-read-line))))
      (se-test--kill buffer))))

(ert-deftest shell-edit-test-eshell-put-back ()
  "`shell-edit-eshell-put-back' replaces the pending input.
The prompt survives and the point rests at the end of the new
input."
  (let ((buffer (se-test--eshell-buffer "echo old" 'prompt)))
    (unwind-protect
        (progn
          (shell-edit-eshell-put-back buffer "echo new")
          (with-current-buffer buffer
            (should (equal "user@host:~$ echo new"
                           (buffer-substring-no-properties
                            (point-min) (point-max))))
            (should (= (point) (point-max)))))
      (se-test--kill buffer))))

(ert-deftest shell-edit-test-eshell-put-back-empty ()
  "An empty edit leaves the prompt with no pending input."
  (let ((buffer (se-test--eshell-buffer "echo old" 'prompt)))
    (unwind-protect
        (progn
          (shell-edit-eshell-put-back buffer "")
          (with-current-buffer buffer
            (should (equal "user@host:~$ "
                           (buffer-substring-no-properties
                            (point-min) (point-max))))
            (should (= (point) (point-max)))))
      (se-test--kill buffer))))

(ert-deftest shell-edit-test-eshell-put-back-discards ()
  "The eshell put-back discards the edit when not prompting."
  (let ((buffer (se-test--eshell-buffer "echo hi" 'prompt)))
    (unwind-protect
        (progn
          ;; a command started meanwhile: the prompt field is gone
          (with-current-buffer buffer
            (remove-text-properties (point-min) (point-max) '(field)))
          (shell-edit-eshell-put-back buffer "echo new")
          (with-current-buffer buffer
            (should (equal "user@host:~$ echo hi"
                           (buffer-substring-no-properties
                            (point-min) (point-max))))))
      (se-test--kill buffer))))

(ert-deftest shell-edit-test-eshell-refuses-while-running ()
  "`shell-edit-eshell' refuses while an eshell command is running."
  (let ((buffer (se-test--eshell-buffer "echo hi" nil)))
    (unwind-protect
        (with-current-buffer buffer
          (should-error (shell-edit-eshell) :type 'user-error))
      (se-test--kill buffer))))

;;;; Term

(ert-deftest shell-edit-test-term-read-between ()
  "`shell-edit--term-read-between' joins the wrapped rows.
The logical line is the screen text from BEG to END with the row
breaks in between removed: the separators are wraps, not newline
keystrokes."
  (with-temp-buffer
    (insert "abc\ndef\nghi\n")
    (should (equal "defghi" (shell-edit--term-read-between 5 12)))
    (should (equal "abc" (shell-edit--term-read-between 1 4)))
    (should (equal "gh" (shell-edit--term-read-between 9 11)))))

(ert-deftest shell-edit-test-term-line-mode-read-line ()
  "In line mode the pending input is the text around the process mark."
  (let ((buffer (se-test--term-line-buffer "echo hi")))
    (unwind-protect
        (with-current-buffer buffer
          (should-not (term-in-char-mode))
          (should (equal "echo hi" (shell-edit-term-read-line))))
      (se-test--kill buffer))))

(ert-deftest shell-edit-test-term-line-mode-put-back ()
  "In line mode the put-back replaces the input after the process mark.
The prompt survives and the point rests at the end of the new
input."
  (let ((buffer (se-test--term-line-buffer "echo old")))
    (unwind-protect
        (progn
          (shell-edit-term-put-back buffer "echo new")
          (with-current-buffer buffer
            (should (equal "user@host:~$ echo new"
                           (buffer-substring-no-properties
                            (point-min) (point-max))))
            (should (= (point) (point-max)))))
      (se-test--kill buffer))))

(ert-deftest shell-edit-test-term-put-back-dead-shell ()
  "The term put-back discards the edit when the shell has exited."
  (let ((buffer (se-test--term-line-buffer "echo hi")))
    (unwind-protect
        (with-current-buffer buffer
          (delete-process (get-buffer-process buffer))
          (should-not (get-buffer-process buffer))
          (shell-edit-term-put-back buffer "echo new")
          ;; The edit never arrived, and the pending input the exit
          ;; notification sits behind is untouched.
          (should-not
           (string-match-p "echo new" (buffer-string)))
          (should (string-suffix-p "echo hi" (buffer-string))))
      (se-test--kill buffer))))

(ert-deftest shell-edit-test-term-refuses-without-shell ()
  "`shell-edit-term' refuses without a running shell."
  (let ((buffer (generate-new-buffer " *se-test-term*")))
    (unwind-protect
        (with-current-buffer buffer
          (should-error (shell-edit-term) :type 'user-error))
      (se-test--kill buffer))))

(ert-deftest shell-edit-test-term-raw-ctl-x-map ()
  "The rebuilt raw `C-x' prefix carries the editor and pty fallback."
  (should (eq (lookup-key shell-edit--term-raw-ctl-x-map (kbd "C-e"))
              #'shell-edit-term))
  ;; Every other chord falls back on the [t] default binding.
  (should (eq (lookup-key shell-edit--term-raw-ctl-x-map [t])
              #'shell-edit--term-send-raw-keys)))

;;;; Dispatch

(ert-deftest shell-edit-test-dispatch-refuses-elsewhere ()
  "`shell-edit' refuses outside the supported shells."
  (with-temp-buffer
    (should-error (shell-edit) :type 'user-error)))

(ert-deftest shell-edit-test-dispatch-comint ()
  "`shell-edit' routes comint buffers to the comint backend."
  (let ((buffer (se-test--comint-buffer "echo hi")))
    (unwind-protect
        (let ((edit (with-current-buffer buffer (shell-edit))))
          (unwind-protect
              (with-current-buffer edit
                (should (eq shell-edit--put-back
                            #'shell-edit-comint-put-back))
                (should (equal (buffer-string) "echo hi")))
            (se-test--kill edit)))
      (se-test--kill buffer))))

(provide 'shell-edit-tests)
;;; shell-edit-tests.el ends here
