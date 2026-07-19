# SBCL Bridge

A file-based request/response bridge for driving a headless SBCL (Steel Bank
Common Lisp) process from an external tool — typically a coding agent —
without the debugging-protocol chatter that Swank adds.

This document covers five files:

- `sbcl-bridge.lisp` — the Lisp code that runs *inside* the persistent SBCL process.
- `sbcl-bridge-ctl.sh` — process manager: start/stop/restart/status/suspend/resume/etc.
- `sbcl-client.sh` — client: submit code to a running bridge and wait for the result.
- `sbcl-client.lisp` — a pure Common Lisp reimplementation of the two scripts
  above, for driving a bridge from *another* running SBCL image instead of
  the shell. Speaks the same on-disk protocol; maintained in parallel, not a
  replacement — see "sbcl-client.lisp" below.
- `sbcl-bridge-test.sh` — end-to-end smoke test: spins up a throwaway bridge
  in a temp directory and exercises every major behavior in ~60 seconds. Run
  it after any SBCL upgrade or change to the bridge itself.

See [`CHANGELOG.md`](CHANGELOG.md) for the dated history of what's changed.
For design rationale, the theory of operation, and every bug found building
this, see [MAINTENANCE.md](MAINTENANCE.md).

> **Provenance and AI Disclosure**
>
> This project was synthesized through close collaboration between an
  experienced human programmer and multiple AI models.
>
> * Primarily authored with the help of Claude Sonnet.
>
> * Tested and optimized with the help of Claude Fable and Gemini Pro.
>
> It is published openly for community scrutiny and iteration.

---

## What it is

Swank (the protocol behind SLIME/SLY) is designed for interactive debugging
from an editor. SBCL Bridge instead uses the simplest mechanism that works
reliably in a container with no REPL, no TTY, and no systemd: **plain
files**, with a background loop watching a directory. A single SBCL process
runs forever; a caller drops a request file, the bridge evaluates it and
writes the result to a log, and a client script waits for and returns that
result. State persists across requests — the whole point is a persistent,
interactive SBCL session a coding agent can treat like a REPL.

## Installation & requirements

- **SBCL** with thread support (`:sb-thread` in `*features*` — true of
  essentially every mainstream Linux build). Without thread support,
  cancellation is disabled but everything else still works; the bridge prints
  a warning at startup in that case.
- **Bash**, `gzip`, standard coreutils (`ps`, `awk`, `sed`, `mktemp`, `wc`,
  `ls`). GNU `date` is assumed but not required.
- No systemd, no cron, no network daemon — everything here is designed to work
  unmodified inside a bare Docker container.

Put the files on disk together (or anywhere, as long as you either keep
`sbcl-bridge.lisp` alongside `sbcl-bridge-ctl.sh` or point `SBCL_BRIDGE_LISP`
at it), and make the shell scripts executable:

```bash
chmod +x sbcl-bridge-ctl.sh sbcl-client.sh sbcl-bridge-test.sh
```

## Quickstart

```bash
export SBCL_BRIDGE_DIR=/path/to/bridge   # where all the files above will live
export SBCL_BRIDGE_LISP=/path/to/sbcl-bridge.lisp

./sbcl-bridge-ctl.sh start
./sbcl-bridge-ctl.sh status

./sbcl-client.sh eval '(+ 1 2 3)'
# ;;; => 6

./sbcl-client.sh eval '(defun square (x) (* x x)) (square 12)'
# ;;; => SQUARE
# ;;; => 144

echo '(format nil "hello, ~a" (get-universal-time))' > /tmp/code.lisp
./sbcl-client.sh file /tmp/code.lisp

./sbcl-bridge-ctl.sh stop
```

Both scripts read `SBCL_BRIDGE_DIR` from the environment, so exporting it once
per shell session is the easiest way to work.

Verify the whole installation end to end (uses throwaway temp directories,
needs no setup):

```bash
./sbcl-bridge-test.sh
# ...
# == 44 passed, 0 failed ==
#
# Diagnostics bundle: /path/you/ran/this/from/sbcl-bridge-test-diagnostics-20260101-120000.tar.gz
```

Every run — pass or fail — writes that diagnostics bundle (transcript,
pass/fail summary, environment info, and every touched bridge directory's
logs) to the directory you ran it from; attach it rather than describing a
failure secondhand if you need help debugging one on a machine nobody else
can log into.

## Reference

### Directory layout

Everything lives in one "bridge directory" (`$SBCL_BRIDGE_DIR`, or the
`:directory` argument to `run-bridge`):

