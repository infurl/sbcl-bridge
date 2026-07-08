# SBCL Bridge

A file-based request/response bridge for driving a headless SBCL (Steel Bank
Common Lisp) process from an external tool — typically a coding agent —
without the debugging-protocol chatter that Swank adds.

This document consolidates everything you need to understand, run, and operate
the system. It covers four files:

- `sbcl-bridge.lisp`
  - The Lisp code that runs *inside* the persistent SBCL process.

- `sbcl-bridge-ctl.sh`
  - Process manager: start/stop/restart/status/suspend/resume/etc.

- `sbcl-client.sh`
  - Client: submit code to a running bridge and wait for the result.

- `sbcl-bridge-test.sh`
  - End-to-end smoke test: spins up a throwaway bridge in a temp directory
	and exercises every major behavior in ~30 seconds. Run it after any SBCL
	upgrade or change to the bridge itself.

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

## 1. Why this exists

Swank (the protocol behind SLIME/SLY) is designed for interactive debugging
from an editor: it's stateful, bidirectional, and layers a lot of its own
messaging on top of whatever you actually wanted to evaluate. That's exactly
wrong for a tool harness, where something like a coding agent just wants to
say "run this code" and get back "here's what happened" — cleanly,
synchronously, and without needing to speak a debugger protocol.

SBCL Bridge instead uses the simplest mechanism that works reliably in a
container with no REPL, no TTY, and no systemd: **plain files**, with a
background loop watching a directory.

---

## 2. How it works (theory of operation)

### 2.1 The core idea

A single SBCL process runs forever, executing `sbcl-bridge:run-bridge` instead
of an interactive REPL. That function polls a directory for a specific
filename. When a caller wants code evaluated, it:

1. Writes the code to a temp file **in the same directory**.

2. Atomically hard-links the temp file to `next-sbcl-input.lisp` (`ln` on the
   same filesystem — the bridge never sees a half-written file, and, because
   `ln` *fails* if the target already exists, a request that's queued but not
   yet claimed is never overwritten; the client just waits for the slot).

The bridge loop notices the file, immediately renames it out of the way
(`next-sbcl-input.working`) so a new request can be queued right away, logs
the raw text, evaluates each top-level form in it, and prints the results —
bracketed by machine-parseable markers — to `*standard-output*`, which the
shell has redirected to `sbcl-output.log`. The client script watches that log
for its markers and echoes the result back once they appear.

There is no IPC, no sockets, no protocol library — just files, atomic renames,
and polling. This is deliberately unglamorous: it's easy to reason about, easy
to debug by eye (everything is a plain text file you can `cat`), and works
identically whether the agent driving it is local, remote, or itself running
inside another container.

### 2.2 Why polling instead of inotify

Polling (every 0.2s by default) is simpler, has no extra library dependency,
and is cheap enough that the overhead is irrelevant next to how long an actual
Lisp evaluation takes. `inotify` would shave milliseconds off best-case
latency at the cost of an extra dependency and more moving parts — not a good
trade for this use case.

### 2.3 Why `--non-interactive` doesn't cause the process to exit

Normally `sbcl --non-interactive` runs your `--load`/`--eval` forms and
exits. That's fine here, because `run-bridge` **never returns** under normal
operation — it's an infinite loop. There's no REPL reading from stdin that
could hit EOF and quit; the process only ever stops via `SIGTERM`/`SIGKILL`
(from `sbcl-bridge-ctl.sh stop`) or by explicitly calling `suspend-bridge`.

### 2.4 Directory layout

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
└── logs/                         # rotated, gzipped log generations
    ├── sbcl-output.log.<timestamp>.gz
    └── sbcl-input.log.<timestamp>.gz
```

### 2.5 The request format

A request is just Lisp source text, optionally preceded by header comment
lines:

```lisp
;;; REQID: my-unique-id
;;; TIMEOUT: 45
(defun square (x) (* x x))
(square 12)
```

- **`REQID`** correlates a request with its response. If omitted, the bridge
  synthesizes one (`auto-<universal-time>-<random>`). `sbcl-client.sh`
  supplies one (a nanosecond timestamp, its own PID, and a random component)
  — unless the submitted code already carries its own `REQID` header, in
  which case the client reuses it rather than shadowing it; an embedded
  `TIMEOUT` header likewise extends the client's wait budget (see §7,
  "Embedded headers"). The response and input
  log markers always echo the reqid exactly as submitted, but the archive
  *filename* in `processed/` is sanitized to alphanumerics plus `.`/`_`/`-`
  (other characters become `_`, leading dots are stripped, and the name is
  capped at 100 characters) — so a hand-written reqid containing `/`,
  pathname wildcards, or other junk can't break the archive rename or name a
  file outside `processed/`. Distinct raw ids that sanitize to the same name
  overwrite each other in the archive.

- **`TIMEOUT`** overrides the bridge's default per-request timeout (seconds),
  or disables it entirely with the literal value `none`. Note that any
  non-positive value (`0` or negative) also **disables** the timeout rather
  than timing out immediately, and an unparseable value silently falls back
  to the bridge default.

Because these are ordinary `;;; ...` Lisp comments, the reader ignores them
automatically — there's no preprocessing step that strips them before
evaluation, and a request with no headers at all is just as valid as one with
both.

Every top-level form in the request is read and evaluated **in sequence**, in
the order they appear — so `(defun ...)` followed by a call to that function
in the same request works exactly as you'd expect, as would an `(in-package
...)` form changing what package the rest of the request reads in.

**State persists across requests — that's the point.** The bridge is one
long-lived Lisp image, so *everything* a request does to the global
environment carries over to every later request: functions and variables you
define, systems you load, and — importantly — the values of global special
variables like `*package*`, `*readtable*`, `*read-default-float-format*`, and
`*print-*` settings. An `(in-package :my-app)` in one request means later
requests are read and evaluated in `MY-APP` too, until something changes it
back. This is deliberate: the whole design goal is a persistent, interactive
SBCL that a coding agent can treat like a REPL session, setting up a package
and working context once and then iterating in it. The flip side is that
requests are *not* isolated from each other — if you (or your agent) want a
predictable environment per request, either start each request with an
explicit `(in-package ...)`, or wrap state changes you don't want to leak in
a `let` that rebinds the relevant specials for just that request.

### 2.6 The response format

Every request produces a block in `sbcl-output.log` that looks like this:

```
;;; BEGIN-OUTPUT id=my-unique-id ts=3987654321
;;; => 144
;;; END-OUTPUT id=my-unique-id status=ok
```

- One `;;; => value1 ; value2 ; ...` line is printed per evaluated form,
  using `~S` (so it round-trips as Lisp), with multiple return values
  separated by `;`. A value whose *printing* signals (a broken
  `print-object` method, say) is rendered as `#<unprintable TYPE>` instead —
  the form evaluated successfully, so a presentation failure doesn't flip
  the request to `status=error`. (Printing that *loops* rather than signals
  — circular structure, since `*print-circle*` is off for round-trippable
  output — is bounded by the request timeout instead.)

