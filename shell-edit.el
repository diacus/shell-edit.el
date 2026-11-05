;;; shell-edit.el --- Edit a shell's command line -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Diacus Magnuz

;; Author: Diacus Magnuz
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: processes, terminals, comint
;; URL: https://github.com/diacus/shell-edit
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The shells keep their unfinished command line in different places:
;; vterm and a char-mode term carry it inside the pty, where only
;; readline -- or zle -- can reach it; eshell and the comint buffers
;; (M-x shell, and any other comint REPL) keep it in the buffer
;; itself, between `process-mark' and the end of the buffer.  Wherever
;; it rests, `C-x C-e' hands it over to an Emacs buffer, mirroring
;; readline's `edit-and-execute-command'.  The edit lands in a fresh
;; buffer, displayed as `shell-edit-display-style' says -- ordinary
;; window rules by default, a dedicated frame as an option -- where
;;
;;   `C-c C-c'  accepts the edit: it is placed back on the shell's
;;              prompt, ready to run with RET -- nothing is executed;
;;   `C-c C-k'  (or plain `C-x k') discards it, leaving the prompt
;;              untouched.
;;
;; The read and the put-back are backend-specific, which is what the
;; per-shell commands exist for.  Each is bound automatically in its
;; shell's mode map as `C-x C-e' once the mode is loaded:
;;
;;   `shell-edit-vterm'    vterm-mode, through the pty;
;;   `shell-edit-eshell'   eshell-mode, in the buffer;
;;   `shell-edit-comint'   comint-mode, in the buffer (any REPL);
;;   `shell-edit-term'     term-mode, char and line mode both.
;;
;; In a term buffer's char mode the plain `C-x' prefix is rebuilt, not
;; shadowed: `C-x C-e' opens the editor while every other raw `C-x'
;; chord keeps reaching the inferior's pty untouched.
;;
;; `shell-edit' dispatches on the current buffer's mode, for shells
;; and setups that would rather bind one command.

;;; Code:

(require 'comint)

;; What the shells define in their own libraries; keeping the byte
;; compiler quiet about the free references, nothing is loaded.
(declare-function vterm-send-key "vterm")
(declare-function vterm-insert "vterm")
(declare-function vterm-reset-cursor-point "vterm")
(declare-function vterm--get-cursor-point "vterm")
(declare-function vterm--get-end-of-line "vterm")
(declare-function term-in-char-mode "term")
(declare-function term-send-raw-string "term")
(declare-function term-check-proc "term")
(eval-when-compile
  (defvar vterm--process)
  (defvar eshell-last-output-end)
  (defvar eshell-mode-map)
  (defvar vterm-mode-map)
  (defvar term-mode-map)
  (defvar term-raw-map))

(defgroup shell-edit nil
  "Edit a shell's command line in its own buffer."
  :group 'processes)

;;;; Shared machinery

(defcustom shell-edit-display-style 'window
  "How the shell edit buffer is displayed.

The value `window' displays it through `pop-to-buffer', with
whatever the ordinary window-display rules decide.  The value
`frame' shows it in a dedicated frame, deleted when the edit is
done; on a text terminal, where no frame can be popped, the `frame'
style falls back to the `window' display.  The value `auto' keeps
the historical behavior: `frame' when Emacs is graphic, `window'
otherwise.  Any other non-nil value is a function receiving the
edit BUFFER, which should return the frame it created, or nil when
BUFFER went to a window of the current frame."
  :type '(choice
          (const :tag "Window display rules" window)
          (const :tag "Dedicated frame" frame)
          (const :tag "Frame when graphic" auto)
          (function :tag "Custom display function"))
  :group 'shell-edit)

(defvar shell-edit--counter 0
  "Counter to generate unique names for shell edit buffers.")

(defvar-local shell-edit--source nil
  "The shell buffer whose command line is being edited.")

(defvar-local shell-edit--frame nil
  "The frame `shell-edit--open' created for this buffer, or nil.")

(defvar-local shell-edit--put-back nil
  "Function of \(SOURCE-BUFFER TEXT\) placing TEXT on the shell prompt.")

(defun shell-edit--display-in-window (buffer)
  "Display BUFFER through the ordinary window-display rules.
Always returns nil: no frame was created."
  (pop-to-buffer buffer)
  nil)

