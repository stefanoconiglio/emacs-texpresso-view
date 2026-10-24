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
;; SPC / DEL) turn the pages; q closes the window.  The page fits its window,
;; in the colours of the Emacs theme.
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

(defun texpresso-view--show (file page count width height)
  "Show the PNG FILE, page PAGE (from 0) of COUNT, WIDTH x HEIGHT pixels."
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
  "Take TeXpresso's `page-image' and `selected-text' messages.
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
  "Next page."
  (interactive)
  (texpresso--send 'next-page))

(defun texpresso-view-previous ()
  "Previous page."
  (interactive)
  (texpresso--send 'previous-page))

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
  (setq texpresso-view--source nil)
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
    (setq texpresso-view--source source)
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
      (texpresso-view--send-size))))

(add-hook 'window-size-change-functions #'texpresso-view--send-size)

(provide 'texpresso-view)
;;; texpresso-view.el ends here