```
bridge-dir/
├── next-sbcl-input.lisp          # dropped by a client
├── next-sbcl-input.working       # request currently being processed
├── sbcl-input.log                # append-only record of every request
├── sbcl-output.log               # append-only record of every response
├── cancel-request                # dropped by `ctl.sh interrupt`
├── .sbcl-bridge.pid              # PID file written by ctl.sh
├── processed/                    # archived requests, named <reqid>.lisp
│   ├── error-<timestamp>.lisp    # archived if renaming failed
│   └── leftover-<timestamp>.lisp # unfinished request found at startup
├── cores/                        # suspended executable images and metadata
│   ├── bridge-<timestamp>.core
│   └── bridge-<timestamp>.core.version
├── quicklisp-installer.lisp      # cached quicklisp.lisp download
└── logs/                         # rotated, gzipped log generations
    ├── sbcl-output.log.<timestamp>.gz
    └── sbcl-input.log.<timestamp>.gz
```

### The request format

A request is just Lisp source text, optionally preceded by header comment
lines:

```lisp
;;; REQID: my-unique-id
;;; TIMEOUT: 45
(defun square (x) (* x x))
(square 12)
```

- **`REQID`** correlates a request with its response. If omitted, the bridge
  synthesizes one. The archive *filename* in `processed/` is sanitized to
  alphanumerics plus `.`/`_`/`-` and capped at 100 characters — distinct raw
  ids that sanitize to the same name overwrite each other in the archive.
- **`TIMEOUT`** overrides the bridge's default per-request timeout (seconds),
  or disables it entirely with the literal value `none`. Any non-positive
  value also **disables** the timeout rather than timing out immediately, and
  an unparseable value silently falls back to the bridge default.

These are ordinary `;;; ...` Lisp comments — no preprocessing step strips
them, and a request with no headers at all is just as valid as one with both.

Every top-level form in the request is read and evaluated **in sequence**,
in the order they appear. **State persists across requests — that's the
point.** Everything a request does to the global environment (function/
variable definitions, loaded systems, `*package*`, `*readtable*`, `*print-*`
settings) carries over to every later request, until something changes it
back. If you want a predictable environment per request, either start each
request with an explicit `(in-package ...)`, or wrap state changes you don't
want to leak in a `let` that rebinds the relevant specials for just that
request.

### The response format

Every request produces a block in `sbcl-output.log`:

```
;;; BEGIN-OUTPUT id=my-unique-id ts=3987654321
;;; => 144
;;; END-OUTPUT id=my-unique-id status=ok ts=3987654321 elapsed-ms=4 consed-bytes=131136
```

Every `END-OUTPUT` line carries `ts=`/`elapsed-ms=`/`consed-bytes=` (wall
time and allocation for that request), for every outcome, not just
`status=ok` — `sbcl-client.sh` prints a matching `stats: ...` line to
stderr after every response. `END-INPUT` and the standalone
`CANCEL-REQUESTED`/`WATCHDOG-ERROR`/`SUSPENDING`/`RESUME:` log lines carry
`ts=` too.

- One `;;; => value1 ; value2 ; ...` line is printed per evaluated form,
  using `~S`, with multiple return values separated by `;`. A value whose
  *printing* signals is rendered as `#<unprintable TYPE>` instead — the form
  evaluated successfully, so a presentation failure doesn't flip the request
  to `status=error`.
- `status=` on the `END-OUTPUT` line is always one of: `ok`, `error` (an
  `ERROR` condition was signalled), `timeout`, `cancelled` (via `ctl.sh
  interrupt`), or `fatal-condition` (a non-`ERROR` `SERIOUS-CONDITION`, e.g.
  `STORAGE-CONDITION` for heap/stack exhaustion).

`error` and `fatal-condition` responses also include a bracketed backtrace:

```
;;; BEGIN-OUTPUT id=abc ts=123
;;; ERROR: arithmetic error DIVISION-BY-ZERO signalled
Operation was (/ 5 0).
;;; BACKTRACE-BEGIN id=abc
0: (SB-KERNEL::INTEGER-/-INTEGER 5 0)
1: (SB-INT:SIMPLE-EVAL-IN-LEXENV (LEVEL-A 5) #<NULL-LEXENV>)
2: (EVAL (LEVEL-A 5))
;;; BACKTRACE-END id=abc
;;; END-OUTPUT id=abc status=error
```

Meanwhile `sbcl-input.log` gets the raw request text, similarly bracketed,
purely for audit/debugging purposes — it's never read back by any part of
the system.

### Request lifecycle

1. Client writes `next-sbcl-input.lisp` (atomically, by hard-linking a temp
   file into place — which fails, rather than overwriting, if a request is
   already queued; the client waits for the slot in that case).
2. Bridge notices it, immediately renames it to `next-sbcl-input.working` —
   clearing the way for the next request as soon as one is claimed, rather
   than only after it finishes.
3. Bridge logs the request, evaluates it, prints the response.
4. Bridge renames the working file to `processed/<reqid>.lisp`.

If the process dies *unexpectedly* between steps 2 and 4, the next
`run-bridge` startup finds the orphaned `next-sbcl-input.working` and
archives it as `processed/leftover-<timestamp>.lisp` rather than leaving it
stuck — a crash never wedges the input slot shut. A normal suspend/resume
cycle leaves no leftover.

### `sbcl-bridge.lisp` exported symbols