- `status=` on the `END-OUTPUT` line is always one of:
  - `ok` Every form evaluated without incident.
  - `error` An `ERROR` condition was signalled (see §8.3).
  - `timeout` The request exceeded its timeout (see §8.1).
  - `cancelled` The request was interrupted via `ctl.sh interrupt` (see §8.2).
  - `fatal-condition` A non-`ERROR` `SERIOUS-CONDITION` occurred,
	e.g. `STORAGE-CONDITION` (heap/stack exhaustion) (see §8.3).

`error` and `fatal-condition` responses also include a bracketed backtrace
(see §8.3):

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
purely for audit/debugging purposes — it's never read back by any part of the
system:

```
;;; BEGIN-INPUT id=abc ts=123
(defun square (x) (* x x))
(square 12)
;;; END-INPUT id=abc
```

### 2.7 The claimed-request lifecycle

1. Client writes `next-sbcl-input.lisp` (atomically, by hard-linking a temp
   file into place — which fails, rather than overwriting, if a request is
   already queued; the client waits for the slot in that case).

2. Bridge notices it, immediately renames it to `next-sbcl-input.working` —
   this is what "clears the way" for the next request as soon as one is
   claimed, rather than only after it finishes.

3. Bridge logs the request, evaluates it, prints the response.

4. Bridge renames the working file to `processed/<reqid>.lisp` (with the
   reqid sanitized for filename safety, see §2.5). A request that suspends
   the bridge does this step itself: `suspend-bridge` archives its own
   working file under its reqid immediately before `save-lisp-and-die`,
   since the process exits before the bridge loop could.

If the process dies *unexpectedly* between steps 2 and 4 (a crash, a
`SIGKILL`, or a hand-rolled `save-lisp-and-die` called directly instead of
through `suspend-bridge`), the next `run-bridge` startup (a fresh `start`, or
a `resume`) finds the orphaned `next-sbcl-input.working` and archives it as
`processed/leftover-<timestamp>.lisp` rather than leaving it stuck — so a
crash never wedges the input slot shut. A normal suspend/resume cycle leaves
no leftover.

---

## 3. Installation & requirements

- **SBCL** with thread support (`:sb-thread` in `*features*` — true of
  essentially every mainstream Linux build). Without thread support,
  cancellation is disabled but everything else still works; the bridge prints
  a warning at startup in that case.

- **Bash**, `gzip`, standard coreutils (`ps`, `awk`, `sed`, `mktemp`, `wc`,
  `ls`). All ordinary on Debian/Ubuntu. GNU `date` is assumed but not
  required: the client uses `date +%s%N` for request ids, and on BSD/macOS
  `date` (where `%N` passes through as a literal `N`) the PID and `$RANDOM`
  components of the id keep it unique anyway.

- No systemd, no cron, no network daemon — everything here is designed to work
  unmodified inside a bare Docker container.

Put the files on disk together (or anywhere, as long as you either keep
`sbcl-bridge.lisp` alongside `sbcl-bridge-ctl.sh` or point `SBCL_BRIDGE_LISP`
at it), and make the shell scripts executable:

```bash
chmod +x sbcl-bridge-ctl.sh sbcl-client.sh sbcl-bridge-test.sh
```

To verify the installation (and re-verify after any SBCL upgrade), run the
smoke test — it needs no setup, uses a temp directory, and cleans up after
itself:

```bash
./sbcl-bridge-test.sh
# ...
# == 21 passed, 0 failed ==
```

---

## 4. Quick start

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

---

## 5. `sbcl-bridge.lisp` — the running process

You will not normally call anything in this file directly (that's what the two
shell scripts are for), but it's useful to know what's in it.

### Exported symbols

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
  terminates the process (see §8.4). Normally invoked *through* the bridge
  protocol (i.e. submitted as a request) by `ctl.sh suspend`, not called
  directly. Because `save-lisp-and-die` exits before the bridge loop can do
  its usual post-request archiving, `suspend-bridge` archives its own claimed
  request file (`next-sbcl-input.working` → `processed/<reqid>.lisp`) itself,
  right before saving — a normal suspend leaves no `leftover-*.lisp` behind
  on resume.

### Internal design notes worth knowing

- **Single-threaded evaluation, one watchdog thread.** All actual code
  evaluation happens on the bridge's main thread. A second "bridge-watchdog"
  thread runs alongside it purely to watch for the `cancel-request` control
  file and, when needed, asynchronously interrupt the main thread (see §8.2).

- **Bridge output is serialized by a recursive lock.** SBCL streams aren't
  thread-safe, and both the main thread and the watchdog write to
  `*standard-output*`, so every bridge-emitted line (markers, `;;; =>`
  values, condition reports, `CANCEL-REQUESTED`, ...) is written under one
  shared lock. The lock is *recursive* because a cancellation interrupt can
  land on the main thread while it already holds the lock mid-line; the
  unwinding handler then re-acquires it to print its `CANCELLED`/`END-OUTPUT`
  lines — a plain mutex would self-deadlock there. What *evaluated code*
  prints is deliberately not locked (the bridge can't wrap arbitrary user
  output), so a request's own prints can still theoretically interleave with
  a watchdog one-liner — but bridge lines can no longer garble each other.