(defun shell-edit--display-in-frame (buffer)
  "Pop up a fresh, dedicated frame displaying BUFFER.

The usual case when Emacs runs as a daemon.  Return the frame
that was created, or nil when BUFFER went to a window of the
current frame."
  (let ((previous (selected-frame))
        (window (display-buffer
                 buffer
                 '((display-buffer-pop-up-frame)
                   (reusable-frames . nil)
                   (dedicated . t)))))
    (when (and (window-live-p window)
               (not (eq (window-frame window) previous)))
      (select-frame-set-input-focus (window-frame window))
      (window-frame window))))

(defun shell-edit--display (buffer)
  "Display BUFFER for editing, per `shell-edit-display-style'.
The frame returned, when any, is deleted with the edit buffer.
An unknown symbol value behaves like the `window' style, the
most harmless guess the display can make."
  (pcase shell-edit-display-style
    ('window (shell-edit--display-in-window buffer))
    ((pred functionp) (funcall shell-edit-display-style buffer))
    ((or 'frame 'auto)
     (if (display-graphic-p)
         (shell-edit--display-in-frame buffer)
       (shell-edit--display-in-window buffer)))
    (_ (shell-edit--display-in-window buffer))))

(defun shell-edit--close-display ()
  "Quit the window and the frame displaying this edit buffer.

Added to `kill-buffer-hook' by `shell-edit--open': the frame
`shell-edit--display-in-frame' created, when any, is deleted as
long as it still comes with the edit buffer, and every other
window showing the buffer is quit -- deleted when it was created
for the buffer, restored to its previous buffer when the display
only borrowed it.  `quit-restore-window' kills the buffer when it
quits it, so this hook re-enters `kill-buffer' once, with nothing
left to quit.

Everything anchors on EDIT, the buffer captured at entry:
`delete-frame' reselects the surviving frame's window, which
switches the current buffer away from the edit buffer -- reading
`current-buffer' after it would hand the quitting to the shell's
own window, and the shell buffer would go down with the edit."
  (let* ((edit (current-buffer))
         (frame (and shell-edit--frame
                     (frame-live-p shell-edit--frame)
                     shell-edit--frame)))
    ;; The dedicated frame: delete it while its windows still show
    ;; the edit buffer, before anything switches them away.
    (when (and frame
               (memq edit (mapcar #'window-buffer (window-list frame 'never))))
      (delete-frame frame))
    ;; The remaining windows, the frame's own excluded.
    (dolist (window (get-buffer-window-list edit nil t))
      (unless (and frame (eq (window-frame window) frame))
        (quit-restore-window window 'kill)))))

(defun shell-edit-accept ()
  "Place the edited line back on the shell prompt, without executing it.
The transfer goes through `shell-edit--put-back'; running the
command on the fresh line stays with the shell's own RET.  The
buffer is killed *before* the transfer: killing hands the window
back to the shell buffer, which redisplay remembers with an old
stale point, and the put-back -- which leaves the shell's point at
the end of its pending input, where RET sends it -- must have the
last word on that."
  (interactive)
  (let* ((source shell-edit--source)
         (put-back shell-edit--put-back)
         (text (string-trim-right
                (buffer-substring-no-properties
                 (point-min) (point-max)))))
    (kill-buffer (current-buffer))
    (if (not (and put-back
                  (bufferp source)
                  (buffer-live-p source)))
        (message "shell edit: the shell is gone, discarding the edit")
      (funcall put-back source text))))

(defun shell-edit-abort ()
  "Leave the shell prompt untouched and discard the edit buffer."
  (interactive)
  (kill-buffer (current-buffer)))