- **`sbcl-bridge:run-bridge`** — the main entry point. Never returns under
  normal operation.

  ```lisp
  (sbcl-bridge:run-bridge
    :directory "/path/to/bridge/"   ; required
    :poll-interval 0.2              ; seconds between directory checks when idle
    :default-timeout 30             ; seconds; NIL disables unless overridden per-request
    :backtrace-frames 20            ; max frames in an error/backtrace report
    :input-name "next-sbcl-input.lisp"
    :working-name "next-sbcl-input.working"
    :input-log-name "sbcl-input.log"
    :archive-subdir "processed")
  ```

  In practice you only ever pass `:directory`; the shell scripts invoke it
  exactly that way, and everything else uses its default.

- **`sbcl-bridge:suspend-bridge`** — saves an executable core image and
  terminates the process (see "Suspend & resume" below). Normally invoked
  *through* the bridge protocol by `ctl.sh suspend`, not called directly.

### `sbcl-bridge-ctl.sh` — process management

No systemd required. Uses a PID file and plain `kill`, works identically
inside a container. **Exit codes:** `0` on success, `1` on any failure,
uniformly across every subcommand, with the specific reason always in the
stderr message.

**Commands:**

- `start` — cold-starts a fresh SBCL process running `run-bridge`. No-op
  (with a message) if already running. Always run with `--no-sysinit
  --no-userinit`, so behavior can't depend on a stray `/etc/sbclrc` or
  `~/.sbclrc`; anything an init file would have provided can be loaded
  explicitly as an ordinary first request instead.
- `stop [--force]` — escalates gracefully by default: cancels any in-flight
  request, then drops a `stop-request` file the bridge's watchdog thread
  checks (whether idle or busy — unlike `interrupt`'s `cancel-request`,
  which only does anything mid-request) to trigger an in-Lisp
  `(sb-ext:exit)`, only falling back to `SIGTERM`/`SIGKILL` if that doesn't
  work within `SBCL_STOP_TIMEOUT`. `--force` skips straight to signals
  (e.g. if the watchdog thread itself is wedged).
- `restart` — `stop` then a *fresh* `start` (no saved state).
- `refresh` — `stop` then `resume` from `cores/current.core`: the core that
  was actually live, not just the newest file on disk by mtime. Errors
  clearly if there's no `current.core` symlink yet.
- `status` — reports running/stopped, PID, uptime, RSS/VSZ memory, saved
  core images (including pinned-core names), log sizes, and the number of
  archived request files. Also triggers cheap housekeeping: a size-based
  log-rotation check and pruning of `processed/` down to
  `SBCL_PROCESSED_RETAIN` files.
- `suspend [core-path] [--name NAME]` — saves an executable core image and
  stops the process (see "Suspend & resume" below). Defaults to
  `cores/bridge-<timestamp>.core`. `--name NAME` saves to `cores/NAME.core`
  and pins it (a `.pinned` sidecar) — exempt from `SBCL_CORE_RETAIN`'s
  automatic pruning, deletable only via `delete-core`.
- `resume [core-path-or-name]` — resumes from a saved core image. Defaults
  to the most recent one in `cores/`; also accepts a bare pinned-core name.
- `delete-core <name-or-path> [--force]` — the only way to remove a pinned
  core.
- `interrupt [reqid]` — cancels whatever request is currently running, or a
  specific one by id (see "Cancellation" below).
- `logs [-f] [lines]` — prints the last N lines (default 50) of
  `sbcl-output.log`, or follows it live with `-f`.
- `rotate-logs [--force]` — rotates logs now. Without `--force`, only
  rotates logs that have actually exceeded `SBCL_LOG_MAX_BYTES`, and never
  while a request is queued or in flight.

**A note on core retention with pinned cores:** `cores/current.core` (what
`refresh` resumes from) is *also* exempt from `SBCL_CORE_RETAIN` pruning,
so a `refresh` never points at something already deleted. Steady-state disk
usage for unpinned cores is therefore `SBCL_CORE_RETAIN` **plus one** (the
current one, plus the retained budget), not exactly `SBCL_CORE_RETAIN`.

**Environment variables:**

- `SBCL_BRIDGE_DIR` — default `.` — directory the bridge monitors.
- `SBCL_BRIDGE_LISP` — default: alongside this script — path to `sbcl-bridge.lisp`.
- `SBCL_BIN` — default `sbcl` — the SBCL executable to run.
- `SBCL_CORE_RETAIN` — default `3` — number of suspended core images to keep.
- `SBCL_PROCESSED_RETAIN` — default `200` — number of archived request files to keep.
- `SBCL_STOP_TIMEOUT` — default `10` — seconds to wait for graceful exit before `SIGKILL` on `stop`.
- `SBCL_SUSPEND_TIMEOUT` — default `60` — seconds to wait for `suspend` to finish.
- `SBCL_LOG_MAX_BYTES` — default `10485760` (10 MiB) — a log is rotated once it exceeds this size.
- `SBCL_LOG_RETAIN` — default `5` — number of rotated, gzipped log generations to keep (per log file).
- `SBCL_MEM_WARN_MB` — default: unset — if set, `status` prints a warning when RSS exceeds this many MB.

