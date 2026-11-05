# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A GNU ELPA-style Emacs Lisp package (`shell-edit.el`): `C-x C-e` copies a shell's pending command line into a fresh Emacs buffer, and `C-c C-c` / `C-c C-k` accept or discard the edit. Nothing is ever executed by the package — acceptance only places text on the shell's prompt. Targets Emacs 27.1+, licensed GPL-3.0-or-later (the header carries the SPDX tag; keep the standard ELPA header layout — Author, Version, Package-Requires, Keywords, URL — in order).

## Commands

Verify work with the byte compiler, the documentation linter, and the ERT suite:

```sh
# Byte-compile (catches lexical/scope/warnings issues)
emacs -Q --batch -f batch-byte-compile shell-edit.el

# checkdoc: docstring style, e.g. sentences end in periods
emacs -Q --batch --eval '(checkdoc-file "shell-edit.el")'

# the ERT suite (also `C-c p t` via projectile-project-test-cmd in .dir-locals.el)
emacs -Q --batch -L . -l shell-edit.el -l test/*-tests.el -f ert-run-tests-batch-and-exit

# byte-compile a new or changed test file (requires -L ., they load the package)
emacs -Q --batch -L . -f batch-byte-compile test/*-tests.el
```

`shell-edit.elc` is gitignored and should not be committed.

## Testing

The suite (`test/shell-edit-tests.el`, excluded from the ELPA tarball by `.elpaignore`) uses plain ERT. Every test is self-contained: it builds its own faked shell buffer, exercises the behavior, and cleans up inside `unwind-protect`.

### The fixture pattern

The suite never starts real shells. It dresses plain buffers up the way the shells dress theirs, mirroring the pty-location split in Architecture:

- **comint / term line mode** — a live, silent inferior process (`sleep`, with `set-process-query-on-exit-flag` nil) attached to the buffer, its `process-mark` parked after a prompt string like `user@host:~$ `, and `comint-accum-marker` set where comint keeps it. The pending input is whatever sits after the marker, so read/put-back are plain buffer edits (`se-test--comint-buffer`, `se-test--term-line-buffer`).
- **eshell** — the prompt text carries the `field` `prompt` property and `eshell-last-output-end` is a marker right after it, with the pending input following (`se-test--eshell-buffer`). `shell-edit--eshell-prompting-p` reads the `prompt` field: omitting the property simulates a command still running.
- **vterm and term char mode are not covered.** They keep the line inside the pty, where only readline/zle can reach it — nothing short of a real pty exercises them. Validate changes to those paths manually in a real vterm / `term` char-mode session; do not fake their process/terminal state in tests.

### Adding tests

Name tests `shell-edit-test-<topic>` and put them in `test/shell-edit-tests.el` (or a new `test/*-tests.el` file — the run and compile patterns above pick up every one). Docstrings must be checkdoc-clean. When you touch a backend — read-line, put-back, guard, dispatch, or the shared machinery — cover the same shape the existing backend tests do:

1. **read-line** on a dressed-up buffer: it returns the pending input, prompt excluded.
2. **put-back, live shell**: the old pending input is replaced, the prompt preserved, point ends at the end of the new input, the accumulator state reset (the detached `comint-accum-marker` reads back as a marker with no position).
3. **put-back, empty text**: the prompt is left with no pending input.
4. **put-back, dead shell**: a live process that has exited — or, for eshell, a shell no longer prompting — means the edit is discarded with a message and the buffer text is untouched.
5. **the interactive command's guard**: `should-error ... :type 'user-error` when the shell is not accepting input.
6. **a round trip** through the real put-back: open the editor with the backend command, edit, `shell-edit-accept`, then assert both the source buffer's text and its point — it must rest at the end of the pending input, since the put-back has the last word on point (see the load-bearing accept ordering in Architecture).

### Gotchas learned writing the suite

`delete-process` inserts a `Process ... killed` notification into the process's buffer (and detaches it — `get-buffer-process` returns nil afterwards), so for dead-shell assertions check the region you care about or the presence/absence of specific strings, not the whole buffer text. `lookup-key` does not resolve `[t]` fallback bindings — query the `[t]` key directly. Shared globals such as `shell-edit--counter` persist across tests; never assert on their values.

## Architecture

The file is organized in five sections after the header, connected by one contract:

**The put-back contract.** Every backend registers itself via `shell-edit--open` with three arguments: the SOURCE shell buffer, the LINE text to edit, and a PUT-BACK function of `(SOURCE-BUFFER TEXT)` that places TEXT on the shell's prompt. The edit buffer carries that pair in buffer-locals `shell-edit--source` / `shell-edit--put-back`. When changing a backend, all three parts must stay consistent.

**Backends vs. pty location.** The central design fact (see Commentary): `eshell` and comint (`M-x shell`) keep pending input *in the buffer*, after a marker — `eshell-last-output-end` or `process-mark` — so reading and put-back are plain buffer edits. `vterm` and a char-mode `term` keep it *inside the pty*, where only readline/zle can reach it, so those backends read the terminal screen between cursor positions and put back by emitting readline keys (`C-a`, `C-k`, `C-l` — `C-l` redraws the wrapped line so screen and buffer stay in sync). Comint/term-line-mode put-backs need `inhibit-read-only` and must run in the SOURCE buffer.

**Accept ordering is load-bearing.** `shell-edit-accept` kills the edit buffer *before* calling the put-back, on purpose: killing hands the window back to the shell buffer, whose stale point redisplay remembers, and the put-back must have the last word on point (it leaves point at end of pending input, where RET runs it). Do not reorder this.

**The four backend commands** exist because read/put-back are mode-specific; `shell-edit` dispatches among them with `derived-mode-p` for setups that bind one command. Each backend has the shape `shell-edit-<mode>-read-line` / `shell-edit-<mode>-put-back` / `shell-edit-<mode>`.

**Guard pattern.** Interactive commands refuse with `user-error` when the shell isn't accepting input (e.g. `shell-edit--eshell-prompting-p` checks the `prompt` text field; a command still running means eshell hasn't redrawn `eshell-last-output-end` yet); put-backs re-check liveness and quietly discard the edit with a message when the shell died meanwhile.

**Cross-package references declare, never require.** Beyond `(require 'comint)`, every vterm/term/eshell symbol is referenced via `declare-function` for functions and `eval-when-compile` defvars for variables — the package must not load those libraries, and the byte compiler must stay silent about them. Follow that pattern for any new backend.

**Automatic bindings** live at the bottom in `with-eval-after-load` blocks per library. Two subtleties: eshell's keymap is defined by `esh-mode`, which only loads with the first eshell buffer (waiting for the `eshell` feature is not enough), and term's char mode rebuilds the `C-x` prefix in `term-raw-map` via `shell-edit--term-raw-ctl-x-map` rather than binding a plain `C-x C-e` — the `[t]` binding (`shell-edit--term-send-raw-keys`) forwarding whole key sequences is what keeps every other raw `C-x` chord reaching the inferior's pty.