(defconst shell-edit-edit-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'shell-edit-accept)
    (define-key map (kbd "C-c C-k") #'shell-edit-abort)
    map)
  "Keys of a shell edit buffer.
\\<shell-edit-edit-map>\\[shell-edit-accept] accepts the edit,
\\[shell-edit-abort] discards it.")

(defun shell-edit--open (source line put-back)
  "Open a fresh buffer with LINE, the command line of the SOURCE shell.
PUT-BACK receives (SOURCE TEXT) when the edit is accepted.  The
buffer is displayed as `shell-edit-display-style' says, and there
\\<shell-edit-edit-map>\\[shell-edit-accept] places the edit back on the
shell's prompt,
while \\[shell-edit-abort] -- or plain `kill-buffer' -- discards it."
  (with-current-buffer
      (generate-new-buffer
       (format "*shell edit %d*"
               (setq shell-edit--counter (1+ shell-edit--counter))))
    (setq-local shell-edit--source source)
    (setq-local shell-edit--put-back put-back)
    (setq-local shell-edit--frame
                (shell-edit--display (current-buffer)))
    (add-hook 'kill-buffer-hook #'shell-edit--close-display)
    (insert line)
    (goto-char (point-max))
    (use-local-map shell-edit-edit-map)
    (current-buffer)))

;;;; Comint (M-x shell, and any other comint REPL)

(defun shell-edit--comint-input-start ()
  "Return the position where the pending input rests in this buffer.
The region `comint-send-input' sends on RET: the accumulated
lines of `comint-accumulate' and the plain typed-ahead input all
rest after `process-mark', which follows the end of the last
prompt."
  (process-mark (get-buffer-process (current-buffer))))

(defun shell-edit--comint-process-live-p ()
  "Return t when the shell process of this comint buffer is alive."
  (and (get-buffer-process (current-buffer))
       (process-live-p (get-buffer-process (current-buffer)))))

(defun shell-edit-comint-read-line ()
  "Return the current command line in this comint buffer.
Everything after `shell-edit--comint-input-start' is what the
buffer is carrying for the next RET -- typed-ahead and accumulated
input included; the process output, prompt included, is everything
before it."
  (buffer-substring-no-properties
   (shell-edit--comint-input-start) (point-max)))

(defun shell-edit-comint-put-back (source text)
  "Place TEXT on the shell prompt of SOURCE, without executing it.
The pending input is deleted from `process-mark' onwards and TEXT
takes its place, ready to run with RET; the `comint-accumulate'
state is reset as well, since the edit covers the accumulated
lines too.  When the shell process is no longer alive, nothing is
written and the edit is discarded."
  (if (not (with-current-buffer source
             (shell-edit--comint-process-live-p)))
      (message "shell edit: the shell is gone, discarding the edit")
    (with-current-buffer source
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (delete-region (shell-edit--comint-input-start) (point-max))
        (set-marker comint-accum-marker nil)
        (when (> (length text) 0)
          (insert text))
        (goto-char (point-max))))))