### `sbcl-client.sh` — submitting work

```bash
sbcl-client.sh eval '<lisp forms...>'
sbcl-client.sh file <path-to-lisp-file>     # shortcut: submit an existing file
sbcl-client.sh -                            # read code from stdin
```

Before touching anything, the client checks that `SBCL_BRIDGE_DIR` actually
looks like it's being watched by a *live* bridge (a pidfile exists, its PID
is alive, and looks like an `sbcl` process) — a directory can exist with no
bridge behind it, and without this check a submission against a dead bridge
would otherwise sit until `SBCL_TIMEOUT` and report a misleading timeout
instead of the real problem. Each failure prints a specific reason and exits
6.

**Embedded headers: self-describing request files.** A request file can
carry its own headers, and submitting it through the client Just Works —
the idiomatic way to package a setup script that knows its own identity and
how long it's allowed to take:

```lisp
;;; REQID: project-setup
;;; TIMEOUT: 45

(in-package #:cl-user)
(dolist (file '("package.lisp" "utils.lisp" "server.lisp"))
  (load (merge-pathnames file #P"/workspace/myproject/src/")))
(defparameter *server-ready* t)
```

```bash
./sbcl-client.sh file project-setup.lisp
# ...
# ;;; END-OUTPUT id=project-setup status=ok
```

Precedence for the evaluation timeout, highest first: `SBCL_REQUEST_TIMEOUT`
(env) → embedded `;;; TIMEOUT:` header → the bridge's default.
`SBCL_TIMEOUT`, when set, still overrides the client's *wait budget*
unconditionally. One caveat with a fixed, reused `REQID`: each run's
`processed/` archive overwrites the previous one — fine for setup scripts,
less ideal for requests you want to tell apart later.

**Environment variables:**

- `SBCL_BRIDGE_DIR` — default `.` — directory the bridge monitors.
- `SBCL_POLL_INTERVAL` — default `0.2` — seconds between checks of the output log.
- `SBCL_TIMEOUT` — default larger of `30` or the effective evaluation timeout + 5
  — total seconds this script waits before giving up (covers both queueing
  and receiving the response).
- `SBCL_REQUEST_TIMEOUT` — default unset, use bridge default — seconds the
  *bridge* allows the evaluation itself to run. `none` disables it for this request.

**Exit codes** — a deliberate, disjoint scheme meant to be a stable contract
for scripted or agent callers. Codes 0–5 mean the request was delivered and
the bridge reported an outcome; codes 6–7 mean the request was **never
delivered**:

- **0** — `status=ok`
- **1** — `status=error` (an `ERROR` condition was signalled)
- **2** — no response within the wait budget — the request **was**
  submitted; this script gave up waiting, not the bridge reporting a timeout
- **3** — `status=timeout` — the bridge-side per-request timeout expired
- **4** — `status=cancelled` — cancelled via `ctl.sh interrupt`
- **5** — `status=fatal-condition` — a non-`ERROR` `SERIOUS-CONDITION` occurred
- **6** — usage or preflight error — nothing was submitted; fix your setup, retrying won't help
- **7** — could not submit in time — the input slot never freed up; the bridge is just busy

