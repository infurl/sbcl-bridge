# SBCL Bridge

A file-based request/response bridge for driving a headless SBCL (Steel Bank
Common Lisp) process from an external tool — typically a coding agent —
without the debugging-protocol chatter that Swank adds.

This document consolidates everything you need to understand, run, and operate
the system. It covers three files:

| File                    | Role                                                              |
|--------------------------|-------------------------------------------------------------------|
| `sbcl-bridge.lisp`       | The Lisp code that runs *inside* the persistent SBCL process.     |
| `sbcl-bridge-ctl.sh`     | Process manager: start/stop/restart/status/suspend/resume/etc.    |
| `sbcl-client.sh`         | Client: submit code to a running bridge and wait for the result.  |

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

2. Atomically renames the temp file to `next-sbcl-input.lisp` (an atomic `mv`
   on the same filesystem — the bridge never sees a half-written file).

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
├── next-sbcl-input.lisp      # dropped by a client; claimed almost instantly
├── next-sbcl-input.working   # request currently being processed
├── sbcl-input.log            # append-only record of every request submitted
├── sbcl-output.log           # append-only record of every response (+ startup banner etc.)
├── cancel-request            # dropped by `ctl.sh interrupt`; consumed within one poll cycle
├── .sbcl-bridge.pid          # PID file written by ctl.sh
├── processed/                # archived requests, named <reqid>.lisp
│   ├── error-<timestamp>.lisp    # archived if renaming failed at the infra level
│   └── leftover-<timestamp>.lisp # a claimed-but-unfinished request found at startup
├── cores/                    # suspended executable images, from ctl.sh suspend
│   ├── bridge-<timestamp>.core
│   └── bridge-<timestamp>.core.version   # sidecar: SBCL version + machine type at save time
└── logs/                     # rotated, gzipped log generations
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
  synthesizes one (`auto-<universal-time>-<random>`).  `sbcl-client.sh` always
  supplies one (a nanosecond timestamp + its own PID).

- **`TIMEOUT`** overrides the bridge's default per-request timeout (seconds),
  or disables it entirely with the literal value `none`.

Because these are ordinary `;;; ...` Lisp comments, the reader ignores them
automatically — there's no preprocessing step that strips them before
evaluation, and a request with no headers at all is just as valid as one with
both.

Every top-level form in the request is read and evaluated **in sequence**, in
the order they appear — so `(defun ...)` followed by a call to that function
in the same request works exactly as you'd expect, as would an `(in-package
...)` form changing what package the rest of the request reads in.

### 2.6 The response format

Every request produces a block in `sbcl-output.log` that looks like this:

```
;;; BEGIN-OUTPUT id=my-unique-id ts=3987654321
;;; => 144
;;; END-OUTPUT id=my-unique-id status=ok
```

- One `;;; => value1 ; value2 ; ...` line is printed per evaluated
  form, using `~S` (so it round-trips as Lisp), with multiple return
  values separated by `;`.

- `status=` on the `END-OUTPUT` line is always one of:

  | Status             | Meaning                                                          |
  |--------------------|-------------------------------------------------------------------|
  | `ok`               | Every form evaluated without incident.                            |
  | `error`            | An `ERROR` condition was signalled (see §8.3).                    |
  | `timeout`          | The request exceeded its timeout (see §8.1).                      |
  | `cancelled`        | The request was interrupted via `ctl.sh interrupt` (see §8.2).     |
  | `fatal-condition`  | A non-`ERROR` `SERIOUS-CONDITION` occurred, e.g. `STORAGE-CONDITION` (heap/stack exhaustion) (see §8.3). |

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

1. Client writes `next-sbcl-input.lisp` (atomically).

2. Bridge notices it, immediately renames it to `next-sbcl-input.working` —
   this is what "clears the way" for the next request as soon as one is
   claimed, rather than only after it finishes.

3. Bridge logs the request, evaluates it, prints the response.

4. Bridge renames the working file to `processed/<reqid>.lisp`.

If the process dies (or suspends) between steps 2 and 4, the next `run-bridge`
startup (a fresh `start`, or a `resume`) finds the orphaned
`next-sbcl-input.working` and archives it as
`processed/leftover-<timestamp>.lisp` rather than leaving it stuck — so a
crash never wedges the input slot shut.

---

## 3. Installation & requirements

- **SBCL** with thread support (`:sb-thread` in `*features*` — true of
  essentially every mainstream Linux build). Without thread support,
  cancellation is disabled but everything else still works; the bridge prints
  a warning at startup in that case.

- **Bash**, `gzip`, standard coreutils (`ps`, `awk`, `sed`, `mktemp`, `wc`,
  `ls`). All ordinary on Debian/Ubuntu.

- No systemd, no cron, no network daemon — everything here is designed to work
  unmodified inside a bare Docker container.

Put all three files on disk together (or anywhere, as long as you either keep
`sbcl-bridge.lisp` alongside `sbcl-bridge-ctl.sh` or point `SBCL_BRIDGE_LISP`
at it), and make the two shell scripts executable:

```bash
chmod +x sbcl-bridge-ctl.sh sbcl-client.sh
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
  directly.

