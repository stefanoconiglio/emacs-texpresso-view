;;; texpresso-view.el --- TeXpresso's live view inside Emacs  -*- lexical-binding: t -*-

;; Author: Stefano Coniglio
;; URL: https://github.com/stefanoconiglio/emacs-texpresso-view
;; Version: 0.1
;; Package-Requires: ((emacs "29.1") (texpresso "0"))
;; Keywords: tex
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.  See the file LICENSE.

;;; Commentary:

;; TeXpresso (https://github.com/let-def/texpresso) re-typesets a LaTeX
;; document as you type and shows its pages in a window of its own.  This
;; package shows them inside Emacs instead, in the window to the right of the
;; source, the way pdf-tools shows a PDF: TeXpresso renders the page on
;; display as a PNG, Emacs displays it.  No PDF is made: TeXpresso draws
;; XeTeX's page descriptions directly, which is why it is fast.
;;
;; M-x texpresso-view in a LaTeX buffer: TeXpresso on that file, with no window
;; of its own, and its page on the right, following the cursor and updating
;; as you type.  Run it again to close it.  In the page's window: a click
;; jumps to the source line under it (or says there is none); a drag copies
;; the text it crosses, highlighted on the page; n / p (or PageDown / PageUp,
;; SPC / DEL, the mouse wheel) turn the pages; q closes the window.  The page
;; fits its window, in the colours of the Emacs theme.
;;
;; Scroll sync, both ways: a page turned brings its source to the top of the
;; source window (a beamer frame's \begin{frame}, in whichever file it is); a
;; scroll of the source brings the page of the line at its top.  Moving the
;; cursor brings the cursor's page, as `texpresso-follow-cursor' does.
;;
;; It needs a TeXpresso with the commands `render-to', `click-at' and
;; `select' (and its rerun fixes): until they are upstream, TeXpresso built
;; with the patches in the folder texpresso/ of this package's repository.

;;; Code:

(require 'texpresso)

(defconst texpresso-view-buffer-name "*TeXpresso window*"
  "Name of the buffer showing the page.
texpresso.el knows it: a click answered while it is current opens the source
in another window instead of replacing it.")

(defvar texpresso-view--size nil
  "The size last asked of TeXpresso, (WIDTH . HEIGHT) in pixels.")

(defvar texpresso-view--source nil
  "The buffer whose file TeXpresso shows.")

(defvar texpresso-view--image nil
  "The image on display, to free it from the image cache when replaced.")

(defun texpresso-view--file ()
  "The PNG TeXpresso writes the page to."
  (expand-file-name (format "texpresso-view-%d.png" (emacs-pid))
                    temporary-file-directory))

(defun texpresso-view--window ()
  "The window showing the page, if any."
  (get-buffer-window texpresso-view-buffer-name t))

(defun texpresso-view--send-size (&rest _)
  "Ask TeXpresso for the page at the size of its window; stop when it has none."
  (when (process-live-p texpresso--process)
    (let* ((win (texpresso-view--window))
           (size (and win (cons (window-body-width win t)
                                (window-body-height win t)))))
      (unless (equal size texpresso-view--size)
        (setq texpresso-view--size size)
        (if size
            (texpresso--send 'render-to (texpresso-view--file) (car size) (cdr size))
          (texpresso--send 'render-to "" 0 0))))))

(defun texpresso-view--show (file page count width height &optional source line)
  "Show the PNG FILE, page PAGE (from 0) of COUNT, WIDTH x HEIGHT pixels.
SOURCE and LINE: where the page starts in the source, if TeXpresso knows."
  (texpresso-view--page-shown page source line)
  (let ((buf (get-buffer texpresso-view-buffer-name)))
    (when (and buf (file-readable-p file))
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (data (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally file)
                      (buffer-string))))
          (when texpresso-view--image
            (image-flush texpresso-view--image))
          (setq texpresso-view--image
                (create-image data 'png t :scale 1.0 :width width :height height))
          (erase-buffer)
          ;; Centre the page in its window: TeXpresso fits it to the window,
          ;; so one side is filled and the other has room to share out.
          (let* ((win (texpresso-view--window))
                 (left (if win (max 0 (/ (- (window-body-width win t) width) 2)) 0))
                 (top (if win (max 0 (/ (- (window-body-height win t) height) 2)) 0)))
            (when (> top (frame-char-height))
              (insert (propertize " " 'display `(space :width (1) :height (,top)))
                      "\n"))
            (when (> left 0)
              (insert (propertize " " 'display `(space :width (,left))))))
          (insert-image texpresso-view--image)
          (goto-char (point-min))
          (setq mode-line-process (format " %d/%d" (1+ page) count))
          (force-mode-line-update))))))