- **`handler-bind`, not `handler-case`, around evaluation.** `handler-case`
  unwinds the stack *before* running its handler body — which would make
  backtrace capture useless. `handler-bind` runs its handler in the original
  signalling context, stack intact, which is what makes §8.3's backtraces
  meaningful.

- **A debugger-hook backstop, installed twice.** In `--non-interactive` mode,
  SBCL's own default behavior on a truly unhandled condition is already to
  print a backtrace and exit rather than hang — but the bridge installs its
  own hook so that if something ever escapes all of the handling described in
  §8.3 (which would be a bug), the log still records which request was active
  before the process exits. The same hook function is installed in *both*
  `cl:*debugger-hook*` and `sb-ext:*invoke-debugger-hook*`:
  `--non-interactive`/`--disable-debugger` places SBCL's own print-and-exit
  handler in the latter, and the precise consultation order between the two
  hooks is an implementation detail that has shifted across SBCL versions —
  setting both means the reqid-logging backstop runs regardless of which one
  a given SBCL consults first.

---

## 6. `sbcl-bridge-ctl.sh` — process management

No systemd required. Uses a PID file and plain `kill`, works identically
inside a container.

### Commands

- `start`
  - Cold-starts a fresh SBCL process running `run-bridge`. No-op (with a
	message) if already running. SBCL is always started with `--no-sysinit
	--no-userinit`: the bridge must behave identically in a bare container
	and on a developer desktop, and a stray `/etc/sbclrc` or `~/.sbclrc`
	that loads Quicklisp, changes `*print-*` settings, or merely prints
	something would make evaluation results environment-dependent (and
	could corrupt the marker protocol). Anything an init file would have
	provided can be loaded explicitly as an ordinary first request instead
	— which also means it's captured in the input log and, unlike an init
	file, becomes image state that survives suspend/resume. (`resume`
	never processes init files either: the saved image's custom toplevel
	bypasses the startup sequence that would read them, and the version
	probe used for core-compatibility checks runs with the same flags.)

- `stop`
  - Sends `SIGTERM`, waits up to `SBCL_STOP_TIMEOUT`, escalates to `SIGKILL`
	if needed.

- `restart`
  - `stop` then `start`.

- `status`
  - Reports running/stopped, PID, uptime, RSS/VSZ memory, saved core images,
	log sizes, and the number of archived request files. The RUNNING check
	verifies (via `/proc/<pid>/cmdline`, where available) that the recorded
	PID actually belongs to an sbcl process or a `*.core` image, so a PID
	recycled by an unrelated process after a crash reads as STOPPED instead
	of RUNNING — and can't be `SIGTERM`ed by `stop`. Also triggers cheap
	housekeeping: a size-based log-rotation check (see §8.5) and pruning of
	`processed/` down to `SBCL_PROCESSED_RETAIN` files, so anything that
	polls `status` keeps both bounded for free.

- `suspend [core-path]`
  - Saves an executable core image and stops the process (see §8.4). Defaults
	to `cores/bridge-<timestamp>.core`.

- `resume [core-path]`
  - Resumes from a saved core image. Defaults to the most recent one in
	`cores/`.

- `interrupt [reqid]`
  - Cancels whatever request is currently running, or a specific one by id
	(see §8.2).

- `logs [-f] [lines]`
  - Prints the last N lines (default 50) of `sbcl-output.log` for this
	`SBCL_BRIDGE_DIR`, or follows it live with `-f` (like `tail -f`). Purely
	a convenience so you don't have to compose the log path by hand.

- `rotate-logs [--force]`
  - Rotates logs now. Without `--force`, only rotates logs that have actually
	exceeded `SBCL_LOG_MAX_BYTES`, and never while a request is queued or in
	flight (so a waiting client can't have the log truncated out from under
	it — see §8.5). `--force` rotates regardless of size *and* busyness, with
	a warning if a request is in flight.

### Environment variables

- `SBCL_BRIDGE_DIR` — default `.`
  - Directory the bridge monitors.

- `SBCL_BRIDGE_LISP` — default: alongside this script
  - Path to `sbcl-bridge.lisp`.

- `SBCL_BIN` — default `sbcl`
  - The SBCL executable to run.

- `SBCL_CORE_RETAIN` — default `3`
  - Number of suspended core images to keep; oldest are pruned after a
	successful new suspend. Pruning also removes orphaned `.version`
	sidecars (a sidecar is written just *before* `save-lisp-and-die`, so a
	failed save can leave one behind with no matching core).

- `SBCL_PROCESSED_RETAIN` — default `200`
  - Number of archived request files (`processed/*.lisp`, including
	`error-*` and `leftover-*`) to keep; the oldest beyond that are pruned
	on every `status` call. Nothing bridge-side ever deletes archives, so
	without this an agent hammering the bridge would accumulate them without
	bound.

- `SBCL_STOP_TIMEOUT` — default `10`
  - Seconds to wait for graceful exit before `SIGKILL` on `stop`.

- `SBCL_SUSPEND_TIMEOUT` — default `60`
  - Seconds to wait for `suspend` to finish saving and exiting.

- `SBCL_LOG_MAX_BYTES` — default `10485760` (10 MiB)
  - A log is rotated once it exceeds this size.

- `SBCL_LOG_RETAIN` — default `5`
  - Number of rotated, gzipped log generations to keep (per log file).

- `SBCL_MEM_WARN_MB` — default: unset
  - If set, `status` prints a warning when RSS exceeds this many MB.

---

## 7. `sbcl-client.sh` — submitting work

```bash
sbcl-client.sh eval '<lisp forms...>'
sbcl-client.sh file <path-to-lisp-file>     # shortcut: submit an existing file
sbcl-client.sh -                            # read code from stdin
```

The client:

1. Scans the leading `;;; KEY: value` header comments of the submitted code
   (any mode — `file`, `eval`, or stdin) with the same parser rules the
   bridge uses, and honors what it finds: an embedded `;;; REQID:` is
   **reused** as the request id rather than shadowed by a generated one, and
   an embedded `;;; TIMEOUT:` feeds into the client's own wait budget (step
   below). If the code carries no `REQID`, the client generates a unique one
   (nanosecond timestamp + its own PID + a random component; on non-GNU
   `date` without `%N` support, the latter two still keep ids unique).

2. Writes the code to a temp file — prepending a `REQID` header only when it
   generated one, and a `TIMEOUT` header only when `SBCL_REQUEST_TIMEOUT` is
   set — then atomically hard-links it into place. `ln` fails if
   `next-sbcl-input.lisp` already exists, so a request that's queued but not
   yet claimed by the bridge is never overwritten — if the slot is busy, the
   client polls until the bridge claims the queued request (within the
   overall `SBCL_TIMEOUT` budget), so sequential callers queue up safely
   instead of clobbering each other.

3. Records the current byte size of `sbcl-output.log` so it only ever scans
   *new* content — cheap even in a long-lived session with a huge log. If the
   log is rotated (truncated) while the client is waiting, it detects that
   the file shrank below its remembered offset and rescans from the top
   rather than waiting forever past EOF.

4. Polls until it sees the matching `END-OUTPUT` marker, then prints
   everything between `BEGIN-OUTPUT` and `END-OUTPUT` and exits with a
   status-appropriate code. The markers are matched *through* the delimiter
   that follows the id (`id=<reqid> `), so a reqid that happens to be a
   strict prefix of another reqid can never match the wrong request's block.

### Embedded headers: self-describing request files

A request file can carry its own headers, and submitting it through the
client Just Works — this is the idiomatic way to package a setup script that
knows its own identity and how long it's allowed to take:

```lisp
;;; REQID: quicklisp-loader
;;; TIMEOUT: 45

(in-package #:cl-user)
(load #P"/usr/share/common-lisp/source/quicklisp/quicklisp.lisp")
(ql:quickload "alexandria")
;; ...
```

```bash
./sbcl-client.sh file quicklisp-loader.lisp
# ...
# ;;; END-OUTPUT id=quicklisp-loader status=ok
```

The response markers and the `processed/` archive carry `quicklisp-loader`,
and the client waits up to 50 seconds (45 + 5) rather than abandoning the
request at its default 30 — previously the bridge would honor the embedded
`TIMEOUT` while the client, unaware of it, gave up first with exit 2.

Precedence for the evaluation timeout, highest first:
`SBCL_REQUEST_TIMEOUT` (env) → embedded `;;; TIMEOUT:` header → the bridge's
default. (The env value wins mechanically: the client prepends it ahead of
the code, and the bridge honors the first `TIMEOUT` header it sees.)
`SBCL_TIMEOUT`, when set, still overrides the client's *wait budget*
unconditionally.

One caveat with a fixed, reused `REQID`: response correlation is unaffected
(the client only scans log output appended after its own submission), but
each run's `processed/` archive overwrites the previous one, and log entries
from different runs share the same id — fine for setup scripts, less ideal
for requests you want to tell apart later.

### Environment variables

- `SBCL_BRIDGE_DIR` — default `.`
  - Directory the bridge monitors.

- `SBCL_POLL_INTERVAL` — default `0.2`
  - Seconds between checks of the output log.

- `SBCL_TIMEOUT` — default larger of `30` or the effective evaluation
  timeout + 5 (from `SBCL_REQUEST_TIMEOUT` or an embedded `TIMEOUT` header)
  - Total seconds *this script* waits before giving up — the budget covers
	both queueing the request (if the input slot is busy) and receiving the
	response. Setting it to the empty string is the same as leaving it unset.

- `SBCL_REQUEST_TIMEOUT` — default unset, use bridge default
  - Seconds the *bridge* allows the evaluation itself to run. `none` disables
	it for this request.

### Exit codes

- **0** — `status=ok`

- **1** — `status=error`
  - An `ERROR` condition was signalled.

- **2** — client-side wait timeout
  - The client gave up within `SBCL_TIMEOUT` — either the input slot never
	freed up (another request stayed queued), or no response arrived.

- **3** — `status=timeout`
  - The bridge-side per-request timeout expired.

- **4** — `status=cancelled`
  - Cancelled via `ctl.sh interrupt`.

- **5** — `status=fatal-condition`
  - A non-`ERROR` `SERIOUS-CONDITION` occurred.

Note the distinction between exit code 2 (this *script* gave up waiting) and
exit code 3 (the *bridge* gave up evaluating). If you set
`SBCL_REQUEST_TIMEOUT` without also raising `SBCL_TIMEOUT`, the client
auto-adjusts its own wait to `SBCL_REQUEST_TIMEOUT + 5` so it doesn't give up
on exit code 2 right as the bridge's own timeout is about to report properly
on exit code 3.

---

## 8. Feature deep dives

### 8.1 Timeouts

Every request runs under `sb-ext:with-timeout`, bounding the *entire* request
(all forms in it), not each form individually. Default: 30 seconds. Override
per request:

```bash
SBCL_REQUEST_TIMEOUT=5 ./sbcl-client.sh eval '(sleep 10)'
# ;;; TIMEOUT after 5 seconds
# ;;; END-OUTPUT id=... status=timeout      (client exit code 3)

SBCL_REQUEST_TIMEOUT=none ./sbcl-client.sh eval '(long-running-computation)'
```

A timeout cleanly unwinds the request and returns control to the main loop —
the bridge itself is completely unaffected and ready for the next request
immediately.

Two edge cases in how the `TIMEOUT` header is interpreted, worth knowing:
a value of `0` (or anything negative) **disables** the timeout, exactly like
`none` — it does not time out immediately. And an unparseable value (e.g.
`TIMEOUT: soon`) silently falls back to the bridge's default rather than
erroring. Non-integer numbers are truncated (`30.9` → `30`).

### 8.2 Cancellation

Sometimes you don't want to wait for a timeout — you know right now that a
request should stop. `ctl.sh interrupt` handles this:

