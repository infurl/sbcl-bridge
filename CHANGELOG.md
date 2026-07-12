# Changelog

All notable changes to sbcl-bridge, in reverse-chronological order.  There's
no version-number scheme for this project, so entries are dated instead.

## 2026-07-12

A significant batch, developed and verified against a working copy before
being deployed:

* **`stop` now escalates gracefully by default.** It cancels any in-flight
  request, then asks the running image to exit cleanly via an in-Lisp
  `(sb-ext:exit)` (checked by the bridge's watchdog thread whether idle or
  busy — unlike cancellation, which only ever applies mid-request), and only
  falls back to SIGTERM/SIGKILL if that doesn't work within
  `SBCL_STOP_TIMEOUT`. Use `stop --force` to skip straight to signals.

* **New `refresh` command** — stop + resume from `cores/current.core`, a new
  symlink maintained by `suspend`/`resume` that tracks whichever core was
  *actually* live, as distinct from `restart` (stop + a fresh start with no
  saved state) or blindly resuming the newest file on disk by mtime.

* **Named/pinned cores.** `suspend --name NAME` saves to `cores/NAME.core` and
  marks it exempt from automatic core-retention pruning;
  `resume`/`delete-core` accept a bare name in place of a full path;
  `delete-core` is the only way to remove a pinned one.  Steady-state disk
  usage for unpinned cores is `SBCL_CORE_RETAIN` plus one (the current core is
  always exempt too, which `refresh` depends on).

* **Startup hardening against duplicate bridges.** `run-bridge` now refuses to
  start if a live PID file already points at a real bridge watching the same
  directory (confirmed via `/proc/<pid>/environ`, not just a bare `kill -0`),
  auto-cleaning a genuinely stale PID file with no operator action
  needed. `status` also gained an on-demand scan that warns about strays
  independent of that startup-time gate.

* **Backtraces from threads other than the bridge's own main one.** A
  background thread started by submitted code (e.g. a web server's
  request-handler threads) that signals an unhandled condition is now logged,
  with a full backtrace, to a new `sbcl-async-errors.log` — only that thread
  terminates; the bridge and the rest of the process keep running. An
  unhandled condition on the bridge's own main thread is unaffected by this
  and remains fatal, as before.

* **Per-response timing and memory stats.** Every `END-OUTPUT` marker now
  carries `elapsed-ms=` and `consed-bytes=` alongside its status, for every
  outcome (not just `status=ok` — knowing how much a request cost before
  erroring or timing out is itself useful). `sbcl-client.sh` prints a `stats:
  ...` line to stderr after every response.

* **Timestamps on every log line.** `END-INPUT`/`END-OUTPUT` (previously only
  `BEGIN-INPUT`/`BEGIN-OUTPUT` had them) and the freestanding
  `CANCEL-REQUESTED`/`WATCHDOG-ERROR`/`SUSPENDING`/`RESUME:` lines all gained
  `ts=`.

* Fixed a latent bug (not introduced by this batch, caught while adding the
  async-backtrace feature above): backtrace capture relied on unexported
  `sb-debug` internals that silently produced an *empty* backtrace
  specifically when this file was loaded whole via `--load` — i.e. on every
  normal bridge startup — despite working fine compiled standalone. Replaced
  with the stable, exported `sb-debug:print-backtrace`.

## 2026-07-11

* Added `sbcl-client.lisp` (980 lines), a pure Common Lisp client/control
  library duplicating `sbcl-bridge-ctl.sh` and `sbcl-client.sh` as ordinary
  Lisp functions and conditions, maintained in parallel with the shell scripts
  and speaking the exact same on-disk protocol — a bridge started by one
  control surface can be controlled by either. A small, related adjustment
  landed in `sbcl-bridge.lisp` itself alongside it.

## 2026-07-10

* Compiled-fasl-cache (`XDG_CACHE_HOME`) integration: ASDF's
  output-translations are relocated automatically on resume if the cache
  directory has moved, so a resumed image reuses previously compiled `.fasl`
  files instead of recompiling from source.

* `CL_SOURCE_REGISTRY` integration: ASDF's source registry is similarly
  relocated on resume when the environment variable's value has changed since
  it was last synced.

## 2026-07-09

* Quicklisp (`QUICKLISP_HOME`) integration: install-if-needed,
  load-if-present, and relocate-if-moved handling, so a bridge session gets a
  working Quicklisp without repeating the compile cost on every resume. The
  single largest change to `sbcl-bridge.lisp` up to this point.

* Improved, then debugged, the regression test suite (two separate passes the
  same day).

* Fixed a path-comparison bug — the immediate precursor to the
  pathname-normalization pass the next day.

* **Normalized pathname handling throughout** — `sbcl-bridge-ctl.sh`,
  `sbcl-bridge.lisp`, and `sbcl-client.sh` all touched in the same commit —
  closing a class of bugs where a directory argument with (or without) a
  trailing slash could silently produce a malformed merged path (a doubled
  slash, or a dropped final path segment).

## 2026-07-08

* Requests now honor their own embedded `;;; REQID:`/`;;; TIMEOUT:` headers,
  and the bridge is started with `--no-sysinit --no-userinit` so a local
  `~/.sbclrc` can never make evaluation results environment-dependent.

* Improved the portability of suspended core images across machines — the
  `.version` sidecar recording SBCL version/machine-type/`SBCL_HOME` at save
  time, and the restoration logic that reads it back on resume.

* Made the shell scripts' permissions/tracing consistent (`set +x`).

* The client now checks for a live, recognizable bridge before queuing a
  request, rather than queuing blind.

* The bridge can now be resumed with `SBCL_BRIDGE_DIR` pointing at a different
  location than where it was suspended — the shared-workspace case where a
  core suspended on a host is resumed inside a container (or vice versa) at a
  different absolute path.

## 2026-07-07

* Added the regression/diagnostics test suite (`sbcl-bridge-test.sh`,
  226 lines to start), contributed by Claude Fable, alongside further work on
  the control script, bridge, and client.

* Added a disclaimer to the README.

## 2026-07-06

* **Initial commit**: `sbcl-bridge-ctl.sh`, `sbcl-bridge.lisp`, and
  `sbcl-client.sh` created — the three files that would go on to define the
  project.

* **First publicly-testable version**: substantial growth across all three
  core files, plus the first version of the README (723 lines).

* Fixed an `SBCL_HOME` restoration bug.

* Reformatted and fine-tuned the README's structure, tables, and list
  formatting.