Two distinctions worth internalizing: exit 2 is this *script* giving up
waiting, exit 3 is the *bridge* reporting it gave up evaluating. Exit 6 is a
*setup* problem (fix it before retrying); exit 7 is *contention* (retry,
wait, or `interrupt` whatever's queued).

### Feature usage

**Timeouts.** Every request runs under `sb-ext:with-timeout`, bounding the
*entire* request. Default 30 seconds; override per request:

```bash
SBCL_REQUEST_TIMEOUT=5 ./sbcl-client.sh eval '(sleep 10)'
# ;;; TIMEOUT after 5 seconds
# ;;; END-OUTPUT id=... status=timeout      (client exit code 3)

SBCL_REQUEST_TIMEOUT=none ./sbcl-client.sh eval '(long-running-computation)'
```

A timeout cleanly unwinds the request and returns control to the main loop —
the bridge itself is completely unaffected and ready for the next request
immediately. A value of `0` (or anything negative) **disables** the timeout,
same as `none`; an unparseable value silently falls back to the bridge's
default.

**Cancellation.** `ctl.sh interrupt` stops a request you don't want to wait
out:

```bash
# in one terminal/process:
SBCL_REQUEST_TIMEOUT=none ./sbcl-client.sh eval '(sleep 60)'
# ... blocks ...

# in another:
./sbcl-bridge-ctl.sh interrupt
# Cancellation requested for whatever request is currently running.
```

The first command returns almost immediately with `status=cancelled`
(client exit code 4) instead of waiting the full 60 seconds. Omit `reqid` to
cancel whatever's currently running; supply one to only cancel if it
matches. **Limitation:** this relies on SBCL delivering the interrupt at a
"safepoint" — a request stuck entirely inside a blocking foreign/C call
would not be interruptible this way.

**Condition handling & backtraces.** Beyond ordinary `ERROR` conditions,
`STORAGE-CONDITION` (heap/stack exhaustion) and any other
`SERIOUS-CONDITION` are also caught per-request, so a single catastrophic
request can't take the whole process down. Every `error`/`storage-condition`
report includes a backtrace, truncated to `*bridge-backtrace-frames*`
(default 20) and filtered to stop as soon as it reaches the bridge's own
internal machinery:

```bash
./sbcl-client.sh eval '(defun f (x) (/ x 0)) (f 5)'
```
```
;;; => F
;;; ERROR: arithmetic error DIVISION-BY-ZERO signalled
Operation was (/ 5 0).
;;; BACKTRACE-BEGIN id=...
0: (SB-KERNEL::INTEGER-/-INTEGER 5 0)
1: (SB-INT:SIMPLE-EVAL-IN-LEXENV (F 5) #<NULL-LEXENV>)
2: (EVAL (F 5))
;;; BACKTRACE-END id=...
;;; END-OUTPUT id=... status=error
```

**Cross-thread backtraces.** A background thread started by submitted code
(e.g. a web server's request-handler threads) that signals an unhandled
condition is logged, with a full backtrace, to a separate
`sbcl-async-errors.log` — only that thread terminates; the bridge and the
rest of the process keep running. An unhandled condition on the bridge's
own main thread is unaffected by this and remains fatal, as always. See
"Known limitations" below for the scope of what this does and doesn't
catch.

**Suspend & resume.** The bridge can save its entire in-memory state to disk
and pick up again later exactly where it left off:

```bash
./sbcl-bridge-ctl.sh suspend
# Suspended. Core image saved: cores/bridge-20260706-032300.core

./sbcl-bridge-ctl.sh resume
# Resuming from cores/bridge-20260706-032300.core ...
# Resumed (pid 2701).
```

Practical facts worth knowing:

- `suspend` queues behind anything already in flight rather than
  interrupting it, and carries `;;; TIMEOUT: none` (a full GC plus writing a
  large heap to disk can legitimately take a while) — `SBCL_SUSPEND_TIMEOUT`
  is the only limit that applies. A timed-out suspend is withdrawn (removed
  from the queue), not left armed to fire later by surprise.
- **Contrib modules and `SBCL_HOME`.** A resumed image has no idea where
  SBCL's contrib modules live on disk unless `ctl.sh resume` restores
  `SBCL_HOME` for it (which it does automatically). Anything that calls
  `cl:require` for a contrib (`sb-posix`, `asdf`, `sb-bsd-sockets`, etc. —
  many Quicklisp systems pull these in transitively) that wasn't already
  loaded *before* the suspend can fail with `Don't know how to REQUIRE ...`
  after a resume. **The robust practice:** load everything your workload
  needs *before* suspending, rather than right after a bare `start` — once a
  contrib is loaded into the image, it's baked into the heap and never
  needs to be found on disk again. See MAINTENANCE.md for the full
  mechanism and why it needs to work this way.
- **Moved workspaces.** If a suspended core is resumed with a different
  `SBCL_BRIDGE_DIR` set in its environment than the one baked into the
  image (e.g. a host/container shared-workspace setup mounting the same
  directory at different paths), the current environment's value wins
  automatically — `ctl.sh resume` always exports it as an absolute,
  symlink-resolved path for the child it launches.
- **Version metadata.** A sidecar file (`<core-path>.version`) records the
  SBCL version/machine-type at save time; `resume` warns (not a hard
  failure) on a mismatch.
- **Core retention.** `suspend` prunes down to `SBCL_CORE_RETAIN` (default
  3) most recent images, but only *after* confirming the new one saved
  successfully.
- **Crash resilience.** If the process dies without going through
  `suspend-bridge`, the next startup finds the stale working file and
  archives it as `processed/leftover-<timestamp>.lisp` automatically.

**Log rotation.**

```bash
./sbcl-bridge-ctl.sh rotate-logs            # rotate only if over SBCL_LOG_MAX_BYTES
./sbcl-bridge-ctl.sh rotate-logs --force    # rotate regardless of current size
```

You generally don't need to call this yourself: `ctl.sh status` performs the
same size check every time it runs, so anything that polls status
periodically keeps both logs bounded for free. Rotation is skipped while a
request is queued or in flight, so a waiting client is never stranded;
`rotate-logs --force` overrides this. Rotated generations are kept
separately per log file (`SBCL_LOG_RETAIN`, default 5 each), gzip-compressed,
named `logs/<original-name>.<timestamp>.gz`.

**Memory reporting.**

```bash
./sbcl-bridge-ctl.sh status
# RUNNING (pid=2771, uptime=00:12:34)
# Memory: RSS=142MB VSZ=1312MB
# Saved core images (newest first): ...
# Logs: sbcl-output.log=48KB sbcl-input.log=12KB
# Processed archive: 37 request file(s) (retention: 200)
```

Set `SBCL_MEM_WARN_MB` to have `status` print a warning (to stderr) whenever
RSS exceeds that threshold.

**Quicklisp integration.** If `QUICKLISP_HOME` is set, the bridge makes a
best-effort attempt, on every start or resume, to have a working Quicklisp
available there and pointed there — installing fresh if nothing's there
yet, loading it if it's installed but not yet loaded, or redirecting an
already-loaded client if `QUICKLISP_HOME` now names a different directory
than what's baked into the image. Opt-in entirely by that variable's
presence; unset, none of this runs.

```bash
export QUICKLISP_HOME=/workspace/quicklisp
./sbcl-bridge-ctl.sh start
# sbcl-output.log:
# ;;; QUICKLISP: loaded, home=/workspace/quicklisp/
```

Every step is best-effort: a failure at any point is logged with a `;;;
QUICKLISP: ...` line explaining what happened, and the bridge continues
normally, usable for anything that doesn't need Quicklisp. See
MAINTENANCE.md for the redirect mechanism and why it's not just one `setf`.

**ASDF cache relocation.** If `XDG_CACHE_HOME` is set and ASDF is already
loaded, the bridge keeps ASDF's compiled-fasl output cache pointed at the
*current* `XDG_CACHE_HOME` on every start/resume:

```bash
export XDG_CACHE_HOME=/workspace/cache
./sbcl-bridge-ctl.sh start
./sbcl-client.sh eval '(require :asdf)'
./sbcl-bridge-ctl.sh suspend
# ... resume somewhere XDG_CACHE_HOME is /different/cache ...
./sbcl-bridge-ctl.sh resume
# sbcl-output.log:
# ;;; ASDF: XDG_CACHE_HOME changed: /workspace/cache/common-lisp/... -> /different/cache/common-lisp/...
```

**`CL_SOURCE_REGISTRY` relocation.** Same idea, independently, for where
ASDF looks to *find* systems (as opposed to where it caches compiled
output) — serves users who never touch Quicklisp at all:

```bash
export CL_SOURCE_REGISTRY=/workspace/my-project//
./sbcl-bridge-ctl.sh start
./sbcl-client.sh eval '(require :asdf)'
./sbcl-bridge-ctl.sh suspend
# ... resume somewhere CL_SOURCE_REGISTRY is /different/project// ...
./sbcl-bridge-ctl.sh resume
# sbcl-output.log:
# ;;; ASDF: CL_SOURCE_REGISTRY changed: /workspace/my-project// -> /different/project//
```

### Known limitations & caveats

Worth internalizing before you rely on this in production:

- **Single request in flight at a time**, by design. The client blocks
  until it sees its response; concurrent callers queue safely (no
  fairness guarantee between simultaneous waiters).
- **No sandboxing.** Submitted code runs with the full privileges of the
  SBCL process. Add a safety margin at the Docker layer if you need one,
  rather than in the bridge itself.
- **No isolation between requests, by design** — see "State persists across
  requests" above. That's the feature; the caveat is a request can leave
  the environment in a state a later request doesn't expect.
- **Response markers can be spoofed by the code being evaluated** — the
  protocol is plain text on a shared log. Treat evaluated code as trusted
  (which it inherently is anyway, given no sandboxing). If an agent
  evaluates content derived from untrusted input, validate results
  independently rather than trusting the reported `status=` alone.
- **Cancellation needs a safepoint** — code stuck inside a blocking foreign
  call won't respond to `interrupt`.
- **`suspend` can fail with `ERROR: failed AVER: (THREAD-P THREAD)`
  against a process that's been alive for hours and spawned/exited many
  short-lived threads** (a Hunchentoot server — one worker thread per
  request — is the textbook trigger; any thread-per-task pattern
  qualifies). A known-fragile area of SBCL itself, not this tool's own bug
  — see MAINTENANCE.md for the root-cause research. **Practical rule: only
  ever suspend a freshly-restarted process, never a long-uptime one** —
  `ctl.sh restart` immediately before `ctl.sh suspend`, reload whatever the
  workload needs, then suspend, unless you have a specific reason to
  preserve that exact process's live state.
- **A process a failed `suspend` didn't cleanly exit from should be
  considered corrupted enough to kill, not retried against** — the SBCL
  manual's own wording, worth remembering generally.
- **The startup duplicate-bridge guard narrows the launch race between two
  processes starting against the same directory, it doesn't eliminate
  it** — see MAINTENANCE.md for why a fully rigorous fix isn't worth the
  tradeoff here. Worth an occasional `ps aux | grep -i sbcl` sanity check
  after any irregular stop/kill.
- **Cross-thread backtraces (`sbcl-async-errors.log`) only catch conditions
  that reach the top of a thread's stack genuinely unhandled** — a thread
  spawned by a library with its own top-level error handling (e.g.
  Hunchentoot's request-handler threads) won't show up here. An unhandled
  condition on the bridge's own main thread remains fatal to the whole
  process, unaffected by this.
- **Version-compatibility check on resume is advisory, not a guarantee.**
  A warning means "look into this," not "this definitely won't work."
- **No log rotation or archive pruning without something calling
  `status`.** A completely dormant bridge with nobody checking on it won't
  clean up after itself.
- **A fresh Quicklisp install needs real network access to
  `beta.quicklisp.org`** as a last resort, only reached if no local
  installer/cache is found. See MAINTENANCE.md for how to avoid it in a
  network-restricted container.
- **Absolute paths a setup script bakes in on its own are outside anything
  this tooling can see** — e.g. a project-specific `local-projects/`
  symlink target. Everything this tooling itself controls (watched
  directory, `SBCL_HOME`, Quicklisp's home, ASDF's fasl cache and
  source-registry) is relocated automatically on resume; your own baked-in
  paths are not.

### `sbcl-client.lisp` — pure Lisp client/control library

A pure Common Lisp reimplementation of `sbcl-bridge-ctl.sh` and
`sbcl-client.sh`, for driving a bridge from *another* running SBCL image
instead of the shell. Speaks the exact same on-disk protocol those scripts
do — a bridge started with `sbcl-bridge-ctl.sh` can be controlled from here,
and vice versa, neither side knowing or caring which started it.

```lisp
(load "sbcl-client.lisp")
(sbcl-bridge-client:bridge-start :directory "/tmp/my-bridge")
(sbcl-bridge-client:bridge-eval "(+ 1 2)")
;; => "3"
(sbcl-bridge-client:bridge-suspend)
(sbcl-bridge-client:bridge-resume)
(sbcl-bridge-client:bridge-stop)
```

Configuration mirrors the shell scripts' environment variables exactly —
`*bridge-dir*` reads `SBCL_BRIDGE_DIR`, `*poll-interval*` reads
`SBCL_POLL_INTERVAL`, and so on. Every function also accepts a `:directory`
(and other relevant) keyword to override the ambient default for one call.

**Current scope:** every `sbcl-bridge-ctl.sh` command (`start`, `stop`,
`restart`, `status`, `suspend`, `resume`, `interrupt`, `rotate-logs`,
`logs`) and `sbcl-client.sh`'s submission protocol, each as an ordinary
function. Where the shell client distinguishes outcomes by exit code, this
library signals a condition — `bridge-evaluation-error`,
`bridge-request-timeout-error`, `bridge-cancelled-error`, and so on, all
subclasses of `bridge-error` — with the reqid and raw response text
attached, or, with `bridge-eval`'s `:signal-errors nil`, returned as extra
values instead for callers who'd rather branch on a status keyword than
handle conditions. **Not yet ported:** `sbcl-bridge-test.sh`'s 44-check
smoke suite.

## Cookbook

### Troubleshooting

- **`sbcl-client.sh` exits 6 with "No bridge appears to be running" /
  "Stale .sbcl-bridge.pid" / "doesn't look like an sbcl process"** — the
  client's preflight liveness check caught the problem before submitting
  anything. Run `ctl.sh status`, and `ctl.sh start` if nothing is running.
- **`sbcl-client.sh` exits 7 ("timed out ... waiting for the input slot")**
  — another request stayed queued for the whole wait budget. The bridge is
  alive and busy, not broken — raise `SBCL_TIMEOUT`, wait and retry, or
  `ctl.sh interrupt` whatever's occupying it.
- **`sbcl-client.sh` exits 2 ("timed out ... waiting for response")** — the
  request **was** delivered; either evaluation is still running, or the
  bridge died during the wait. Raise `SBCL_TIMEOUT` if it's just slow, or
  run `ctl.sh status` to check the bridge is still alive.
- **`ctl.sh suspend` reports "did not complete ... withdrawn"** — a
  long-running request was in flight and `SBCL_SUSPEND_TIMEOUT` expired.
  The queued suspend has been removed; wait for (or `interrupt`) the
  in-flight request and try again, possibly with a larger
  `SBCL_SUSPEND_TIMEOUT`.
- **`ctl.sh start` says "Failed to start"** — check `sbcl-output.log`
  directly for the SBCL-level error (e.g. `sbcl-bridge.lisp` not found —
  check `SBCL_BRIDGE_LISP`).
- **`;;; ERROR: Don't know how to REQUIRE <some-contrib>` after a resume,
  but the identical code works on a fresh `start`** — confirm you resumed
  via `ctl.sh resume`, not by running the `.core` file directly; look for a
  resume-time `WARNING: no usable SBCL_HOME found` message; check whether
  an inherited `SBCL_HOME` in your environment points somewhere stale.
  Otherwise, load the failing library before suspending next time.
- **A resumed bridge shows `RUNNING` and looks healthy, but requests always
  time out (exit 2), and `sbcl-output.log` shows nothing beyond `SBCL-BRIDGE
  STARTED`** — classic symptom of the resumed bridge watching a different
  directory than the one you're submitting to. Check the `dir=` value on
  the `SBCL-BRIDGE STARTED` log line against your actual `SBCL_BRIDGE_DIR`
  — remember it must be set *before* the `resume` command, not just before
  the `eval`.
- **`(require "UIOP")` (or `ql:quickload`) fails even though
  `QUICKLISP_HOME` is set correctly** — check `sbcl-output.log` for a `;;;
  QUICKLISP: ...` line from the most recent start/resume; no line at all
  means `QUICKLISP_HOME` wasn't actually exported before `ctl.sh
  start`/`resume`.
- **Compiled systems keep rebuilding from source after a resume** — check
  for a `;;; ASDF: XDG_CACHE_HOME changed: ... -> ...` line around the most
  recent resume; if it's missing, double-check `XDG_CACHE_HOME` was
  exported before start/resume, or that ASDF was ever loaded in this image.
- **`asdf:find-system` can't find a project system after a resume, even
  though `CL_SOURCE_REGISTRY` looks right** — same shape as above, for
  `;;; ASDF: CL_SOURCE_REGISTRY changed: ...` instead.
- **A stray `sbcl` process left over from a previous test** —
  `ps aux | grep sbcl-bridge.lisp`, then `kill` it. Telltale symptom:
  requests are claimed and archived normally but *some* responses never
  appear in `sbcl-output.log` (two bridges racing for the same directory).
- **Logs growing without bound** — nothing has called `status` or
  `rotate-logs` recently.
- **A request seems to hang forever with no timeout firing** — check
  whether it was submitted with `SBCL_REQUEST_TIMEOUT=none`; use `ctl.sh
  interrupt` to cancel it directly.

## Quick reference

```bash
# Setup (once per shell)
export SBCL_BRIDGE_DIR=/path/to/bridge
export SBCL_BRIDGE_LISP=/path/to/sbcl-bridge.lisp
export QUICKLISP_HOME=/path/to/quicklisp        # optional
export XDG_CACHE_HOME=/path/to/cache            # optional
export CL_SOURCE_REGISTRY=/path/to/systems//    # optional

# Lifecycle
./sbcl-bridge-ctl.sh start
./sbcl-bridge-ctl.sh status
./sbcl-bridge-ctl.sh stop [--force]     # graceful (cancel, then in-Lisp exit) unless --force
./sbcl-bridge-ctl.sh restart            # stop + FRESH start (no saved state)
./sbcl-bridge-ctl.sh refresh            # stop + resume from cores/current.core

# Suspend / resume / named cores
./sbcl-bridge-ctl.sh suspend [core-path] [--name NAME]   # --name pins it (exempt from pruning)
./sbcl-bridge-ctl.sh resume  [core-path-or-name]
./sbcl-bridge-ctl.sh delete-core <name-or-path> [--force] # the only way to remove a pinned core

# Cancel whatever's running
./sbcl-bridge-ctl.sh interrupt [reqid]

# Logs (sbcl-output.log, sbcl-input.log, sbcl-async-errors.log -- the third
# records unhandled conditions from threads OTHER than the bridge's own main
# one, e.g. one a web server you started spawned)

./sbcl-bridge-ctl.sh logs [-f] [lines]
./sbcl-bridge-ctl.sh rotate-logs [--force]

# Submit work
./sbcl-client.sh eval '(+ 1 2 3)'
./sbcl-client.sh file path/to/code.lisp
echo '(+ 1 2)' | ./sbcl-client.sh -

# Verify the whole installation end to end
./sbcl-bridge-test.sh

# Per-request timeout
SBCL_REQUEST_TIMEOUT=5    ./sbcl-client.sh eval '(sleep 10)'   # -> status=timeout
SBCL_REQUEST_TIMEOUT=none ./sbcl-client.sh eval '(long-job)'   # no timeout

# Embedded headers in a submitted file are honored (id reused, timeout
# extends the client's wait budget)
printf ';;; REQID: setup\n;;; TIMEOUT: 120\n(load "setup.lisp")\n' > setup-req.lisp
./sbcl-client.sh file setup-req.lisp

# Request headers (equivalent, written by hand instead of via the client)
cat > next-sbcl-input.lisp << 'EOF'
;;; REQID: manual-1
;;; TIMEOUT: 10
(+ 1 2)
EOF
```

Client exit codes:

- **0** — ok
- **1** — evaluation error (`status=error`)
- **2** — submitted, but no response within `SBCL_TIMEOUT`
- **3** — bridge-side timeout (`SBCL_REQUEST_TIMEOUT`)
- **4** — cancelled (`ctl.sh interrupt`)
- **5** — fatal non-error condition
- **6** — usage / preflight error — never submitted, fix your setup
- **7** — couldn't submit within `SBCL_TIMEOUT` — bridge just busy, retry