```bash
# in one terminal/process:
SBCL_REQUEST_TIMEOUT=none ./sbcl-client.sh eval '(sleep 60)'
# ... blocks ...

# in another:
./sbcl-bridge-ctl.sh interrupt
# Cancellation requested for whatever request is currently running.
```

The first command returns almost immediately with `status=cancelled` (client
exit code 4) instead of waiting the full 60 seconds.

**How it works:** a background "bridge-watchdog" thread (started alongside the
main loop) polls for a small control file (`cancel-request`). When it appears,
the watchdog checks whether its target (blank = "whatever's current", or a
specific reqid) matches the request currently being evaluated, and if so,
calls `sb-thread:interrupt-thread` on the main thread with a closure that
signals a `request-cancelled` condition right there in the main thread's
execution context. The `handler-bind` in `eval-and-report` catches it and
reports `status=cancelled`.

The injected closure re-checks, *on the main thread at the moment the
interrupt is actually delivered*, that the same request is still being
evaluated (`*evaluating-request*` is bound and the current reqid still
matches). Without that guard, a cancellation racing with request completion
could deliver `request-cancelled` after `eval-and-report`'s handlers are gone
— e.g. between the `END-OUTPUT` line and the request bookkeeping, or during
the archive rename — where it would land in the main loop's `LOOP-ERROR`
backstop and spuriously archive a perfectly successful request as an error.
With the guard, a too-late cancellation is simply a no-op.

`ctl.sh interrupt [reqid]` — omit `reqid` to cancel whatever's currently
running; supply one to only cancel if it matches (useful if you're not sure
whether your request has already finished and you don't want to accidentally
cancel someone else's).

**Limitation:** this relies on SBCL delivering the interrupt at a "safepoint,"
which ordinary Lisp execution provides constantly (every function call, loop
iteration, etc.). A request stuck entirely inside a blocking foreign/C call
(e.g. certain `sb-alien` FFI calls) would not be interruptible this way — not
a concern for typical Lisp-level agent work, but worth knowing the boundary.

### 8.3 Condition handling & backtraces

**Why this matters:** a coding agent will, by the nature of what it's doing,
frequently submit code that doesn't work. The bridge needs to survive that
indefinitely, and the error report needs to be useful enough for the agent to
fix its own mistake without another round trip.

Three layers of protection:

1. **Comprehensive condition catching.** Beyond ordinary `ERROR` conditions,
   `STORAGE-CONDITION` (heap/stack exhaustion — notably *not* a subtype of
   `ERROR` in ANSI Common Lisp) and any other `SERIOUS-CONDITION` are also
   caught per-request, so a single catastrophic request — including a real
   stack overflow from unbounded recursion — can't silently take the whole
   process down. Confirmed by deliberately blowing the control stack in
   testing: caught cleanly, reported as `status=fatal-condition`, bridge still
   serving requests immediately after.

2. **Backtrace capture.** Every `error`/`storage-condition`/
   `serious-condition` report includes a backtrace, bracketed by
   `BACKTRACE-BEGIN id=... ` / `BACKTRACE-END id=...`, truncated to
   `*bridge-backtrace-frames*` (default 20). The backtrace is captured via
   `handler-bind` *before* the stack unwinds — using `handler-case` instead
   would have already discarded the very frames you'd want to see.

   The backtrace is also **filtered**: it stops as soon as it reaches the
   bridge's own internal machinery (the frames for `run-forms`,
   `eval-and-report`, and everything below them are never useful to someone
   debugging their own submitted code), rather than showing 14 frames of the
   bridge's polling loop down to `%START-LISP`. If the (unexported, and thus
   not permanently guaranteed-stable) SBCL internals this filtering relies on
   are ever unavailable, it falls back automatically to an unfiltered
   `sb-debug:print-backtrace`.

3. **`*debugger-hook*` backstop.** If something somehow still escapes all of
   the above (which would indicate a real gap), the hook logs the active
   request id and a note before the process exits, rather than the process
   hanging in a debugger prompt with no terminal attached to answer it.

Example:

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

### 8.4 Suspend & resume

The bridge can save its entire in-memory state — every function you've
defined, every global variable, loaded packages, all of it — to disk, and pick
up again later exactly where it left off (in terms of state; not literally
mid-computation, see below).

```bash
./sbcl-bridge-ctl.sh suspend
# Suspended. Core image saved: cores/bridge-20260706-032300.core

./sbcl-bridge-ctl.sh resume
# Resuming from cores/bridge-20260706-032300.core ...
# Resumed (pid 2701).
```

**How it works:** `sb-ext:save-lisp-and-die` snapshots the entire heap and
then terminates the process. Crucially, it does *not* resume execution from
wherever you called it — on reload, execution always restarts from a
designated top-level entry point. `suspend-bridge` takes advantage of this by
pointing that entry point (`:toplevel`) at `resume-bridge`, a small wrapper
that just calls `run-bridge` again using the
directory/poll-interval/timeout/backtrace-frames settings that were cached in
global variables when the bridge started — so resuming re-enters the exact
same polling loop, watching the same directory, with no `--load`/`--eval`
flags needed. The saved image is a fully self-contained executable
(`:executable t :save-runtime-options t`) — resuming it is just running the
file.

**Practical mechanics worth knowing:**

- `suspend` is itself submitted through the normal request pipeline (it writes
  a request whose sole content is `(sbcl-bridge:suspend-bridge :core-path
  "...")`), so it naturally queues behind anything already in flight rather
  than interrupting it. The request is submitted with the same atomic
  hard-link technique the client uses, so `ctl.sh suspend` fails cleanly —
  with no race window — if another request is already queued in
  `next-sbcl-input.lisp`. The suspend request also carries `;;; TIMEOUT:
  none`, since a full GC plus writing a large heap to disk can legitimately
  take longer than the bridge's default per-request timeout;
  `SBCL_SUSPEND_TIMEOUT` (below) is the only limit that applies.