### Internal design notes worth knowing

- **Single-threaded evaluation, one watchdog thread.** All actual code
  evaluation happens on the bridge's main thread. A second "bridge-watchdog"
  thread runs alongside it purely to watch for the `cancel-request` control
  file and, when needed, asynchronously interrupt the main thread (see §8.2).

- **`handler-bind`, not `handler-case`, around evaluation.** `handler-case`
  unwinds the stack *before* running its handler body — which would make
  backtrace capture useless. `handler-bind` runs its handler in the original
  signalling context, stack intact, which is what makes §8.3's backtraces
  meaningful.

- **A `*debugger-hook*` backstop.** In `--non-interactive` mode, SBCL's own
  default behavior on a truly unhandled condition is already to print a
  backtrace and exit rather than hang — but the bridge installs its own hook
  so that if something ever escapes all of the handling described in §8.3
  (which would be a bug), the log still records which request was active
  before the process exits.

---

## 6. `sbcl-bridge-ctl.sh` — process management

No systemd required. Uses a PID file and plain `kill`, works identically
inside a container.

### Commands

| Command                       | Effect |
|--------------------------------|--------|
| `start`                        | Cold-starts a fresh SBCL process running `run-bridge`. No-op (with a message) if already running. |
| `stop`                         | Sends `SIGTERM`, waits up to `SBCL_STOP_TIMEOUT`, escalates to `SIGKILL` if needed. |
| `restart`                      | `stop` then `start`. |
| `status`                       | Reports running/stopped, PID, uptime, RSS/VSZ memory, saved core images, and log sizes. Also triggers a cheap size-based log-rotation check (see §8.5). |
| `suspend [core-path]`          | Saves an executable core image and stops the process (see §8.4). Defaults to `cores/bridge-<timestamp>.core`. |
| `resume [core-path]`           | Resumes from a saved core image. Defaults to the most recent one in `cores/`. |
| `interrupt [reqid]`            | Cancels whatever request is currently running, or a specific one by id (see §8.2). |
| `rotate-logs [--force]`        | Rotates logs now. Without `--force`, only rotates logs that have actually exceeded `SBCL_LOG_MAX_BYTES`. |

### Environment variables

| Variable                | Default                        | Meaning |
|--------------------------|--------------------------------|---------|
| `SBCL_BRIDGE_DIR`        | `.`                             | Directory the bridge monitors. |
| `SBCL_BRIDGE_LISP`       | alongside this script           | Path to `sbcl-bridge.lisp`. |
| `SBCL_BIN`               | `sbcl`                          | The SBCL executable to run. |
| `SBCL_CORE_RETAIN`       | `3`                             | Number of suspended core images to keep; oldest are pruned after a successful new suspend. |
| `SBCL_STOP_TIMEOUT`      | `10`                            | Seconds to wait for graceful exit before `SIGKILL` on `stop`. |
| `SBCL_SUSPEND_TIMEOUT`   | `60`                            | Seconds to wait for `suspend` to finish saving and exiting. |
| `SBCL_LOG_MAX_BYTES`     | `10485760` (10 MiB)             | A log is rotated once it exceeds this size. |
| `SBCL_LOG_RETAIN`        | `5`                             | Number of rotated, gzipped log generations to keep (per log file). |
| `SBCL_MEM_WARN_MB`       | *(unset)*                       | If set, `status` prints a warning when RSS exceeds this many MB. |

---

## 7. `sbcl-client.sh` — submitting work

```bash
sbcl-client.sh eval '<lisp forms...>'
sbcl-client.sh file <path-to-lisp-file>     # shortcut: submit an existing file
sbcl-client.sh -                            # read code from stdin
```