(defvar texpresso-view--click-pending nil
  "Non-nil from a click in the page until TeXpresso answers with its source.")

(defun texpresso-view--dispatch (_process expr)
  "Take TeXpresso's message EXPR if it is a `page-image' or `selected-text'.
Let texpresso.el have the others."
  (pcase (car-safe expr)
    ('page-image
     (apply #'texpresso-view--show (cdr expr))
     t)
    ('selected-text
     (let ((text (string-trim (nth 1 expr))))
       (if (string-empty-p text)
           (message "TeXpresso: no text there")
         (kill-new text)
         (message "Copied: %s" (truncate-string-to-width
                                (replace-regexp-in-string "\n" " " text) 70 nil nil "…"))))
     t)
    ('synctex
     (setq texpresso-view--click-pending nil)
     nil)))

(advice-add 'texpresso--stdout-dispatch :before-until #'texpresso-view--dispatch)

(defun texpresso-view--object-xy (event)
  "The points where EVENT starts and ends, in pixels of the page image.
The end is measured from the start, so a drag that leaves the image still
counts."
  (let* ((start (event-start event))
         (end (event-end event))
         (a (posn-object-x-y start))
         (sx (posn-x-y start))
         (ex (posn-x-y end)))
    (when a
      (list (car a) (cdr a)
            (+ (car a) (- (car ex) (car sx)))
            (+ (cdr a) (- (cdr ex) (cdr sx)))))))

(defun texpresso-view-click (event)
  "Jump to the source of the point of the page clicked in EVENT."
  (interactive "e")
  (let ((xy (posn-object-x-y (event-start event))))
    (when (and xy (process-live-p texpresso--process))
      (setq texpresso-view--click-pending t)
      (texpresso--send 'click-at (car xy) (cdr xy))
      (run-with-timer
       0.6 nil
       (lambda ()
         (when texpresso-view--click-pending
           (setq texpresso-view--click-pending nil)
           (message "TeXpresso: no source line there")))))))

(defun texpresso-view-select (event)
  "Copy the text of the page from where the drag EVENT starts to where it ends.
TeXpresso highlights it in the page."
  (interactive "e")
  (let ((pts (texpresso-view--object-xy event)))
    (when (and pts (process-live-p texpresso--process))
      (apply #'texpresso--send 'select pts))))

(defun texpresso-view-next ()
  "Next page; the source shows where it starts."
  (interactive)
  (texpresso-view--turn 1))

(defun texpresso-view-previous ()
  "Previous page; the source shows where it starts."
  (interactive)
  (texpresso-view--turn -1))

(defvar texpresso-view--wheel-time 0
  "When the mouse wheel last turned a page.")

(defun texpresso-view-wheel (event)
  "Turn the page with the mouse wheel EVENT, one page every 0.3 s at most.
A touchpad sends many wheel events for one stroke."
  (interactive "e")
  (when (> (- (float-time) texpresso-view--wheel-time) 0.3)
    (setq texpresso-view--wheel-time (float-time))
    (texpresso-view--turn
     (if (memq (event-basic-type event) '(wheel-down mouse-5)) 1 -1))))

;;; Scroll sync: the source follows the pages turned, the page the source
;;; scrolled.  TeXpresso's own `texpresso-follow-cursor' moves the page to
;;; the cursor's line after every other command.

(defvar texpresso-view--source-window nil
  "The window the source was in when the view opened.")

(defvar texpresso-view--page nil
  "The page on display, from 0.")

(defvar texpresso-view--turn nil
  "A page turned from the view and not yet shown: (PAGE . TIME asked).")

(defvar texpresso-view--scroll-timer nil
  "The pending move of the page to a scrolled source.")

(defconst texpresso-view--page-commands
  '(texpresso-view-click texpresso-view-select texpresso-view-next
    texpresso-view-previous texpresso-view-wheel ignore)
  "Commands of the page's window: after them the page does not follow the cursor.
A click or the wheel on the page leaves the source window selected.")

(defun texpresso-view--source-window ()
  "The window of the source, if any."
  (cond ((window-live-p texpresso-view--source-window)
         texpresso-view--source-window)
        ((buffer-live-p texpresso-view--source)
         (get-buffer-window texpresso-view--source))))

(defun texpresso-view--turn (step)
  "Turn STEP pages, and have the source follow once the page is shown."
  (when (process-live-p texpresso--process)
    (let* ((turn texpresso-view--turn)
           (from (if (and turn (< (- (float-time) (cdr turn)) 2))
                     (car turn)
                   texpresso-view--page)))
      (when from
        (setq texpresso-view--turn (cons (+ from step) (float-time)))))
    (texpresso--send (if (> step 0) 'next-page 'previous-page))))

(defun texpresso-view--page-shown (page source line)
  "PAGE is on display, starting at LINE of SOURCE: follow it if it was turned."
  (setq texpresso-view--page page)
  (let ((turn texpresso-view--turn))
    (when (and turn (= page (car turn)))
      (setq texpresso-view--turn nil)
      (when (and source (< (- (float-time) (cdr turn)) 2))
        (texpresso-view--show-source source line)))))

(defun texpresso-view--page-start (pos)
  "Where the page whose source starts at POS begins: a frame's \\begin{frame}.
Beamer typesets a frame when it reads its \\end{frame}, which SyncTeX
gives as the frame's source."
  (save-excursion
    (goto-char pos)
    (or (and (looking-at "[ \t]*\\\\end{frame}")
             (re-search-backward "^[ \t]*\\\\begin{frame}" nil t)
             (line-beginning-position))
        pos)))

(defun texpresso-view--show-source (file line)
  "Show LINE of FILE at the top of the source window, the cursor on it."
  (let* ((file (expand-file-name file))
         (win (texpresso-view--source-window))
         (buf (and win (or (find-buffer-visiting file)
                           (and (file-exists-p file) (find-file-noselect file))))))
    (when buf
      (unless (eq (window-buffer win) buf)
        (set-window-buffer win buf))
      (let ((pos (with-current-buffer buf
                   (save-restriction
                     (widen)
                     (goto-char (point-min))
                     (forward-line (1- line))
                     (texpresso-view--page-start (point))))))
        (set-window-point win pos)
        (set-window-start win pos)))))

(defun texpresso-view--scroll-command-p (command)
  "Non-nil if COMMAND scrolls (the mouse wheel, \\[scroll-up-command] …)."
  (and command (symbolp command)
       (string-match-p "scroll" (symbol-name command))))

(defun texpresso-view--source-scrolled (win _start)
  "After a scroll command moved WIN, the source window, show its top line's page.
Waits for the scrolling to pause."
  (when (and (eq win (texpresso-view--source-window))
             (texpresso-view--scroll-command-p last-command)
             (process-live-p texpresso--process)
             (texpresso-view--window))
    (when (timerp texpresso-view--scroll-timer)
      (cancel-timer texpresso-view--scroll-timer))
    (setq texpresso-view--scroll-timer
          (run-with-timer 0.15 nil #'texpresso-view--follow-scroll win))))

(defun texpresso-view--input-file (pos)
  "The file that the \\input or \\include on the line at POS reads, if any."
  (save-excursion
    (goto-char pos)
    (when (looking-at "[ \t]*\\\\\\(?:input\\|include\\){\\([^}]+\\)}")
      (let ((file (expand-file-name (match-string 1))))
        (seq-find #'file-exists-p (list file (concat file ".tex")))))))

(defun texpresso-view--follow-scroll (win)
  "Show the page of the line at the top of WIN.
An \\input line stands for the start of the file it reads: SyncTeX knows
the pages typeset from it by that file's lines."
  (setq texpresso-view--scroll-timer nil)
  (when (and (window-live-p win) (process-live-p texpresso--process))
    (with-current-buffer (window-buffer win)
      (when (buffer-file-name)
        (let* ((start (save-excursion
                        ;; blank lines and comments have no page: the
                        ;; first line with text below stands for them
                        (goto-char (window-start win))
                        (while (and (looking-at "[ \t]*\\(?:%.*\\)?$")
                                    (zerop (forward-line 1))
                                    (not (eobp))))
                        (point)))
               (input (texpresso-view--input-file start)))
          (if input
              (texpresso--send 'synctex-forward input 1)
            (texpresso--send 'synctex-forward (buffer-file-name)
                             (line-number-at-pos start t))))))))

(defun texpresso-view--follow-cursor-p ()
  "Nil while the view is open, after a scroll or a command of the page's window.
The page then follows the scroll or the page turned, not the cursor."
  (not (and (buffer-live-p texpresso-view--source)
            (or (memq this-command texpresso-view--page-commands)
                (texpresso-view--scroll-command-p this-command)))))

(advice-add 'texpresso--post-command :before-while #'texpresso-view--follow-cursor-p)
(add-hook 'window-scroll-functions #'texpresso-view--source-scrolled)

(defvar texpresso-view-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'texpresso-view-click)
    (define-key map [drag-mouse-1] #'texpresso-view-select)
    (define-key map [down-mouse-1] #'ignore)
    (define-key map (kbd "n") #'texpresso-view-next)
    (define-key map (kbd "p") #'texpresso-view-previous)
    (define-key map (kbd "<next>") #'texpresso-view-next)
    (define-key map (kbd "<prior>") #'texpresso-view-previous)
    (define-key map (kbd "SPC") #'texpresso-view-next)
    (define-key map (kbd "DEL") #'texpresso-view-previous)
    (define-key map [wheel-down] #'texpresso-view-wheel)
    (define-key map [wheel-up] #'texpresso-view-wheel)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keys of the page window.")

(define-derived-mode texpresso-view-mode special-mode "TeXpresso"
  "TeXpresso's page, beside the source.
\\{texpresso-view-mode-map}"
  (setq-local cursor-type nil)
  (setq-local display-line-numbers nil)
  (setq-local mode-line-process nil))

;;;###autoload
(defun texpresso-view ()
  "Show TeXpresso's live view of this LaTeX file in the window to the right.
Run it again in the same buffer to close the view and stop TeXpresso; in
another LaTeX buffer, it shows that file instead."
  (interactive)
  (if (and (eq (current-buffer) texpresso-view--source)
           (process-live-p texpresso--process)
           (texpresso-view--window))
      (texpresso-view--stop)
    (texpresso-view--start)))

(defvar pdf-view-scroll-sync-mode)
(declare-function pdf-view-scroll-sync-mode "pdf-view-scroll-sync")

(defun texpresso-view--stop ()
  "Close the page's window and stop TeXpresso."
  (let ((win (texpresso-view--window)))
    (when (and win (not (one-window-p t)))
      (delete-window win)))
  (when (process-live-p texpresso--process)
    (kill-process texpresso--process))
  (when (buffer-live-p texpresso-view--source)
    (with-current-buffer texpresso-view--source
      (texpresso-mode -1)))
  (when (timerp texpresso-view--scroll-timer)
    (cancel-timer texpresso-view--scroll-timer))
  (setq texpresso-view--source nil
        texpresso-view--source-window nil
        texpresso-view--scroll-timer nil
        texpresso-view--page nil
        texpresso-view--turn nil)
  (when (get-buffer texpresso-view-buffer-name)
    (kill-buffer texpresso-view-buffer-name))
  (setq texpresso-view--size nil)
  (message "TeXpresso view closed"))

(defun texpresso-view--start ()
  "Start TeXpresso on this buffer's file, its page in the window to the right.
TeXpresso opens no window of its own: it draws with SDL's offscreen driver
and writes the page on display as a PNG that the window shows.  Its reruns
are turned on: after a pause, if the .aux file changed, it typesets again
with the previous pass's references, as a second pdflatex pass would
\(beamer's total slide count, the table of contents, \\ref).  In this
buffer `pdf-view-scroll-sync-mode' is turned off, so that saving does not
also compile with latexmk."
  (unless (buffer-file-name)
    (user-error "TeXpresso view: this buffer has no file"))
  (unless (display-images-p)
    (user-error "TeXpresso view needs a graphical frame (it shows images)"))
  (let ((source (current-buffer))
        (process-environment (append '("SDL_VIDEO_DRIVER=offscreen"
                                       "SDL_VIDEODRIVER=offscreen")
                                     process-environment)))
    (setq texpresso-view--size nil)
    (when (and (buffer-live-p texpresso-view--source)
               (not (eq texpresso-view--source source)))
      (with-current-buffer texpresso-view--source
        (texpresso-mode -1)))
    (setq texpresso-view--source source
          texpresso-view--page nil
          texpresso-view--turn nil)
    (when (bound-and-true-p pdf-view-scroll-sync-mode)
      (pdf-view-scroll-sync-mode -1))
    (texpresso (buffer-file-name))
    (when (process-live-p texpresso--process)
      (texpresso--send 'rerun t))
    (let ((buf (get-buffer-create texpresso-view-buffer-name))
          (win (or (texpresso-view--window)
                   (split-window (selected-window) nil 'right))))
      (with-current-buffer buf
        (texpresso-view-mode)
        ;; global-display-line-numbers-mode turns them on once the mode is
        ;; set: their gutter pushed the page right and cut it off
        (when (bound-and-true-p display-line-numbers-mode)
          (display-line-numbers-mode -1)))
      (set-window-buffer win buf)
      (set-window-dedicated-p win t)
      (select-window (get-buffer-window source))
      (setq texpresso-view--source-window (selected-window))
      (texpresso-view--send-size))))

(add-hook 'window-size-change-functions #'texpresso-view--send-size)

(provide 'texpresso-view)
;;; texpresso-view.el ends here
