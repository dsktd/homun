# Emacs UI audit against docs/emacs-ui.md (2026-11-26)

Sizes: S under an hour, M a day, L several days. Fixed = done in this change.

| Rule | Place | Problem | Fix |
|---|---|---|---|
| 3 | transcript, board, compose | `?` was plain `describe-mode`, no key menu | Fixed: transient menus (S) |
| 7 | claude-remote.el button face | fixed blue and white | Fixed: inherits `highlight` (S) |
| 7 | claude-transcript.el (4 faces) | fixed hex backgrounds per dark/light | Derive from `default` background with `color-lighten-name` (S) |
| 7 | claude-follow.el, claude-phone.el palette, homun-stage.el fallbacks, init.el | hex colours; phone palette is a whole fixed theme | Fixed: phone, follow, transcript and Stage faces inherit the theme; stage palette fallbacks are used only when a face is unset (acceptable) |
| 4 | transcript (3 `erase-buffer` sites), doctor, compose | full re-render; point kept only in some | Fixed: transcript, Stage scene (doctor) and compose keep point and window start (M) |
| 2 | compose | no single-key actions (it is an edit buffer); `C-c ?` added | Acceptable for edit buffers |
| 8 | all views | no `imenu-create-index-function`, no outline setup | Fixed for the transcript: imenu and outline, one entry per message (M); board rows open |
| 3 | doctor, stage, phone, org questions | no `?` menu | Fixed: `?` menus (M) |
| 5 | all | no 16 ms redraw measurement in tests | Fixed in tests: a redraw timing check (`homun-ui-redraw-timing`, generous threshold); live profiling stays manual (L) |
| 6 | board, phone | stale versus live state not uniformly shown | Fixed: `claude-stale-badge` in `claude-header`, opted in by `claude-stale-after` (board); phone link already says retry/offline (M) |
| 9 | transcript, stage, widgetry | `display-graphic-p` used only in board; text fallback unchecked | Tty test run in `tests/` (L) |
| 1 | stage (SVG scenes) | scene text not searchable | Alt text layer under each scene (L) |