- **A timed-out `suspend` is withdrawn, not left armed.** If the process
  hasn't exited within `SBCL_SUSPEND_TIMEOUT` (typically because a
  long-running request is still in flight ahead of the suspend), `ctl.sh
  suspend` reports failure *and removes the suspend request if it's still
  queued* — otherwise the bridge would save-and-exit by surprise whenever the
  in-flight request eventually finished, long after the command reported
  failure. If the bridge has already claimed the suspend request by then,
  `ctl.sh` says so instead: the suspend may still complete shortly, so check
  `status` before assuming the bridge stayed up.

- `save-lisp-and-die` refuses to run while other threads are alive.
  `suspend-bridge` stops the watchdog thread first automatically; you don't
  need to do anything about this yourself.

- **Version metadata.** A sidecar file (`<core-path>.version`) records
  `(lisp-implementation-version)`, `(machine-type)`, and
  `(sb-int:sbcl-homedir-pathname)` at save time. `ctl.sh resume` compares the
  version/machine-type against the currently configured `$SBCL_BIN` and prints
  a warning (not a hard failure — the image is self-contained and executable,
  so a mismatch is often survivable) if they differ. If the sidecar is missing
  entirely, it warns that it can't verify compatibility at all.

- **Contrib modules and `SBCL_HOME`.** This is the one genuinely surprising
  gotcha in the whole system, so it's worth understanding even though the
  tooling now handles it automatically. A resumed executable image has **no
  idea where SBCL's contrib modules live on disk** —
  `(sb-int:sbcl-homedir-pathname)` comes back `NIL` in a resumed image,
  because that value is normally derived from the location of the *running
  sbcl binary itself*, and a saved image is just a data blob that can be
  executed from anywhere (typically this bridge's own `cores/` directory,
  nowhere near the real SBCL install). Anything that calls `cl:require` for a
  contrib (`sb-posix`, `uiop`, `asdf`, `sb-bsd-sockets`, etc. — and note
  that many Quicklisp systems pull these in transitively, e.g. `cl-postgres`
  needs `sb-rotate-byte`) that wasn't already loaded *before* the suspend will
  fail with `Don't know how to REQUIRE ...` after a resume, even though the
  exact same code works perfectly on a fresh `start`.

  `write-version-sidecar` records the home directory in effect at save time
  (normalized via `truename`, and falling back to the `SBCL_HOME` this
  process was itself resumed with, so the record survives chains of
  suspend/resume cycles), and `ctl.sh resume` restores a home into the
  `SBCL_HOME` environment variable before launching. Crucially, the recorded
  value is **not trusted blindly**: the machine that suspended the core may
  not be the machine resuming it. The canonical case is a shared-workspace
  workflow — suspend on the host, resume the identical core inside a
  container (or vice versa) — where the two sides' `sbcl` binaries live at
  different prefixes (`/usr/local` build on one side, the distro package
  under `/usr` on the other), so the recorded `<prefix>/lib/sbcl/` simply
  doesn't exist on the resuming side; or it exists but holds contrib fasls
  built by a different SBCL version, which the resumed image can't load.
  `resume` therefore *validates* every candidate (the directory must exist
  and contain `contrib/`) and picks by provenance: if the local `sbcl`'s
  build matches the image's, the **local installation's** home is preferred
  (its fasls are guaranteed compatible, wherever it lives), with the sidecar
  as fallback; if the builds differ, the **sidecar's** home is preferred
  (the only place with matching-version fasls, if it still exists), with the
  local home as a warned-about last resort. A caller-provided `SBCL_HOME`
  always wins but is sanity-checked, and if nothing validates, `resume`
  says so loudly instead of exporting a dead path.

  The more robust practice, when it's an option: load (via `ql:quickload` or
  plain `require`) everything your workload needs *before* suspending. Once
  a contrib is loaded into the image, its code is baked into the heap and
  never needs to be found on disk again after a resume — this is why
  suspending only after your environment is fully set up (rather than right
  after a bare `start`) is the better habit to build.

- **Core retention.** `ctl.sh suspend` prunes down to `SBCL_CORE_RETAIN`
  (default 3) most recent images — but only *after* confirming the new one
  saved successfully, so a failed suspend never costs you your last good
  image. Pruning also sweeps up orphaned `.version` sidecars: the sidecar is
  written just *before* `save-lisp-and-die`, so a save that fails partway
  (e.g. because a user-spawned thread was still alive) leaves a
  `foo.core.version` with no `foo.core`, which would otherwise linger
  forever.

- **No leftovers from a normal suspend.** Because `save-lisp-and-die` exits
  the process, the bridge loop never gets to archive the suspend request's
  own claimed file the usual way. `suspend-bridge` therefore archives its own
  `next-sbcl-input.working` under its reqid (`processed/<reqid>.lisp`)
  immediately before saving — so a suspend/resume cycle driven by `ctl.sh
  suspend` (or any request that calls `suspend-bridge`) leaves nothing behind
  for the resumed bridge to sweep up. This is done as the very last step
  before the save: if anything earlier in `suspend-bridge` fails, the request
  errors out through the normal path with its working file still in place,
  and the loop's usual archive rename (which now checks the file still
  exists) handles it.

- **Crash resilience.** If the process dies *without* going through
  `suspend-bridge` — a crash, a `SIGKILL` mid-request, or a hand-rolled
  `save-lisp-and-die` called directly — the bridge finds the stale
  `next-sbcl-input.working` at the next startup and archives it to
  `processed/leftover-<timestamp>.lisp` automatically rather than blocking
  future requests.

### 8.5 Log rotation

`sbcl-output.log` and `sbcl-input.log` are append-only and will grow forever
unless rotated.

```bash
./sbcl-bridge-ctl.sh rotate-logs            # rotate only if over SBCL_LOG_MAX_BYTES
./sbcl-bridge-ctl.sh rotate-logs --force    # rotate regardless of current size
```