The client:

1. Generates a unique request id (nanosecond timestamp + its own PID).

2. Writes the code (with `REQID`/`TIMEOUT` headers) to a temp file, then
   atomically renames it into place.

3. Records the current byte size of `sbcl-output.log` so it only ever scans
   *new* content — cheap even in a long-lived session with a huge log.

4. Polls until it sees the matching `END-OUTPUT` marker, then prints
   everything between `BEGIN-OUTPUT` and `END-OUTPUT` and exits with a
   status-appropriate code.

### Environment variables

| Variable                 | Default | Meaning |
|----------------------------|---------|---------|
| `SBCL_BRIDGE_DIR`          | `.`     | Directory the bridge monitors. |
| `SBCL_POLL_INTERVAL`       | `0.2`   | Seconds between checks of the output log. |
| `SBCL_TIMEOUT`             | `30` (or `SBCL_REQUEST_TIMEOUT + 5` if that's set and larger) | Seconds *this script* waits for any response at all before giving up. |
| `SBCL_REQUEST_TIMEOUT`     | *(unset — bridge's own default applies, currently 30s)* | Seconds the *bridge* allows the evaluation itself to run. `none` disables it for this request. |

### Exit codes

| Code | Meaning |
|------|---------|
| 0    | `status=ok` |
| 1    | `status=error` — an `ERROR` condition was signalled |
| 2    | No response arrived within `SBCL_TIMEOUT` (client-side wait timeout — the bridge may still be working, or may be stuck) |
| 3    | `status=timeout` — the bridge-side per-request timeout expired |
| 4    | `status=cancelled` — cancelled via `ctl.sh interrupt` |
| 5    | `status=fatal-condition` — a non-`ERROR` `SERIOUS-CONDITION` occurred |

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
   process down.  Confirmed by deliberately blowing the control stack in
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
  than interrupting it. `ctl.sh suspend` refuses to proceed if a request is
  already pending in `next-sbcl-input.lisp`, to avoid ambiguity about
  ordering.

- `save-lisp-and-die` refuses to run while other threads are alive.
  `suspend-bridge` stops the watchdog thread first automatically; you don't
  need to do anything about this yourself.

- **Version metadata.** A sidecar file (`<core-path>.version`) records
  `(lisp-implementation-version)` and `(machine-type)` at save time.  `ctl.sh
  resume` compares this against the currently configured `$SBCL_BIN` and
  prints a warning (not a hard failure — the image is self-contained and
  executable, so a mismatch is often survivable) if they differ. If the
  sidecar is missing entirely, it warns that it can't verify compatibility at
  all.

- **Core retention.** `ctl.sh suspend` prunes down to `SBCL_CORE_RETAIN`
  (default 3) most recent images — but only *after* confirming the new one
  saved successfully, so a failed suspend never costs you your last good
  image.

- **Crash resilience.** If a resume attempt is interrupted or the bridge
  otherwise finds a stale `next-sbcl-input.working` file at startup, it's
  archived to `processed/leftover-<timestamp>.lisp` automatically rather than
  blocking future requests.

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
afterward would just sit empty.  This is the standard "copytruncate" problem,
and the standard workaround: copy the current contents aside (gzipped, into
`logs/`), then truncate the *original* file in place (`: > sbcl-output.log`).
The running process's descriptor still points at that same inode, so its next
write lands cleanly in what is now an empty file. Verified directly: submitted
a request, rotated, submitted another — the second response landed in the
freshly truncated live log, not the rotated copy.

The one accepted caveat (shared with real `logrotate` in copytruncate mode): a
write landing in the small window between the `cp` and the truncate can be
lost. Given these logs are mostly idle between discrete request/response
cycles, this window is vanishingly small in practice.

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
```

Set `SBCL_MEM_WARN_MB` to have `status` print a warning (to stderr) whenever
RSS exceeds that threshold — enough to notice a slow memory leak over a
long-running agent session before it becomes an out-of-memory problem for the
container.

---

## 9. Known limitations & caveats

Worth internalizing before you rely on this in production:

- **Single request in flight at a time**, by design. The client blocks until
  it sees its response. If you need concurrent callers, add your own
  lock/queueing around request submission — the underlying protocol doesn't
  need to change, but nothing here arbitrates between two callers racing to
  write `next-sbcl-input.lisp` simultaneously.

- **No sandboxing.** Submitted code runs with the full privileges of the SBCL
  process — filesystem, network, `sb-ext:run-program`, all of it. Presumably
  intentional for a coding-agent tool, but if you want a safety margin, add it
  at the Docker layer (unprivileged user, cgroup memory/CPU limits, restricted
  network namespace) rather than in the bridge itself.

- **Cancellation needs a safepoint.** Code stuck inside a blocking foreign
  call won't respond to `interrupt` (see §8.2).

- **Backtrace filtering uses unexported SBCL internals**
  (`sb-debug::map-backtrace`, `sb-debug::print-frame-call`). They work on the
  SBCL version this was built and tested against, but aren't part of SBCL's
  stable public API. There's an automatic fallback to the unfiltered public
  API if they ever go away — worth a quick smoke test after any SBCL upgrade.

- **Copytruncate race window** (§8.5): a write landing in the instant between
  copy and truncate can theoretically be lost. Negligible in practice for this
  workload.

- **Version-compatibility check on resume is advisory, not a guarantee.** It
  compares `(lisp-implementation-version)` and `(machine-type)`; a warning
  means "you should look into this before trusting the result," not "this
  definitely won't work" — and conversely, a match doesn't guarantee every
  possible edge case is fine either.

- **No log rotation without something calling `status`.** If nothing ever
  polls `status` and you never explicitly call `rotate-logs`, the logs will
  grow unbounded. Any reasonably active agent loop calling `status`
  periodically for health-checking purposes handles this incidentally, but a
  completely dormant bridge with nobody checking on it will not self-rotate.

---

## 10. Troubleshooting

| Symptom | Likely cause / fix |
|---------|---------------------|
| `sbcl-client.sh` exits 2 ("timed out waiting for response") | Either the bridge isn't running (`ctl.sh status`), or the request is still genuinely executing — raise `SBCL_TIMEOUT`, or check whether it needs `ctl.sh interrupt`. |
| `ctl.sh start` says "Failed to start" | Check `sbcl-output.log` directly for the SBCL-level error (e.g. `sbcl-bridge.lisp` not found — check `SBCL_BRIDGE_LISP`). |
| `ctl.sh suspend` fails with a "multiple threads" style error in the log | Should not happen — `suspend-bridge` stops the watchdog thread first automatically. If you see this, something loaded extra threads into the image before suspending; check what else your submitted code may have spawned. |
| `ctl.sh resume` prints a version-mismatch warning | Informational; the image is self-contained and often still works. If it then actually fails, you'll need to `start` fresh instead (state from that particular suspend point is lost, but everything from before that suspend point that made it into an earlier still-good core is not). |
| A stray `sbcl` process left over from a previous test | `ps aux \| grep sbcl-bridge.lisp`, then `kill` it — `ctl.sh stop` only knows about the PID recorded in `.sbcl-bridge.pid` for *its* `SBCL_BRIDGE_DIR`; a leftover process pointed at the same directory from an earlier, differently-invoked session can race with a newly started one. |
| Logs growing without bound | Nothing has called `status` or `rotate-logs` recently — see §9's last point. |
| A request seems to hang forever with no timeout firing | Check whether it was submitted with `SBCL_REQUEST_TIMEOUT=none`; use `ctl.sh interrupt` to cancel it directly. |

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
./sbcl-bridge-ctl.sh rotate-logs [--force]

# Submit work
./sbcl-client.sh eval '(+ 1 2 3)'
./sbcl-client.sh file path/to/code.lisp
echo '(+ 1 2)' | ./sbcl-client.sh -

# Per-request timeout
SBCL_REQUEST_TIMEOUT=5    ./sbcl-client.sh eval '(sleep 10)'   # -> status=timeout
SBCL_REQUEST_TIMEOUT=none ./sbcl-client.sh eval '(long-job)'   # no timeout

# Request headers (equivalent, written by hand instead of via the client)
cat > next-sbcl-input.lisp << 'EOF'
;;; REQID: manual-1
;;; TIMEOUT: 10
(+ 1 2)
EOF
```

| Client exit code | Meaning |
|---|---|
| 0 | ok |
| 1 | evaluation error |
| 2 | client gave up waiting (`SBCL_TIMEOUT`) |
| 3 | bridge-side timeout (`SBCL_REQUEST_TIMEOUT`) |
| 4 | cancelled (`ctl.sh interrupt`) |
| 5 | fatal non-error condition |
