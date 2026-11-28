# Emacs UI guidelines

Rules for every Emacs view Homun ships (`container/emacs/`) and for new ones. A reviewer can run
the check under each rule; a view that fails one is a bug.

1. **Still a buffer.** Text you can search, copy and navigate with normal motion; point means
   something. Widgets sit on top of text and do not replace it (the Magit model).
   Example: the transcript is a `magit-section-mode` buffer; widgets are overlays on Markdown text.
   Check: `C-s` finds a word inside a widget's label, `M-w` copies it, and `M-x describe-mode` names a real mode.
2. **Keyboard first, mouse and touch as equals.** Every action has a key, the common ones a single
   key (g refresh, q quit, RET act at point, ? menu). Buttons call the same commands.
   Example: the board's stop is `x` and the Stop button runs `claude-board-stop`.
   Check: `C-h k` on each button's action text shows a key; mouse-click and key give the same result.
3. **Discoverable.** A `?` menu lists the keys and `describe-mode` is accurate. The views themselves show no key hints: header lines, mode lines, buttons and buffer text stay clear of key names. `homun-key-hints` (default nil) turns them on, and every hint goes through `homun-key-hint` (`claude.el`); tooltips (`help-echo`) may name keys.
   Example: `homun-menu-transcript`, `-board`, `-compose` (`container/emacs/homun-menu.el`).
   Check: press `?` in the view; every key of the mode map is listed, and its docstring matches; with the default, no header or mode line names a key (`tests/el/homun-key-hints-test.el`).
4. **Stable layout.** No window jumping, no focus stealing, point kept on refresh; append rather than re-render.
   Example: `claude-board--draw` restores point to the same task row.
   Check: put point on a row, refresh (`g`), point stays; run a refresh from another window and focus does not move.
5. **Fast and incremental.** No redraw over 16 ms, updates batched, never blocking on the network; a spinner while busy.
   Example: transcript streaming appends deltas (`claude-transcript-stream.el`).
   Check: `homun-emacs profile start` / `report` while the view updates: no redraw above 16 ms; `C-g` stays responsive during a fetch.
6. **Honest state.** Show live, stale and failed. No silent drops; errors appear where they happen, not only in `*Messages*`.
   Example: a failed send stays in the compose queue with retry and drop beside it.
   Check: cut the network or the daemon; the view says stale or failed in place within one refresh.
7. **Emacs furniture.** Header, mode and tab lines, faces, `:box`, display properties; SVG only where it pays. Inherit the theme; no hard-coded colours.
   Example: `claude-header` on the header line; faces inherit `shadow`, `highlight`, `success`.
   Check: `git grep -nE '"#[0-9a-fA-F]{6}"' container/emacs` shows only a documented fallback; load a light and a dark theme and read both.
8. **Composes.** Plain interactive commands, normal major and minor modes, friendly to evil, imenu, outline, embark and consult.
   Example: `claude-compose-mode` is a minor mode with evil bindings added under `with-eval-after-load 'evil`.
   Check: every action is a `commandp`; `M-x imenu` and `consult-outline` list sections; evil normal state works.
9. **Degrades gracefully.** Works in a tty, a narrow phone frame and 4K, with a text fallback for every graphic.
   Example: the board checks `display-graphic-p` before drawing graphics.
   Check: `homun editor tty` shows everything readable; resize to 40 columns and to 4K; no unreadable box drawing or missing image.

## Faces inherit standard faces

Every face inherits what themes already style (`shadow`, `success`, `warning`, `error`, `font-lock-*`, `link`, `highlight`, `region`, `secondary-selection`, `header-line`, `fringe`, ...), so it follows any theme. A distinct colour (role accents, fills, SVG) is computed at draw time from those faces and the default colours, and recomputed through `enable-theme-functions`; widgetry does it in `widgetry-theme-apply`.
Check: `git grep -nE '"#[0-9a-fA-F]{6}"' container/emacs` lists only bare-frame fallbacks; load `modus-vivendi`, `modus-operandi` and a Doom theme and every face reads; `homun-emacs face get` shows no fixed colour on a `claude-*` or `widgetry-*` face.

## Appendix: audit

The current findings, with fix sizes, are in `design/emacs-ui-audit.md`.