You generally don't need to call this yourself: `ctl.sh status` performs the
same size check every time it runs, so anything that polls status periodically
(an agent's own health-check loop, a Docker `HEALTHCHECK`, etc.) keeps both
logs bounded for free with no extra cron/timer infrastructure.

**How it works — and why it has to work this way:** the bridge process holds
`sbcl-output.log` open for its *entire* lifetime via shell redirection (`>>
sbcl-output.log`). If you simply `mv` that file aside, the running process's
file descriptor keeps writing into the same underlying inode — now sitting
under the renamed name — forever; a fresh `sbcl-output.log` you create
afterward would just sit empty. This is the standard "copytruncate" problem,
and the standard workaround: copy the current contents aside (gzipped, into
`logs/`), then truncate the *original* file in place (`: > sbcl-output.log`).
The running process's descriptor still points at that same inode, so its next
write lands cleanly in what is now an empty file. Verified directly: submitted
a request, rotated, submitted another — the second response landed in the
freshly truncated live log, not the rotated copy.

**Rotation is skipped while a request is queued or in flight** (i.e. whenever
`next-sbcl-input.lisp` or `next-sbcl-input.working` exists). Truncating the
live log at that moment would strand a waiting `sbcl-client.sh`: the client
remembers the byte offset it started scanning from, and a response written
before the rotation would be carried off into the archive where the client
never looks. The size check simply fires again on the next `status` call once
the bridge is idle, so nothing is lost by deferring. `rotate-logs --force`
overrides this (it's meant for maintenance windows and must also work if a
stale `.working` file is lying around), printing a warning if a request is in
flight.

As a second line of defense, the client itself detects truncation: if
`sbcl-output.log` is ever smaller than the offset the client recorded at
submission time, it rescans from the top of the (now-truncated) file instead
of tailing past EOF forever. That recovers responses written *after* a forced
mid-flight rotation; a response already written *before* it is in the archive
and out of reach, which is why the skip-while-busy rule above is the primary
protection.

The one accepted caveat (shared with real `logrotate` in copytruncate mode): a
write landing in the small window between the `cp` and the truncate can be
lost. Given these logs are mostly idle between discrete request/response
cycles — and rotation now doesn't run at all mid-request unless forced — this
window is vanishingly small in practice.

`sbcl-input.log` doesn't strictly need copytruncate (the bridge reopens it
fresh via `with-open-file` on every single write, rather than holding it
open), but it's rotated the same way for consistency.

Rotated generations are kept separately per log file (`SBCL_LOG_RETAIN`,
default 5 each), gzip-compressed, named `logs/<original-name>.<timestamp>.gz`.

### 8.6 Memory reporting

```bash
./sbcl-bridge-ctl.sh status
# RUNNING (pid=2771, uptime=00:12:34)
# Memory: RSS=142MB VSZ=1312MB
# Saved core images (newest first): ...
# Logs: sbcl-output.log=48KB sbcl-input.log=12KB
# Processed archive: 37 request file(s) (retention: 200)
```

Set `SBCL_MEM_WARN_MB` to have `status` print a warning (to stderr) whenever
RSS exceeds that threshold — enough to notice a slow memory leak over a
long-running agent session before it becomes an out-of-memory problem for the
container.

---

## 9. Known limitations & caveats

Worth internalizing before you rely on this in production:

- **Single request in flight at a time**, by design. The client blocks until
  it sees its response. Submission is arbitrated by an atomic hard-link
  (`ln` fails if `next-sbcl-input.lisp` already exists), so concurrent
  callers can no longer clobber each other's queued requests — a caller that
  finds the slot busy simply polls until it frees up, within its
  `SBCL_TIMEOUT` budget. There's still no fairness guarantee between many
  simultaneous waiters (whichever `ln` wins the race goes next), and
  evaluation itself remains strictly one request at a time.

- **No sandboxing.** Submitted code runs with the full privileges of the SBCL
  process — filesystem, network, `sb-ext:run-program`, all of it. Presumably
  intentional for a coding-agent tool, but if you want a safety margin, add it
  at the Docker layer (unprivileged user, cgroup memory/CPU limits, restricted
  network namespace) rather than in the bridge itself.

- **No isolation between requests, by design.** Global state — packages,
  `*package*` and other special variables, definitions, loaded systems —
  persists across requests (§2.5). That's the feature; the caveat is that a
  request can leave the environment in a state a later request doesn't
  expect.

- **Response markers can be spoofed by the code being evaluated.** The
  protocol is plain text on a shared log: evaluated code that prints a line
  like `;;; END-OUTPUT id=<its own id> status=ok` will terminate the waiting
  client's scan early with a forged status (and its remaining real output,
  including the true status line, will be ignored). This can't be fully
  closed with a client-side secret, because the evaluated code can recover
  its own reqid from `sbcl-input.log` or its claimed request file on disk.
  Treat evaluated code as trusted — which it inherently is anyway given the
  no-sandboxing point above. If an agent evaluates content derived from
  untrusted input (a prompt-injection surface), validate results
  independently rather than trusting the reported `status=` alone.

- **Cancellation needs a safepoint.** Code stuck inside a blocking foreign
  call won't respond to `interrupt` (see §8.2).

- **Backtrace filtering uses unexported SBCL internals**
  (`sb-debug::map-backtrace`, `sb-debug::print-frame-call`). They work on the
  SBCL version this was built and tested against, but aren't part of SBCL's
  stable public API. There's an automatic fallback to the unfiltered public
  API if they ever go away — run `./sbcl-bridge-test.sh` after any SBCL
  upgrade to verify this (and everything else) in one go.

- **Copytruncate race window** (§8.5): a write landing in the instant between
  copy and truncate can theoretically be lost. Rotation is skipped entirely
  while a request is queued or in flight (and the client detects truncation
  and rescans), so in practice this now only applies to `rotate-logs --force`
  issued mid-request — which warns about exactly this.

- **Version-compatibility check on resume is advisory, not a guarantee.** It
  compares `(lisp-implementation-version)` and `(machine-type)`; a warning
  means "you should look into this before trusting the result," not "this
  definitely won't work" — and conversely, a match doesn't guarantee every
  possible edge case is fine either.