(defun shell-edit-comint ()
  "Edit the current comint command line in a fresh buffer.
Like `shell-edit-eshell' for eshell, for any comint REPL: the
`shell' buffer is where the binding lives, but inferior buffers
based on comint get the same editor, since the pending input is
delimited the same way."
  (interactive)
  (unless (shell-edit--comint-process-live-p)
    (user-error "No running shell in this comint buffer"))
  (shell-edit--open (current-buffer)
                    (shell-edit-comint-read-line)
                    #'shell-edit-comint-put-back))

;;;; Eshell

(defun shell-edit--eshell-prompting-p ()
  "Return t when this eshell buffer is accepting command input.
Eshell draws its prompt only there: the character right before
`eshell-last-output-end' carries the `prompt' field exactly while
input is pending, never in output or while a command still runs."
  (and eshell-last-output-end
       (>= (point-max) eshell-last-output-end)
       (> (point-max) (point-min))
       (eq (get-text-property
            (max (point-min)
                 (1- (marker-position eshell-last-output-end)))
            'field)
           'prompt)))

(defun shell-edit-eshell-read-line ()
  "Return the current command line in this eshell buffer.
Eshell delimits the pending input with the marker
`eshell-last-output-end', which rests right after the prompt
whenever command input is pending."
  (buffer-substring-no-properties
   eshell-last-output-end (point-max)))

(defun shell-edit-eshell-put-back (source text)
  "Place TEXT on the eshell prompt of SOURCE, without executing it.
The shell's pending input is deleted from the prompt onwards, so
the prompt is left with exactly the edits, ready to run with RET.
When the shell is no longer prompting (a command started
meanwhile), nothing is written and the edit is discarded."
  (if (not (with-current-buffer source
             (shell-edit--eshell-prompting-p)))
      (message "shell edit: the shell is gone, discarding the edit")
    (with-current-buffer source
      (goto-char (point-max))
      (delete-region eshell-last-output-end (point-max))
      (when (> (length text) 0)
        (insert text))
      (goto-char (point-max)))))

(defun shell-edit-eshell ()
  "Edit the current eshell command line in a fresh buffer.
\\<shell-edit-edit-map>\\[shell-edit-accept] puts the edited text back on
the prompt and \\[shell-edit-abort] leaves the input as it was;
nothing is executed.  The
editor refuses to edit while a command is still running, since
eshell delimits the pending input with `eshell-last-output-end'
only afterwards."
  (interactive)
  (unless (shell-edit--eshell-prompting-p)
    (user-error "A command is still running in this eshell buffer"))
  (shell-edit--open (current-buffer)
                    (shell-edit-eshell-read-line)
                    #'shell-edit-eshell-put-back))

;;;; Vterm

(defun shell-edit-vterm-read-line ()
  "Return the shell's current command line in this vterm buffer.
Readline's `C-a' is sent first, so the terminal cursor sits at the
start of the input, right after the prompt; the command line is
read from there to the end of the line, without depending on any
shell integration or prompt detection.  The side effect is that
the shell's cursor moves to the start of its input line."
  (vterm-send-key "a" nil nil t)
  (when vterm--process
    (accept-process-output vterm--process 0.5))
  (vterm-reset-cursor-point)
  (let ((beg (vterm--get-cursor-point))
        (end (vterm--get-end-of-line)))
    (substring-no-properties
     (buffer-substring (min beg end) (max beg end)))))

(defun shell-edit-vterm-put-back (source text)
  "Place TEXT on the vterm prompt of SOURCE, without executing it.
Readline's `C-a' `C-k' discards the shell's current input first --
the prompt is left with exactly the edits, ready to run with RET."
  (if (not (with-current-buffer source
             (and (bound-and-true-p vterm--term)
                  (process-live-p vterm--process))))
      (message "shell edit: the shell is gone, discarding the edit")
    (with-current-buffer source
      (vterm-send-key "a" nil nil t) ; C-a: readline, start of input
      (vterm-send-key "k" nil nil t) ; C-k: readline, kill to end
      (when (> (length text) 0)
        (vterm-insert text))
      ;; The final cursor sync races with the shell's redraw of
      ;; the cleared line; it is cosmetic here.
      (ignore-errors (vterm-reset-cursor-point)))))

(defun shell-edit-vterm ()
  "Edit the shell's current command line in a fresh buffer.
Mirrors readline's `edit-and-execute-command': the command line
after the prompt of this vterm is copied into a temporary buffer,
displayed as `shell-edit-display-style' says.  There,
\\<shell-edit-edit-map>\\[shell-edit-accept] puts the edited text back on
the prompt and \\[shell-edit-abort] discards it; nothing is
executed."
  (interactive)
  (unless (and (bound-and-true-p vterm--term)
               (process-live-p vterm--process))
    (user-error "No running shell in this vterm buffer"))
  (shell-edit--open (current-buffer)
                    (shell-edit-vterm-read-line)
                    #'shell-edit-vterm-put-back))

;;;; Term (char and line mode)

(defun shell-edit--term-read-between (beg end)
  "Return the screen text from BEG to END.
BEG and END sit at the two ends of the shell's logical command
line; the screen text between them is read through the lines the
terminal wrapped it into."
  (let (chunks)
    (save-excursion
      (goto-char beg)
      (while (< (point) end)
        (let ((stop (min (line-end-position) end)))
          (push (buffer-substring-no-properties (point) stop) chunks)
          (goto-char stop)
          (unless (eobp) (forward-char))))
      (apply #'concat (nreverse chunks)))))

(defun shell-edit-term-read-line ()
  "Return the shell's current command line in this term buffer.
In char mode readline's `C-e' and `C-a' are sent first: `C-e'
parks the terminal cursor -- which `process-mark' follows -- at
the end of the logical line and `C-a' at its start; the command
line is the screen text between the two, without any shell
integration or prompt detection.  In line mode nothing is sent to
the pty: the pending input is the text between the process mark
and the end of the buffer."
  (let ((proc (get-buffer-process (current-buffer))))
    (if (term-in-char-mode)
        (progn
          (term-send-raw-string "\C-e")
          (when proc (accept-process-output proc 0.5))
          (let ((end (marker-position (process-mark proc))))
            (term-send-raw-string "\C-a")
            (when proc (accept-process-output proc 0.5))
            (shell-edit--term-read-between
             (marker-position (process-mark proc)) end)))
      (buffer-substring-no-properties
       (process-mark proc) (point-max)))))

(defun shell-edit-term-put-back (source text)
  "Place TEXT on the term prompt of SOURCE, without executing it.
In char mode readline's `C-a' `C-k' discards the shell's current
input first, like the vterm backend does, TEXT is then sent
verbatim, and `C-l' redraws the line: the redraw rewrites the
line's whole wrapped width, which the terminal emulator needs when
the edit replaces a line of another length -- without it the
screen and the read that follows keep stale wrapped rows.  In line
mode the shell's pending input is deleted from the process mark
onwards -- `shell-edit-comint-put-back' style -- so the prompt is
left with exactly the edits, ready to run with RET."
  (if (not (with-current-buffer source
             (term-check-proc (current-buffer))))
      (message "shell edit: the shell is gone, discarding the edit")
    (with-current-buffer source
      (if (term-in-char-mode)
          (progn
            (term-send-raw-string "\C-a")
            (term-send-raw-string "\C-k")
            (when (> (length text) 0)
              (term-send-raw-string text))
            (term-send-raw-string "\C-l"))
        (let ((inhibit-read-only t)
              (proc (get-buffer-process (current-buffer))))
          (goto-char (point-max))
          (delete-region (process-mark proc) (point-max))
          (when (> (length text) 0)
            (insert text))
          (goto-char (point-max)))))))

(defun shell-edit-term ()
  "Edit the shell's current command line in a fresh buffer.
Like `shell-edit-vterm', mirroring readline's
`edit-and-execute-command': the command line of this term -- char
or line mode, whichever the buffer is in -- is copied into a
temporary buffer, displayed as `shell-edit-display-style' says.
There, \\<shell-edit-edit-map>\\[shell-edit-accept] puts the edited text back
on the prompt and \\[shell-edit-abort] discards it; nothing is
executed."
  (interactive)
  (unless (term-check-proc (current-buffer))
    (user-error "No running shell in this term buffer"))
  (shell-edit--open (current-buffer)
                    (shell-edit-term-read-line)
                    #'shell-edit-term-put-back))

(defun shell-edit--term-send-raw-keys ()
  "Send the command's whole key sequence to the inferior's pty.
The `C-x' chords of `term-raw-map' that
`shell-edit--term-raw-ctl-x-map' does not rebind fall back on this
one: `term-send-raw' cannot serve there, because it sends only the
last event, which would strip the `C-x' off chords like `C-x'
`C-s'."
  (interactive)
  (let ((keys (this-command-keys)))
    (when (seq-every-p #'characterp keys)
      (term-send-raw-string keys))))

(defvar shell-edit--term-raw-ctl-x-map
  (let ((map (make-sparse-keymap)))
    ;; The editor is the one chord the editor itself rebinds; every
    ;; other C-x chord keeps reaching the inferior's pty through the
    ;; default binding above, so the raw C-x semantics survive.
    (define-key map "\C-e" #'shell-edit-term)
    (define-key map [t] #'shell-edit--term-send-raw-keys)
    map))

;; The terminal emulator mangles bash readline's redraw over wrapped
;; rows on its own (a retype through C-a C-k shows it too), and the
;; editor's char mode reads the screen -- the C-l redraw in the
;; put-back is what keeps the two in sync.

;;;; Dispatch

(defun shell-edit ()
  "Edit the current shell's command line in a fresh buffer.
Dispatches on the buffer's mode among the supported shells: vterm,
eshell, term and the comint modes.  Each backend binds itself in
its shell's own mode map already; this is the one command for
setups that would rather bind a single one.  Outside the
supported shells, the command refuses with a `user-error'."
  (interactive)
  (cond ((derived-mode-p 'vterm-mode) (shell-edit-vterm))
        ((derived-mode-p 'eshell-mode) (shell-edit-eshell))
        ((derived-mode-p 'term-mode) (shell-edit-term))
        ((derived-mode-p 'comint-mode) (shell-edit-comint))
        (t (user-error "No shell editor for the current buffer"))))

;;;; Automatic bindings

;; The keymap is defined by esh-mode, which eshell itself loads only
;; when the first buffer is created: waiting for the `eshell'
;; feature is not enough.
(with-eval-after-load 'esh-mode
  (define-key eshell-mode-map (kbd "C-x C-e") #'shell-edit-eshell))

(with-eval-after-load 'comint
  (define-key comint-mode-map (kbd "C-x C-e") #'shell-edit-comint))

(with-eval-after-load 'vterm
  (define-key vterm-mode-map (kbd "C-x C-e") #'shell-edit-vterm))

(with-eval-after-load 'term
  (define-key term-mode-map (kbd "C-x C-e") #'shell-edit-term)
  ;; Char mode intercepts every single key, C-x included, so the
  ;; prefix is rebuilt here instead of shadowed wholesale: a plain
  ;; C-x C-e binding would leave every other C-x chord undefined.
  (define-key term-raw-map "\C-x" shell-edit--term-raw-ctl-x-map))

(provide 'shell-edit)
;;; shell-edit.el ends here
