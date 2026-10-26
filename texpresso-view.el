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
;; as you type.  Run it again to close it.  With a prefix argument (C-u), it
;; typesets AUCTeX's `TeX-master', the whole document the file is part of,
;; and the page follows that file the same way.  In the page's window: a click
;; jumps to the source line under it (or says there is none); a drag copies
;; the text it crosses, highlighted on the page; n / p (or PageDown / PageUp,
;; SPC / DEL, the mouse wheel) turn the pages; q closes the window.  The page
;; fits its window, in the colours of the Emacs theme (a terminal's own
;; when Emacs has none there), and follows a theme switched.
;;
;; Scroll sync, both ways: a page turned brings its source to the top of the
;; source window (a beamer frame's \begin{frame}, in whichever file it is); a
;; scroll of the source brings the page of the line at its top.  Moving the
;; cursor brings the cursor's page, as `texpresso-follow-cursor' does.
;;
;; Errors: when the text stops TeX (a brace left open to the end of the
;; file, a missing \end{document}), a red line over the page says so and
;; why, until the text is mended; other errors are counted in the page
;; window's mode line.
;;
;; In a text terminal (`emacs -nw', `emacsclient -t'), in one that draws
;; Sixel pictures (foot, WezTerm, Konsole, xterm -ti vt340…), the page is a
;; Sixel picture drawn over its window, which Emacs leaves blank; clicks and
;; drags work with `xterm-mouse-mode'.  A text terminal without Sixel gets
;; an error.  Where Emacs has no theme there, the page takes the terminal's
;; colours, and follows them when the terminal is recoloured from outside
;; (a desktop theme switch), once it has the focus again.
;;
;; It needs a TeXpresso with the commands `render-to', `click-at' and
;; `select' (and its rerun fixes): until they are upstream, TeXpresso built
;; with the patches in the folder texpresso/ of this package's repository.

;;; Code:

(require 'texpresso)
(require 'subr-x)

(defconst texpresso-view-buffer-name "*TeXpresso window*"
  "Name of the buffer showing the page.
texpresso.el knows it: a click answered while it is current opens the source
in another window instead of replacing it.")

(defvar texpresso-view--size nil
  "What was last asked of TeXpresso: (FILE WIDTH HEIGHT), in pixels.")

(defvar texpresso-view--source nil
  "The buffer whose file TeXpresso shows.")

(defvar texpresso-view--root nil
  "The file TeXpresso typesets: the source's own, or its `TeX-master'.")

(defvar texpresso-view--image nil
  "The image on display, to free it from the image cache when replaced.")

(defvar texpresso-view-cell-size nil
  "The size of a terminal's character cell, (WIDTH . HEIGHT) in pixels.
Nil asks the terminal; set it if the terminal does not answer.")

(defvar texpresso-view--sixel nil
  "The page as a Sixel picture: (DATA WIDTH HEIGHT).")

(defvar texpresso-view--sixel-drawn nil
  "Where the picture was last drawn: (FRAME COLUMN ROW WIDTH HEIGHT), or nil.")

(defvar texpresso-view--sixel-timer nil
  "The pending drawing of the picture.")

(defvar texpresso-view--sixel-again nil
  "Non-nil when the picture must be drawn even where it already is.")

(defvar texpresso-view--sixel-dirty nil
  "Non-nil when a command ran since the picture was drawn.")

(defvar texpresso-view--sixel-idle-timer nil
  "Draws the picture again once Emacs is idle after commands.")

(defun texpresso-view--window ()
  "The window showing the page, if any."
  (get-buffer-window texpresso-view-buffer-name t))

(defun texpresso-view--tty-p (&optional win)
  "Non-nil if WIN, by default the page's window, is in a text terminal.
The page is then a Sixel picture drawn over the window."
  (let ((win (or win (texpresso-view--window))))
    (and win (not (display-images-p (window-frame win))))))

(defun texpresso-view--file ()
  "The file TeXpresso writes the page to: a PNG, or Sixel in a terminal."
  (expand-file-name (format "texpresso-view-%d.%s" (emacs-pid)
                            (if (texpresso-view--tty-p) "six" "png"))
                    temporary-file-directory))

(defun texpresso-view--delete-files ()
  "Delete the page's files: the PNG, the Sixel and their unfinished copies.
A view moved between a graphical and a terminal frame wrote both."
  (let ((base (expand-file-name (format "texpresso-view-%d" (emacs-pid))
                                temporary-file-directory)))
    (dolist (file (delete-dups
                   (delq nil (list (car texpresso-view--size)
                                   (concat base ".png") (concat base ".six")))))
      (dolist (f (list file (concat file ".tmp")))
        (when (file-exists-p f)
          (ignore-errors (delete-file f)))))))

(add-hook 'kill-emacs-hook #'texpresso-view--delete-files)

(defun texpresso-view--send-size (&rest _)
  "Ask TeXpresso for the page at the size of its window; stop when it has none.
In a terminal, the size is the window's cells times their size in pixels,
the height cut to whole Sixel bands of 6 pixels."
  (when (process-live-p texpresso--process)
    (let* ((win (texpresso-view--window))
           (cell (and win (texpresso-view--tty-p win)
                      (texpresso-view--cell-size (window-frame win))))
           (size (cond (cell
                        (list (texpresso-view--file)
                              (* (window-body-width win) (car cell))
                              (* 6 (/ (* (window-body-height win) (cdr cell)) 6))))
                       (win
                        (list (texpresso-view--file)
                              (window-body-width win t) (window-body-height win t))))))
      (unless (equal size texpresso-view--size)
        (setq texpresso-view--size size)
        (if size
            (apply #'texpresso--send 'render-to size)
          (texpresso--send 'render-to "" 0 0))))))

(defvar-local texpresso-view--page-text nil
  "The page's part of the mode line: \" PAGE/COUNT\".")

(defvar-local texpresso-view--errors-text nil
  "The errors' part of the mode line: \" · N errors\", or nil.")

(defun texpresso-view--show (file page count width height &optional source line)
  "Show the PNG FILE, page PAGE (from 0) of COUNT, WIDTH x HEIGHT pixels.
SOURCE and LINE: where the page starts in the source, if TeXpresso knows."
  (texpresso-view--page-shown page source line)
  (let ((buf (get-buffer texpresso-view-buffer-name)))
    (cond
     ((not (and buf (file-readable-p file))))
     ((string-suffix-p ".six" file)
      (setq texpresso-view--sixel
            (list (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally file)
                    (buffer-string))
                  width height))
      (with-current-buffer buf
        (when (texpresso-view--window)
          (texpresso-view--sixel-rows (window-body-height (texpresso-view--window))))
        (setq texpresso-view--page-text (format " %d/%d" (1+ page) count))
        (texpresso-view--mode-line))
      (texpresso-view--sixel-schedule t))
     (t
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
          (setq texpresso-view--page-text (format " %d/%d" (1+ page) count))
          (texpresso-view--mode-line)))))))

(defun texpresso-view--mode-line ()
  "Show the page and the error count in the page window's mode line."
  (setq mode-line-process
        (delq nil (list texpresso-view--page-text texpresso-view--errors-text)))
  (force-mode-line-update))

;;; In a text terminal (foot, xterm, WezTerm…), TeXpresso writes the page as
;;; a Sixel picture, which is drawn over the page's window, left blank:
;;; Emacs writes to a terminal only the cells that change, so the picture
;;; stays until the window moves or the frame is drawn again, after which it
;;; is drawn again.

(defun texpresso-view--sixel-rows (rows)
  "Fill the page's buffer with ROWS lines, blank but each unlike the others.
Each is a space in a colour of its own, which does not show.  When the
source window scrolls, Emacs moves the terminal's lines that it finds
again a few rows away, whole, and the picture with them: lines that
differ are never found again."
  (unless (= (count-lines (point-min) (point-max)) rows)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (dotimes (i rows)
        (insert (propertize " " 'face (list :foreground (format "#%06x" (1+ i))))
                (if (< (1+ i) rows) "\n" "")))
      (goto-char (point-min)))))

(defvar xterm-query-timeout)
(declare-function xterm--query "term/xterm" (query handlers &optional no-async))
(declare-function xterm--read-string "term/xterm" (term1 &optional term2))

(defun texpresso-view--tty-query (query reply end &optional end2)
  "Send QUERY to the selected frame's terminal; the answer after REPLY, to END.
END2: the answer ends with END followed by END2.  Nil if the terminal does
not answer within half a second."
  (require 'term/xterm)
  (let ((xterm-query-timeout 0.5))
    (catch 'answer
      (xterm--query query
                    `((,reply . ,(lambda () (throw 'answer (xterm--read-string end end2)))))
                    t)
      nil)))

(defun texpresso-view--rgb (answer)
  "A terminal's colour ANSWER, \"rgb:RRRR/GGGG/BBBB\", as RGB; nil if not one."
  (when (and answer
             (string-match "\\`rgb:\\([0-9a-f]+\\)/\\([0-9a-f]+\\)/\\([0-9a-f]+\\)" answer))
    (mapcar (lambda (i)
              (let ((h (match-string i answer)))
                (/ (string-to-number h 16) (float (1- (expt 16 (length h)))))))
            '(1 2 3))))

(defun texpresso-view--tty-color (number)
  "The terminal's colour NUMBER (10 the text, 11 the background), as RGB."
  (texpresso-view--rgb (texpresso-view--tty-query (format "\e]%d;?\e\\" number)
                                                  (format "\e]%d;" number) ?\e ?\\)))

(defun texpresso-view--sixel-terminal-p ()
  "Non-nil if the selected frame's terminal draws Sixel pictures.
Its primary device attributes include 4; the answer is kept with the
terminal.  The size of a character cell and the colours are asked again
each time, kept with the terminal too: a zoom changes the cells."
  (let ((term (frame-terminal)))
    (unless (terminal-parameter term 'texpresso-view-sixel)
      (let ((attributes (texpresso-view--tty-query "\e[c" "\e[?" ?c)))
        (set-terminal-parameter
         term 'texpresso-view-sixel
         (if (and attributes (member "4" (split-string attributes ";"))) 'yes 'no))))
    (when (eq (terminal-parameter term 'texpresso-view-sixel) 'yes)
      (let ((cell (texpresso-view--tty-query "\e[16t" "\e[6;" ?t)))
        (when (and cell (string-match "\\`\\([0-9]+\\);\\([0-9]+\\)\\'" cell))
          (set-terminal-parameter
           term 'texpresso-view-cell-size
           (cons (string-to-number (match-string 2 cell))
                 (string-to-number (match-string 1 cell))))))
      (set-terminal-parameter term 'texpresso-view-colors
                              (list (texpresso-view--tty-color 11)
                                    (texpresso-view--tty-color 10)))
      t)))

(defun texpresso-view--color (attribute)
  "The default face's colour ATTRIBUTE (`:background', `:foreground'), as RGB.
As the theme names it, in whichever frame: texpresso.el reads it through
the selected frame, and a terminal's frame gives its nearest colour
instead (#fdf6e3 becomes white).  Nil when Emacs has none."
  (let* ((frame (window-frame (or (texpresso-view--window) (selected-window))))
         (name (face-attribute 'default attribute frame))
         (values (and (stringp name)
                      (or (tty-color-standard-values (downcase name))
                          (and (display-graphic-p frame) (color-values name frame))))))
    (and values (mapcar (lambda (v) (/ v 65535.0)) values))))

(defun texpresso-view--colors ()
  "The page's colours, (BACKGROUND FOREGROUND) as RGB, each nil if unknown.
The theme's, as `texpresso-view--color' reads them; where Emacs has none
\(a terminal with no theme), the page's terminal's, as last asked."
  (let ((tty (terminal-parameter
              (frame-terminal (window-frame (or (texpresso-view--window) (selected-window))))
              'texpresso-view-colors)))
    (list (or (texpresso-view--color :background) (car tty))
          (or (texpresso-view--color :foreground) (cadr tty)))))

(defvar texpresso-view--theme-sending nil
  "Non-nil while `texpresso-view--theme' sends the colours itself.")

(defun texpresso-view--send-theme ()
  "Send TeXpresso the page's colours, when both are known.
TeXpresso stops on a `theme' message without colours."
  (pcase-let ((`(,bg ,fg) (texpresso-view--colors)))
    (when (and bg fg)
      (let ((texpresso-view--theme-sending t))
        (texpresso--send 'theme bg fg)))))

(defun texpresso-view--theme (command &rest _args)
  "Give TeXpresso the colours of the theme, exact, in every frame: COMMAND.
texpresso.el sends `theme' when it starts TeXpresso and when a theme is
enabled; this sends `texpresso-view--colors' instead: the theme's own
colours, or, in a terminal whose frame has none (no theme), the
terminal's."
  (when (and (eq command 'theme) (not texpresso-view--theme-sending))
    (texpresso-view--send-theme)
    t))

(advice-add 'texpresso--send :before-until #'texpresso-view--theme)

;;; A terminal recoloured from outside Emacs tells it nothing: Omarchy, on a
;;; theme switch, recolours foot with OSC 10/11, and Emacs, showing the
;;; terminal's own colours where it has no theme, changes with it, but no
;;; theme is enabled.  So for a while after the page's terminal gets the
;;; focus back (the switch was made in a menu or another window, and the
;;; terminal is recoloured a moment later), its colours are asked again
;;; each half second, without waiting for the answer, and TeXpresso gets
;;; them when they changed.

(defconst texpresso-view-tty-watch 10
  "Seconds the terminal's colours are asked again after it gets the focus.")

(defvar texpresso-view--tty-watch-timer nil
  "Asks the page's terminal its colours each half second, for a while.")

(defvar texpresso-view--tty-watch-end 0
  "When `texpresso-view--tty-watch-timer' stops, as `float-time'.")

(defun texpresso-view--tty-own-colors-p (win)
  "Non-nil if WIN is in a text terminal and the page takes the terminal's colours.
That is, Emacs has none of its own in WIN's frame: no theme there."
  (and (texpresso-view--tty-p win)
       (not (and (texpresso-view--color :background)
                 (texpresso-view--color :foreground)))))

(defun texpresso-view--tty-focus ()
  "When the page's terminal gets the focus back, watch its colours a while."
  (let ((win (texpresso-view--window)))
    (when (and win (process-live-p texpresso--process)
               (eq (frame-focus-state (window-frame win)) t)
               (texpresso-view--tty-own-colors-p win))
      (setq texpresso-view--tty-watch-end (+ (float-time) texpresso-view-tty-watch))
      (unless (timerp texpresso-view--tty-watch-timer)
        (setq texpresso-view--tty-watch-timer
              (run-with-timer 0.2 0.5 #'texpresso-view--tty-watch))))))

(add-function :after after-focus-change-function #'texpresso-view--tty-focus)

(defun texpresso-view--tty-watch-stop ()
  "Stop asking the terminal its colours."
  (when (timerp texpresso-view--tty-watch-timer)
    (cancel-timer texpresso-view--tty-watch-timer))
  (setq texpresso-view--tty-watch-timer nil))

(defun texpresso-view--tty-watch ()
  "Ask the page's terminal its colours, until the watch ends.
Not while a command runs: a command reading characters itself
\(`read-char', `read-event') would get the answer as typed text."
  (let ((win (texpresso-view--window)))
    (cond
     ((or (> (float-time) texpresso-view--tty-watch-end)
          (not (and win (process-live-p texpresso--process)
                    (texpresso-view--tty-own-colors-p win))))
      (texpresso-view--tty-watch-stop))
     ((not (or this-command (input-pending-p)))
      (texpresso-view--tty-ask (window-frame win))))))

(declare-function xterm--query "term/xterm" (query handlers &optional no-async))

(defun texpresso-view--tty-ask (frame)
  "Ask FRAME's terminal its colours, without waiting for the answers.
They come back as input, which `xterm--query''s handlers take out: the
background, then the text colour.  When they differ from the terminal's
colours known, these are replaced and TeXpresso gets them."
  (require 'term/xterm)
  (let ((term (frame-terminal frame))
        (xterm-query-timeout nil))      ; nil: `xterm--query' does not wait
    (with-selected-frame frame
      (xterm--query "\e]11;?\e\\"
                    `(("\e]11;"
                       . ,(lambda ()
                            (set-terminal-parameter
                             term 'texpresso-view-asked
                             (texpresso-view--rgb (xterm--read-string ?\e ?\\)))))))
      (xterm--query "\e]10;?\e\\"
                    `(("\e]10;"
                       . ,(lambda ()
                            (texpresso-view--tty-answered
                             term (texpresso-view--rgb (xterm--read-string ?\e ?\\))))))))))

(defun texpresso-view--tty-answered (term fg)
  "TERM answered its colours: the background asked before, and FG.
TeXpresso gets them if they changed."
  (let ((colors (list (terminal-parameter term 'texpresso-view-asked) fg)))
    (set-terminal-parameter term 'texpresso-view-asked nil)
    (when (and (car colors) fg
               (not (equal colors (terminal-parameter term 'texpresso-view-colors))))
      (set-terminal-parameter term 'texpresso-view-colors colors)
      (when (process-live-p texpresso--process)
        (texpresso-view--send-theme)))))

(defun texpresso-view--cell-size (frame)
  "The size of a character cell of FRAME's terminal, (WIDTH . HEIGHT) in pixels."
  (or texpresso-view-cell-size
      (terminal-parameter (frame-terminal frame) 'texpresso-view-cell-size)
      '(10 . 20)))

(defun texpresso-view--sixel-place ()
  "Where the picture goes: (FRAME COLUMN ROW WIDTH HEIGHT), or nil.
COLUMN and ROW, from 0, are the terminal cell of its top left corner:
centred in the page's window, which TeXpresso filled one way."
  (let ((win (texpresso-view--window)))
    (when (and win texpresso-view--sixel (texpresso-view--tty-p win))
      (pcase-let* ((frame (window-frame win))
                   (`(,cw . ,ch) (texpresso-view--cell-size frame))
                   (`(,left ,top ,_ ,_) (window-body-edges win))
                   (`(,_ ,width ,height) texpresso-view--sixel)
                   (cols (- (window-body-width win) (/ (+ width cw -1) cw)))
                   (rows (- (window-body-height win) (/ (+ height ch -1) ch))))
        ;; a picture made for a larger window waits for the page at this
        ;; size: past the window it would cover others, past the bottom of
        ;; the terminal scroll it
        (when (and (>= cols 0) (>= rows 0))
          (list frame (+ left (/ cols 2)) (+ top (/ rows 2)) width height))))))

(defun texpresso-view--sixel-schedule (&optional again)
  "Draw the picture once Emacs has drawn the frame, if it is not in place.
AGAIN: draw it even if it is, as a new page or a cleared terminal needs."
  (when again
    (setq texpresso-view--sixel-again t))
  (unless (timerp texpresso-view--sixel-timer)
    (setq texpresso-view--sixel-timer
          (run-with-timer 0 nil #'texpresso-view--sixel-draw))))

(defun texpresso-view--sixel-draw ()
  "Draw the picture over the page's window, in its terminal.
When it moved or left, the frame is drawn again first: that clears the
old picture, which Emacs does not know of."
  (setq texpresso-view--sixel-timer nil)
  (let ((place (texpresso-view--sixel-place))
        (drawn texpresso-view--sixel-drawn)
        (again texpresso-view--sixel-again))
    (setq texpresso-view--sixel-again nil)
    (unless (and (equal place drawn) (not again))
      (when (and drawn (not (equal place drawn)) (frame-live-p (car drawn)))
        (redraw-frame (car drawn)))
      (setq texpresso-view--sixel-drawn nil)
      (when place
        (pcase-let ((`(,frame ,col ,row ,_ ,_) place))
          (when (eq frame (tty-top-frame (frame-terminal frame)))
            (redisplay)
            (send-string-to-terminal
             (concat "\e7" (format "\e[%d;%dH" (1+ row) (1+ col))
                     (car texpresso-view--sixel) "\e8")
             (frame-terminal frame))
            (setq texpresso-view--sixel-drawn place
                  texpresso-view--sixel-dirty nil)))))))

(defun texpresso-view--sixel-after-command ()
  "After a command, have the picture drawn again if the frame may have been.
\\[recenter-top-bottom] and \\[redraw-display] clear the terminal at once;
a menu or a pop-up drawn over the window shows when Emacs is idle."
  (when texpresso-view--sixel-drawn
    (if (memq this-command '(recenter-top-bottom recenter redraw-display))
        (texpresso-view--sixel-schedule t)
      (setq texpresso-view--sixel-dirty t))))

(defun texpresso-view--sixel-idle ()
  "Draw the picture again after commands, once Emacs is idle."
  (when texpresso-view--sixel-dirty
    (setq texpresso-view--sixel-dirty nil)
    (texpresso-view--sixel-schedule t)))

(defun texpresso-view--sixel-moved (&rest _)
  "Draw the picture where the page's window now is, if it moved."
  (when (or texpresso-view--sixel-drawn texpresso-view--sixel)
    (texpresso-view--sixel-schedule)))

(defun texpresso-view--sixel-resumed (&rest _)
  "Draw the picture again: the terminal came back cleared."
  (when texpresso-view--sixel
    (texpresso-view--sixel-schedule t)))

(add-hook 'post-command-hook #'texpresso-view--sixel-after-command)
(add-hook 'window-configuration-change-hook #'texpresso-view--sixel-moved)
(add-hook 'resume-tty-functions #'texpresso-view--sixel-resumed)

;;; TeX's errors.  TeXpresso streams TeX's log to Emacs, appending to it and
;;; truncating it as it typesets and goes back, so the log on hand is that of
;;; the text as it stands: its "! " lines are the text's errors.  When the
;;; text stops TeX (an argument open to the end of the file, a missing
;;; \end{document}, TeX's capacity exceeded), a red line over the page says
;;; so; the other errors are counted in the page window's mode line.  Where
;;; an error is comes from TeXpresso's stderr, where TeX's engine prints
;;; "Error: FILE:LINE: MESSAGE".

(defvar texpresso-view--log nil
  "A copy of TeX's log as TeXpresso streams it: a unibyte buffer.")

(defvar texpresso-view--log-known nil
  "Non-nil while `texpresso-view--log' holds the log from its start.
A TeXpresso that was running before the view opened streams past the
copy's end; the copy is known again once the log is cut back within it.")

(defvar texpresso-view--locations nil
  "Where TeX's latest errors are, newest first: a list of (MESSAGE LINE FILE).")

(defvar texpresso-view--stderr-rest ""
  "The start of a line of TeXpresso's stderr not yet ended.")

(defvar texpresso-view--errors-timer nil
  "The pending look at the copy of TeX's log.")

(defvar texpresso-view--stop-since nil
  "When the copy of TeX's log first said that TeX stopped, or nil.")

(defconst texpresso-view-stop-delay 1.0
  "Seconds a stop of TeX lasts before the view says so.
An argument whose closing brace is not typed yet stops TeX: the red line
waits for a pause.")

(defconst texpresso-view--stop-regexp
  (concat "^\\(?:! \\(?:Emergency stop\\|TeX capacity exceeded\\|This can't happen"
          "\\|I can't go on meeting you like this\\)\\|(That makes 100 errors\\)")
  "A line of TeX's log saying that TeX stopped.")

(defun texpresso-view--log-reset ()
  "Start an empty copy of TeX's log, with no errors known."
  (unless (buffer-live-p texpresso-view--log)
    (setq texpresso-view--log (generate-new-buffer " *texpresso-view-log*"))
    (with-current-buffer texpresso-view--log
      (set-buffer-multibyte nil)
      (setq buffer-undo-list t)))
  (with-current-buffer texpresso-view--log
    (erase-buffer))
  (when (timerp texpresso-view--errors-timer)
    (cancel-timer texpresso-view--errors-timer))
  (setq texpresso-view--log-known nil
        texpresso-view--locations nil
        texpresso-view--stderr-rest ""
        texpresso-view--errors-timer nil
        texpresso-view--stop-since nil))

(defun texpresso-view--log-update (offset &optional text)
  "Cut the copy of TeX's log at byte OFFSET, then add TEXT, if any."
  (when (buffer-live-p texpresso-view--log)
    (with-current-buffer texpresso-view--log
      (if (> offset (buffer-size))
          (setq texpresso-view--log-known nil)
        (delete-region (1+ offset) (point-max))
        (when text
          (goto-char (point-max))
          (insert (encode-coding-string text 'utf-8)))
        (setq texpresso-view--log-known t)))
    (texpresso-view--errors-schedule 0.3)))

(defun texpresso-view--stderr (_process text)
  "Note where TeX's errors are, from the lines of TeXpresso's stderr in TEXT."
  (let ((lines (split-string (concat texpresso-view--stderr-rest text) "\n")))
    (setq texpresso-view--stderr-rest (car (last lines)))
    (dolist (line (butlast lines))
      ;; "Error: !Emergency stop" and the like say no place
      (when (string-match "\\`Error: \\([^!:\n][^:\n]*\\):\\([0-9]+\\): \\(.*\\)" line)
        (push (list (match-string 3 line) (string-to-number (match-string 2 line))
                    (match-string 1 line))
              texpresso-view--locations)))
    (when (nthcdr 50 texpresso-view--locations)
      (setcdr (nthcdr 49 texpresso-view--locations) nil))))

(advice-add 'texpresso--stderr-filter :before #'texpresso-view--stderr)

(defun texpresso-view--log-line ()
  "The line of the copy of TeX's log at point, as text."
  (decode-coding-string
   (buffer-substring-no-properties (line-beginning-position) (line-end-position))
   'utf-8))

(defun texpresso-view--log-error ()
  "The error whose \"! \" line is at point: (MESSAGE LINE CONTEXT).
LINE is the source line TeX gives (\"l.14\"), CONTEXT the text of a runaway
argument; either may be nil."
  (let ((message (substring (texpresso-view--log-line) 2))
        line context)
    (save-excursion
      (when (and (zerop (forward-line -2))
                 (equal (texpresso-view--log-line) "Runaway argument?")
                 (zerop (forward-line 1)))
        (setq context (texpresso-view--log-line))))
    (save-excursion
      (let ((limit (save-excursion (forward-line 15) (point))))
        (forward-line 1)
        (when (and (re-search-forward "^\\(?:! \\|l\\.\\([0-9]+\\) \\)" limit t)
                   (match-beginning 1))
          (setq line (string-to-number (match-string 1))))))
    (list message line context)))

(defun texpresso-view--log-errors ()
  "What the copy of TeX's log says: (STOP CAUSE PAGES ERRORS).
ERRORS lists the errors (MESSAGE LINE CONTEXT) before any stop, in order.
STOP is what TeX said when it stopped, or nil; CAUSE the error that made it
stop, when TeX stopped right after one (a runaway argument); PAGES how many
pages TeX wrote, when it said."
  (with-current-buffer texpresso-view--log
    (save-excursion
      (goto-char (point-min))
      (let (errors last stop cause pages)
        (while (and (not stop)
                    (re-search-forward "^\\(?:! \\|(That makes 100 errors\\)" nil t))
          (goto-char (match-beginning 0))
          (if (not (looking-at texpresso-view--stop-regexp))
              (progn (push (texpresso-view--log-error) errors)
                     (setq last (point)))
            (setq stop (string-remove-prefix "! " (texpresso-view--log-line)))
            (when (looking-at "! TeX capacity exceeded")
              ;; an error of its own, with its line
              (setq cause (texpresso-view--log-error)))
            (when (equal stop "Emergency stop")
              ;; an error just before the emergency stop is its cause
              (when (and last (< (count-lines last (point)) 12))
                (setq cause (car errors)))
              ;; and the line "*** (…)" after it says why TeX gave up
              (save-excursion
                (forward-line 1)
                (when (looking-at "\\(?:[< ].*\n\\|\n\\)*\\*\\*\\* (\\(.*\\))")
                  (setq stop (decode-coding-string (match-string 1) 'utf-8))))))
          (forward-line 1))
        (when (re-search-forward "^Output written on [^ ]+ (\\([0-9]+\\) page" nil t)
          (setq pages (string-to-number (match-string 1))))
        (list stop cause pages (nreverse errors))))))

(defun texpresso-view--error-place (error)
  "Where ERROR, (MESSAGE LINE CONTEXT), is: \"FILE:LINE\", \"line LINE\", or nil."
  (pcase-let ((`(,message ,line ,_) error))
    (let ((found (seq-find (lambda (l)
                             (and (equal (nth 1 l) line)
                                  (equal (car l) (string-remove-suffix "." message))))
                           texpresso-view--locations)))
      (cond (found (format "%s:%d" (nth 2 found) line))
            (line (format "line %d" line))))))

(defun texpresso-view--error-text (error)
  "ERROR, (MESSAGE LINE CONTEXT), in a few words."
  (pcase-let ((`(,message ,_ ,context) error))
    (let ((place (texpresso-view--error-place error)))
      (concat (string-remove-suffix "." (string-remove-prefix "! " message))
              (and place (concat " (" place ")"))
              (and context (concat ", near "
                                   (truncate-string-to-width (string-trim context)
                                                             40 nil nil "…")))))))

(defun texpresso-view--errors-schedule (delay)
  "Look at the copy of TeX's log in DELAY seconds, unless a look is pending."
  (unless (timerp texpresso-view--errors-timer)
    (setq texpresso-view--errors-timer
          (run-with-timer delay nil #'texpresso-view--errors-show))))

(defun texpresso-view--errors-show ()
  "Say in the page window what the copy of TeX's log says about errors."
  (setq texpresso-view--errors-timer nil)
  (let ((buf (get-buffer texpresso-view-buffer-name)))
    (when (and buf texpresso-view--log-known (buffer-live-p texpresso-view--log))
      (pcase-let ((`(,stop ,cause ,pages ,errors) (texpresso-view--log-errors)))
        (with-current-buffer buf
          (setq texpresso-view--errors-text
                (and errors
                     (propertize (format " · %d error%s" (length errors)
                                         (if (cdr errors) "s" ""))
                                 'face 'warning
                                 'help-echo (texpresso-view--error-text (car errors)))))
          (texpresso-view--mode-line)
          (cond
           ((not stop)
            (setq texpresso-view--stop-since nil)
            (when header-line-format
              (setq header-line-format nil)))
           ((not texpresso-view--stop-since)
            (setq texpresso-view--stop-since (float-time))
            (texpresso-view--errors-schedule texpresso-view-stop-delay))
           ((< (- (float-time) texpresso-view--stop-since) texpresso-view-stop-delay)
            (texpresso-view--errors-schedule
             (- texpresso-view-stop-delay (- (float-time) texpresso-view--stop-since))))
           (t
            (let ((text (concat "TeX stopped"
                                (and pages (format " after page %d" pages))
                                ": "
                                (if cause (texpresso-view--error-text cause)
                                  (string-remove-suffix "." stop)))))
              (setq header-line-format
                    (propertize (replace-regexp-in-string "%" "%%" text t t)
                                'face 'error 'help-echo text))))))))))

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
     nil)
    ((or 'append 'truncate)
     ;; texpresso.el keeps its *texpresso-log* too: the message goes on
     (when (eq (nth 1 expr) 'log)
       (texpresso-view--log-update (nth 2 expr) (nth 3 expr)))
     nil)))

(advice-add 'texpresso--stdout-dispatch :before-until #'texpresso-view--dispatch)

(defun texpresso-view--sixel-xy (posn)
  "The point of the Sixel picture at POSN, the middle of its cell, in pixels."
  (pcase-let* ((place texpresso-view--sixel-drawn)
               (win (posn-window posn))
               (`(,col . ,row) (posn-col-row posn))
               (`(,left ,top ,_ ,_) (window-body-edges win))
               (`(,cw . ,ch) (texpresso-view--cell-size (window-frame win))))
    (when (and place (eq (window-frame win) (car place)))
      (cons (+ (* (- (+ left col) (nth 1 place)) cw) (/ cw 2))
            (+ (* (- (+ top row) (nth 2 place)) ch) (/ ch 2))))))

(defun texpresso-view--object-xy (event)
  "The points where EVENT starts and ends, in pixels of the page image.
The end is measured from the start, so a drag that leaves the image still
counts."
  (let* ((start (event-start event))
         (end (event-end event))
         (a (posn-object-x-y start))
         (sx (posn-x-y start))
         (ex (posn-x-y end)))
    (cond
     ((texpresso-view--tty-p (posn-window start))
      (let ((a (texpresso-view--sixel-xy start))
            (b (texpresso-view--sixel-xy end)))
        (and a b (list (car a) (cdr a) (car b) (cdr b)))))
     (a
      (list (car a) (cdr a)
            (+ (car a) (- (car ex) (car sx)))
            (+ (cdr a) (- (cdr ex) (cdr sx))))))))

(defun texpresso-view-click (event)
  "Jump to the source of the point of the page clicked in EVENT."
  (interactive "e")
  (let ((pts (texpresso-view--object-xy event)))
    (when (and pts (process-live-p texpresso--process))
      (setq texpresso-view--click-pending t)
      (texpresso--send 'click-at (nth 0 pts) (nth 1 pts))
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
(defun texpresso-view (&optional whole)
  "Show TeXpresso's live view of this LaTeX file in the window to the right.
With a prefix argument WHOLE, TeXpresso typesets AUCTeX's `TeX-master'
instead, the whole document this file is part of, and the page follows
this file as it does its own.  Run it again in the same buffer, with the
same argument, to close the view and stop TeXpresso; in another LaTeX
buffer, or with the other argument, it shows that instead."
  (interactive "P")
  (let ((root (texpresso-view--root whole)))
    (if (and (eq (current-buffer) texpresso-view--source)
             (equal root texpresso-view--root)
             (process-live-p texpresso--process)
             (texpresso-view--window))
        (texpresso-view--stop)
      (texpresso-view--start root))))

(defvar TeX-master)
(declare-function TeX-master-file "tex" (&optional extension nondirectory ask))

(defun texpresso-view--root (whole)
  "The file TeXpresso is to typeset: this buffer's, or with WHOLE its master."
  (unless (buffer-file-name)
    (user-error "TeXpresso view: this buffer has no file"))
  (if (or (not whole) (and (boundp 'TeX-master) (eq TeX-master t)))
      ;; TeX-master t: the file is its own master
      (buffer-file-name)
    (unless (and (fboundp 'TeX-master-file) (boundp 'TeX-master) (stringp TeX-master))
      (user-error "TeXpresso view: this buffer has no TeX-master (AUCTeX's) to typeset"))
    (let ((master (expand-file-name (TeX-master-file t))))
      (unless (file-exists-p master)
        (user-error "TeXpresso view: the TeX-master %s does not exist" master))
      master)))

(defvar pdf-view-scroll-sync-mode)
(declare-function pdf-view-scroll-sync-mode "pdf-view-scroll-sync")

(defun texpresso-view--stop ()
  "Close the page's window and stop TeXpresso."
  (let ((win (texpresso-view--window)))
    (when (and win (not (one-window-p t)))
      (delete-window win)))
  (when (process-live-p texpresso--process)
    (kill-process texpresso--process)
    ;; ended before its files are deleted, so no page is written after
    (let ((end (+ (float-time) 0.5)))
      (while (and (process-live-p texpresso--process) (< (float-time) end))
        (accept-process-output texpresso--process 0.02))))
  (texpresso-view--delete-files)
  (when (buffer-live-p texpresso-view--source)
    (with-current-buffer texpresso-view--source
      (texpresso-mode -1)))
  (when (timerp texpresso-view--scroll-timer)
    (cancel-timer texpresso-view--scroll-timer))
  (when (timerp texpresso-view--errors-timer)
    (cancel-timer texpresso-view--errors-timer))
  (when (buffer-live-p texpresso-view--log)
    (kill-buffer texpresso-view--log))
  (setq texpresso-view--log nil
        texpresso-view--log-known nil
        texpresso-view--locations nil
        texpresso-view--errors-timer nil
        texpresso-view--stop-since nil)
  (setq texpresso-view--source nil
        texpresso-view--root nil
        texpresso-view--source-window nil
        texpresso-view--scroll-timer nil
        texpresso-view--page nil
        texpresso-view--turn nil)
  (when (get-buffer texpresso-view-buffer-name)
    (kill-buffer texpresso-view-buffer-name))
  (when (timerp texpresso-view--sixel-idle-timer)
    (cancel-timer texpresso-view--sixel-idle-timer))
  (when (timerp texpresso-view--sixel-timer)
    (cancel-timer texpresso-view--sixel-timer))
  (texpresso-view--tty-watch-stop)
  (when (frame-live-p (car texpresso-view--sixel-drawn))
    (redraw-frame (car texpresso-view--sixel-drawn)))
  (setq texpresso-view--sixel nil
        texpresso-view--sixel-drawn nil
        texpresso-view--sixel-timer nil
        texpresso-view--sixel-idle-timer nil
        texpresso-view--sixel-dirty nil
        texpresso-view--sixel-again nil)
  (setq texpresso-view--size nil)
  (message "TeXpresso view closed"))

(defun texpresso-view--start (root)
  "Start TeXpresso on ROOT (this file or its master), the page to the right.
TeXpresso opens no window of its own: it draws with SDL's offscreen driver
and writes the page on display as a PNG that the window shows.  Its reruns
are turned on: after a pause, if the .aux file changed, it typesets again
with the previous pass's references, as a second pdflatex pass would
\(beamer's total slide count, the table of contents, \\ref).  In this
buffer `pdf-view-scroll-sync-mode' is turned off, so that saving does not
also compile with latexmk."
  (unless (or (display-images-p) (texpresso-view--sixel-terminal-p))
    (user-error "TeXpresso view needs a graphical frame, or a terminal that shows Sixel pictures"))
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
          texpresso-view--root root
          texpresso-view--page nil
          texpresso-view--turn nil)
    (when (bound-and-true-p pdf-view-scroll-sync-mode)
      (pdf-view-scroll-sync-mode -1))
    (texpresso-view--log-reset)
    (unless (timerp texpresso-view--sixel-idle-timer)
      (setq texpresso-view--sixel-idle-timer
            (run-with-idle-timer 0.5 t #'texpresso-view--sixel-idle)))
    (texpresso root)
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
