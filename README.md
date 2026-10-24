# emacs-texpresso-view

[TeXpresso](https://github.com/let-def/texpresso) inside Emacs: the page of your LaTeX document,
re-typeset as you type, in the window to the right of the source, the way pdf-tools shows a PDF.

- Type in the source → the page updates within a fraction of a second, with no save and no
  compile; it shows the page under the cursor (with `texpresso-follow-cursor`).
- Scroll the source → the page of the line at the top of its window follows, once you pause.
- Turn the page → the source window shows where that page starts at its top, with the cursor
  there: a Beamer frame's `\begin{frame}`, in the `\input` file it comes from if need be.
- Click on the page → jump to the source line under the click (or a message saying there is none,
  on blank space or a footer).
- Drag across the page → the text crossed is highlighted and copied (kill ring and clipboard).
- `n` / `p` (or PageDown / PageUp, SPC / DEL, the mouse wheel over the page) → next and previous
  page; `q` closes the window.
- The page fits its window as you resize it, in the colours of your Emacs theme.
- Errors → when the text stops TeX (a brace left open to the end of the file, a missing
  `\end{document}`), a red line over the page says so, after a second's pause, and why: "TeX
  stopped after page 3: File ended while scanning use of \@iinput, near {sync-child…"; it goes
  once the text is mended. Other errors are counted in the page window's mode line (" 1/5 · 1
  error"; the mouse over it shows the first).
- In a terminal → `emacs -nw` or `emacsclient -t` in a terminal that draws Sixel pictures (foot,
  WezTerm, Konsole, xterm started as `xterm -ti vt340`…) shows the page too, as a Sixel picture
  over its window, with all of the above; clicks and drags need `xterm-mouse-mode`.

One command: `M-x texpresso-view` in a LaTeX buffer opens the view; again in the same buffer, it
closes it and stops TeXpresso. With a prefix, `C-u M-x texpresso-view` typesets AUCTeX's
`TeX-master` instead, the whole document the file is part of (a course that `\input`s its decks),
and the page follows the file you edit as it follows a document of its own; turning pages may
take the source window into the other files. Run it the same way again to close it.

## How it works

TeXpresso is fast because it never makes a PDF. It runs a modified XeTeX that keeps snapshots of
itself as it typesets, so an edit re-typesets only from the page it touches, and it draws XeTeX's
page descriptions (XDV) directly with MuPDF. Normally it shows them in a window of its own.

Here TeXpresso runs with no window (SDL's offscreen driver). Through three commands added to its
editor protocol, it writes the page on display as a PNG the size of the Emacs window
(`render-to`), maps a click on that image back to the source through SyncTeX (`click-at`), and
returns the text between two points (`select`). Emacs shows the PNG as an image, as pdf-tools
does with the pages Poppler draws.

Each new image comes with the source line its page starts at: the first SyncTeX record on the page
from one of the document's own files, or, for a Beamer frame (typeset whole when its
`\end{frame}` is read), that `\end{frame}`, which Emacs takes back to the frame's
`\begin{frame}`. The other way, a scroll of the source sends TeXpresso a SyncTeX search for the
line at the top of the window (a blank or comment line stands for the next line with text; an
`\input` line for the start of the file it reads). For a frame with overlays, TeXpresso picks the
overlay nearest the page shown before: scrolling up into a frame shows its last overlay, scrolling
down its first.

In a text terminal, Emacs asks the terminal whether it draws Sixel pictures, the size of its
character cells in pixels and its colours. TeXpresso then writes the page as Sixel (`render-to`
with a path ending in `.six`) at the window's size in pixels, and Emacs sends it to the terminal
at the window's top left cell, the window itself left blank. Emacs writes to a terminal only the
cells that change, so the picture stays; it is drawn again when the page changes, when the window
moves or changes size, and after the frame is drawn anew (C-l, a menu, a pop-up over it).

XeTeX writes glyph numbers, not characters, so to copy text TeXpresso reads each font's character
map backwards (one of the patches below).

TeX's errors come from its log, which TeXpresso streams to Emacs and rolls back with the document,
so the log on hand is always that of the text as it stands; where an error is (file and line)
comes from the lines `Error: FILE:LINE: …` TeX's engine prints on TeXpresso's stderr.

## Install

1. **TeXpresso with the patches in [`texpresso/`](texpresso/)** (until they are upstream): the
   three editor commands, the page's source line, text from XeTeX's glyphs, two fixes to its
   reruns (an edit made
   while a rerun pass starts no longer stops TeXpresso for good or crashes it; submitted as
   let-def/texpresso#163), one for edits to an `\input` file (once the buffer's length
   differed from the file's, TeXpresso read the file from disk and the edits stopped showing),
   and one so that text that stops TeX while you type (a brace left open to the end of the file,
   a missing `\end{document}`) is no longer reported by the system as a crash of TeXpresso;
   one writes the page as a Sixel picture, for Emacs in a terminal; and one keeps TeXpresso's
   snapshots spread evenly over the document and dense just before the last edit, so that an
   edit anywhere in a 120-page deck shows in 0.06–0.6 s, 0.12 s on average (TeXpresso kept them
   dense only at the start and the end, and an edit in the middle took up to 2.6 s).

   ```
   git clone https://github.com/let-def/texpresso
   git -C texpresso am /path/to/emacs-texpresso-view/texpresso/*.patch
   make -C texpresso all
   ```

   This builds `texpresso/build/texpresso` and `texpresso/build/texpresso-xetex`; see TeXpresso's
   INSTALL.md for what it needs (MuPDF, SDL2, a TeX distribution with XeTeX).

2. **This package**, with TeXpresso's own `texpresso.el` (in its `emacs/` folder):

   ```elisp
   (add-to-list 'load-path "/path/to/texpresso/emacs")
   (add-to-list 'load-path "/path/to/emacs-texpresso-view")
   (require 'texpresso)
   (require 'texpresso-view)
   (setq texpresso-binary "/path/to/texpresso/build/texpresso"
         texpresso-follow-cursor t)   ; show the page under the cursor
   ```

Needs graphical Emacs (it shows images), or Emacs in a terminal that draws Sixel pictures. Tested
with Emacs 31.1 (pgtk, Wayland; and `emacs -nw` in foot 1.28.0) and TeX Live 2026.

## Notes

- `M-x texpresso-view` typesets the file of the buffer you run it in, not AUCTeX's `TeX-master`:
  a deck that a `.dir-locals.el` attaches to a larger file shows on its own, which is quickest for
  editing. `C-u` typesets the master, the whole document: slower to start (TeX typesets every
  page before the one shown: on a 644-page course, 28 s to page 422), heavier (about 850 MB),
  and the first edit at a new place takes 1–2.5 s (the snapshots TeXpresso keeps are spread over
  more pages), the next ones 0.1–0.25 s.
- Its reruns are on: after a pause, if the `.aux` file changed, it typesets once more with the
  previous pass's references, as a second pdflatex run would (Beamer's total slide count, the
  table of contents, `\ref`).
- With `pixel-scroll-precision-mode` on, the mouse wheel over the page belongs to that mode and
  does not turn pages (its keymap comes before the page window's).
- If [pdf-view-scroll-sync](https://github.com/stefanoconiglio/emacs-pdf-view-scroll-sync) is on
  in the buffer, it is turned off, so that saving does not also compile with latexmk.
- In a terminal, the page shows through a multiplexer (tmux, zellij…) only if it passes Sixel
  pictures on to the terminal; it was tried in foot itself. A terminal that does not answer the
  question about its cell size gets 10 × 20 pixels: set `texpresso-view-cell-size` to its own.
- TeXpresso typesets with XeTeX: a document set in T1-encoded fonts (`fontenc`, `lmodern`) loses
  the typographic quotes typed as such unless its preamble loads `fontspec` under XeTeX.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). The patches in `texpresso/` are for TeXpresso, under
its own licence (MIT).
