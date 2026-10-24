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

One command: `M-x texpresso-view` in a LaTeX buffer opens the view; again in the same buffer, it
closes it and stops TeXpresso.

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

XeTeX writes glyph numbers, not characters, so to copy text TeXpresso reads each font's character
map backwards (one of the patches below).

## Install

1. **TeXpresso with the patches in [`texpresso/`](texpresso/)** (until they are upstream): the
   three editor commands, the page's source line, text from XeTeX's glyphs, two fixes to its
   reruns (an edit made
   while a rerun pass starts no longer stops TeXpresso for good or crashes it; submitted as
   let-def/texpresso#163), and one for edits to an `\input` file (once the buffer's length
   differed from the file's, TeXpresso read the file from disk and the edits stopped showing).

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

Needs graphical Emacs (it shows images). Tested with Emacs 31.1 (pgtk, Wayland) and TeX Live 2026.

## Notes

- TeXpresso typesets the file of the buffer you run it in, not AUCTeX's `TeX-master`: a deck that
  a `.dir-locals.el` attaches to a larger file still shows on its own.
- Its reruns are on: after a pause, if the `.aux` file changed, it typesets once more with the
  previous pass's references, as a second pdflatex run would (Beamer's total slide count, the
  table of contents, `\ref`).
- With `pixel-scroll-precision-mode` on, the mouse wheel over the page belongs to that mode and
  does not turn pages (its keymap comes before the page window's).
- If [pdf-view-scroll-sync](https://github.com/stefanoconiglio/emacs-pdf-view-scroll-sync) is on
  in the buffer, it is turned off, so that saving does not also compile with latexmk.
- TeXpresso typesets with XeTeX: a document set in T1-encoded fonts (`fontenc`, `lmodern`) loses
  the typographic quotes typed as such unless its preamble loads `fontspec` under XeTeX.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). The patches in `texpresso/` are for TeXpresso, under
its own licence (MIT).