- **Contrib modules loaded for the first time only after a resume** can still
  fail if you're loading the saved core directly (via `sbcl --core ...` or by
  executing the image) rather than through `ctl.sh resume` — the validated
  `SBCL_HOME` restoration lives in the shell script, not the core image
  itself — or if *neither* the sidecar's recorded home *nor* the local sbcl
  installation's home is usable on the resuming machine (resume warns loudly
  in that case). When in doubt, load everything your workload needs in a
  fresh image before suspending (see §8.4).

- **No log rotation or archive pruning without something calling `status`.**
  If nothing ever polls `status` and you never explicitly call `rotate-logs`,
  the logs will grow unbounded — and the same goes for the `processed/`
  archive, which is pruned to `SBCL_PROCESSED_RETAIN` files by the same
  `status`-driven housekeeping. Any reasonably active agent loop calling
  `status` periodically for health-checking purposes handles both
  incidentally, but a completely dormant bridge with nobody checking on it
  will not clean up after itself.

- **PID-file identity check is a heuristic.** `status`/`stop` verify the
  recorded PID looks like the bridge (command line matching `sbcl` or
  `*.core`), which defeats ordinary PID recycling, but it can't positively
  prove the process is *this* bridge — an unrelated sbcl process that
  happened to recycle the PID would still pass. If you resume from a custom
  core path, keep the `.core` suffix so the check recognizes it; on systems
  without `/proc`, the check degrades to a bare `kill -0`.

---

## 10. Troubleshooting

- **`sbcl-client.sh` exits 2 ("timed out ...")**
  - Either the bridge isn't running (`ctl.sh status`), the request is still
	genuinely executing, or the input slot never freed up because an earlier
	request stayed queued the whole time (the error message says which) —
	raise `SBCL_TIMEOUT`, or check whether something needs `ctl.sh interrupt`.

- **`ctl.sh suspend` reports "did not complete ... withdrawn"**
  - A long-running request was in flight and the suspend request was still
	waiting behind it when `SBCL_SUSPEND_TIMEOUT` expired. The queued suspend
	has been removed, so the bridge will *not* suspend later by surprise; wait
	for (or `interrupt`) the in-flight request and run `suspend` again,
	possibly with a larger `SBCL_SUSPEND_TIMEOUT`.

- **`ctl.sh start` says "Failed to start"**
  - Check `sbcl-output.log` directly for the SBCL-level error (e.g.
	`sbcl-bridge.lisp` not found — check `SBCL_BRIDGE_LISP`).

- **`ctl.sh suspend` fails with a "multiple threads" error in the log**
  - Should not happen — `suspend-bridge` stops the watchdog thread first
	automatically. If you see this, something loaded extra threads into the
	image before suspending; check what else your submitted code may have
	spawned.

- **`ctl.sh resume` prints a version-mismatch warning**
  - Informational; the image is self-contained and often still works.  If it
	then actually fails, you'll need to `start` fresh instead (state from that
	particular suspend point is lost, but everything from before that suspend
	point that made it into an earlier still-good core is not).

- **`;;; ERROR: Don't know how to REQUIRE <some-contrib>` after a resume, but
  the identical code works on a fresh `start`**
  - Handled automatically by resume's validated `SBCL_HOME` restoration — see
	§8.4 — including the shared-workspace case where the core was suspended
	on a *different machine* (host vs. container) whose sbcl lives at a
	different prefix: `resume` detects that the sidecar's recorded path is
	unusable here and restores the local installation's home instead. If
	you're still seeing it: (1) confirm you resumed via `ctl.sh resume`, not
	by running the `.core` file directly or via `sbcl --core ...` by hand —
	the restoration lives in the shell script; (2) look for the resume-time
	`WARNING: no usable SBCL_HOME found` message, which means neither the
	sidecar's path nor the local sbcl's home exists here with a `contrib/`
	inside it; (3) check whether an inherited `SBCL_HOME` in your environment
	is pointing somewhere stale — a caller-provided value is respected even
	when it's wrong (with a warning). Otherwise, load the failing library
	before suspending next time.

- **A stray `sbcl` process left over from a previous test**
  - `ps aux | grep sbcl-bridge.lisp`, then `kill` it — `ctl.sh stop` only
	knows about the PID recorded in `.sbcl-bridge.pid` for *its*
	`SBCL_BRIDGE_DIR`; a leftover process pointed at the same directory from
	an earlier, differently-invoked session can race with a newly started
	one. The telltale symptom: requests are claimed and archived normally but
	*some* responses never appear in `sbcl-output.log` (roughly alternating,
	since the two loops take turns winning the claim) — the losing bridge is
	writing its responses to whatever its own stdout points at, which, if the
	directory was deleted and recreated under it, is a deleted inode. This is
	especially easy to trigger by `rm -rf`-ing and recreating a bridge
	directory without stopping its bridge first.

- **Logs growing without bound**
  - Nothing has called `status` or `rotate-logs` recently — see §9's last
	point.

- **A request seems to hang forever with no timeout firing**
  - Check whether it was submitted with `SBCL_REQUEST_TIMEOUT=none`; use
	`ctl.sh interrupt` to cancel it directly.

---

## 11. Quick reference

```bash
# Setup (once per shell)
export SBCL_BRIDGE_DIR=/path/to/bridge
export SBCL_BRIDGE_LISP=/path/to/sbcl-bridge.lisp

# Lifecycle
./sbcl-bridge-ctl.sh start
./sbcl-bridge-ctl.sh status
./sbcl-bridge-ctl.sh stop
./sbcl-bridge-ctl.sh restart

# Suspend / resume
./sbcl-bridge-ctl.sh suspend [core-path]
./sbcl-bridge-ctl.sh resume  [core-path]

# Cancel whatever's running
./sbcl-bridge-ctl.sh interrupt [reqid]

# Logs
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
- **1** — evaluation error
- **2** — client gave up waiting, to submit or for a response (`SBCL_TIMEOUT`)
- **3** — bridge-side timeout (`SBCL_REQUEST_TIMEOUT`)
- **4** — cancelled (`ctl.sh interrupt`)
- **5** — fatal non-error condition
