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
  - End-to-end smoke test: spins up a throwaway bridge in a temp directory and
    exercises every major behavior in ~60 seconds. Run it after any SBCL
    upgrade or change to the bridge itself. Every run — pass or fail — leaves
    a `sbcl-bridge-test-diagnostics-<timestamp>.tar.gz` in the directory it
    was invoked from (see §3.1); handing that file over is usually enough to
    debug a failure on a machine nobody else can log into.

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
├── quicklisp-installer.lisp      # cached quicklisp.lisp download
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
  supplies one (a nanosecond timestamp, its own PID, and a random component) —
  unless the submitted code already carries its own `REQID` header, in which
  case the client reuses it rather than shadowing it; an embedded `TIMEOUT`
  header likewise extends the client's wait budget (see §7, "Embedded
  headers"). The response and input log markers always echo the reqid exactly
  as submitted, but the archive *filename* in `processed/` is sanitized to
  alphanumerics plus `.`/`_`/`-` (other characters become `_`, leading dots
  are stripped, and the name is capped at 100 characters) — so a hand-written
  reqid containing `/`, pathname wildcards, or other junk can't break the
  archive rename or name a file outside `processed/`. Distinct raw ids that
  sanitize to the same name overwrite each other in the archive.

- **`TIMEOUT`** overrides the bridge's default per-request timeout (seconds),
  or disables it entirely with the literal value `none`. Note that any
  non-positive value (`0` or negative) also **disables** the timeout rather
  than timing out immediately, and an unparseable value silently falls back to
  the bridge default.

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
explicit `(in-package ...)`, or wrap state changes you don't want to leak in a
`let` that rebinds the relevant specials for just that request.

### 2.6 The response format

Every request produces a block in `sbcl-output.log` that looks like this:

```
;;; BEGIN-OUTPUT id=my-unique-id ts=3987654321
;;; => 144
;;; END-OUTPUT id=my-unique-id status=ok
```

- One `;;; => value1 ; value2 ; ...` line is printed per evaluated form,
  using `~S` (so it round-trips as Lisp), with multiple return values
  separated by `;`. A value whose *printing* signals (a broken `print-object`
  method, say) is rendered as `#<unprintable TYPE>` instead — the form
  evaluated successfully, so a presentation failure doesn't flip the request
  to `status=error`. (Printing that *loops* rather than signals — circular
  structure, since `*print-circle*` is off for round-trippable output — is
  bounded by the request timeout instead.)

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

4. Bridge renames the working file to `processed/<reqid>.lisp` (with the reqid
   sanitized for filename safety, see §2.5). A request that suspends the
   bridge does this step itself: `suspend-bridge` archives its own working
   file under its reqid immediately before `save-lisp-and-die`, since the
   process exits before the bridge loop could.

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
smoke test — it needs no setup and uses throwaway temp directories for the
bridges it starts:

```bash
./sbcl-bridge-test.sh
# ...
# == 44 passed, 0 failed ==
#
# Diagnostics bundle: /path/you/ran/this/from/sbcl-bridge-test-diagnostics-20260101-120000.tar.gz
```

### 3.1 Diagnostics bundle

Every run of `sbcl-bridge-test.sh` — whether everything passes or something
fails — ends by writing a single `sbcl-bridge-test-diagnostics-<timestamp>.tar.gz`
to the directory it was invoked from. This is deliberately the one thing the
otherwise-thorough cleanup *doesn't* touch: every throwaway bridge directory
the run creates gets deleted as usual, but not before its logs are copied
into this bundle first, so the evidence survives the cleanup instead of being
deleted along with the temp directories it lived in.

The bundle contains:

- `transcript.log` — everything the script printed, exactly as seen on the
  terminal (stdout and stderr together), including internal
  `wait_for_log_pattern` timing lines — useful because how long the bridge
  takes to finish starting varies with machine speed and load in ways a single
  number measured on one machine can't predict, which is exactly what made the
  fixed-sleep version of this suite's own readiness checks flaky.

- `summary.txt` — just the `PASS`/`FAIL` lines and the final tally, for a
  quick look without reading the full transcript.

- `environment.txt` — SBCL version, `uname -a`, core count and memory, every
  `SBCL_*`/`QUICKLISP_*` environment variable this tooling reads (or
  confirmation it's unset), `PATH`, and `curl`/`wget` availability and
  versions. Nothing here is secret — paths and version strings, nothing that
  looks like a credential.

- `logs/<label>/` — the `sbcl-output.log`, `sbcl-input.log`, `processed/`
  archive, and any `.version` sidecars from every bridge directory the run
  touched (`main`, `preflight`, `quicklisp-unset`, `quicklisp-degrade`,
  `moved-workspace`), captured just before that directory was deleted.  `main`
  is the primary bridge used for most of the suite and usually the most
  informative; the others correspond to the specific isolated scenarios named
  in §8's feature sections.

If a test fails (or behaves differently) on a machine you can't get direct
access to, this bundle is normally enough to debug from — attach it rather
than trying to describe what happened secondhand.

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
  right before saving — a normal suspend leaves no `leftover-*.lisp` behind on
  resume.

### Internal design notes worth knowing

- **Single-threaded evaluation, one watchdog thread.** All actual code
  evaluation happens on the bridge's main thread. A second "bridge-watchdog"
  thread runs alongside it purely to watch for the `cancel-request` control
  file and, when needed, asynchronously interrupt the main thread (see §8.2).

- **Bridge output is serialized by a recursive lock.** SBCL streams aren't
  thread-safe, and both the main thread and the watchdog write to
  `*standard-output*`, so every bridge-emitted line (markers, `;;; =>` values,
  condition reports, `CANCEL-REQUESTED`, ...) is written under one shared
  lock. The lock is *recursive* because a cancellation interrupt can land on
  the main thread while it already holds the lock mid-line; the unwinding
  handler then re-acquires it to print its `CANCELLED`/`END-OUTPUT` lines — a
  plain mutex would self-deadlock there. What *evaluated code* prints is
  deliberately not locked (the bridge can't wrap arbitrary user output), so a
  request's own prints can still theoretically interleave with a watchdog
  one-liner — but bridge lines can no longer garble each other.

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
  setting both means the reqid-logging backstop runs regardless of which one a
  given SBCL consults first.

- **Quicklisp support (§8.7) never references a Quicklisp symbol directly.**
  `ql:quickload`, `ql-setup:*quicklisp-home*`, `quicklisp-quickstart:install`
  and everything else Quicklisp-related is resolved at runtime via
  `find-package`/`find-symbol` on plain strings. A literal package-qualified
  symbol referencing a package that doesn't exist is a **reader** error in
  Common Lisp — it would happen while `sbcl-bridge.lisp` itself is being
  loaded, before any code runs, breaking the bridge for every user regardless
  of whether they ever set `QUICKLISP_HOME`. String-based resolution defers
  that lookup until the package is known to exist (or gracefully handles it
  not existing at all).

---

## 6. `sbcl-bridge-ctl.sh` — process management

No systemd required. Uses a PID file and plain `kill`, works identically
inside a container.

**Exit codes:** `0` on success, `1` on any failure, uniformly across every
subcommand — the conventional shell-tool convention (like `git`, `docker`,
`systemctl`), not the finely-subdivided scheme `sbcl-client.sh` uses (§7).
This is a deliberate difference, not an oversight: `ctl.sh` is a lifecycle
tool whose callers are humans and `Makefile`/`docker` orchestration that
branch on "did this succeed", with the specific reason always in the stderr
message. `sbcl-client.sh`, by contrast, runs in the hot path of an agent's
request/response loop, where the caller genuinely needs to distinguish
outcomes programmatically (`retry` vs. `give up` vs. `treat as an evaluation
error`) without parsing text — which is what earns its exit codes a fully
enumerated, disjoint contract.

### Commands

- `start`
  - Cold-starts a fresh SBCL process running `run-bridge`. No-op (with a
    message) if already running. SBCL is always started with `--no-sysinit
    --no-userinit`: the bridge must behave identically in a bare container and
    on a developer desktop, and a stray `/etc/sbclrc` or `~/.sbclrc` that
    loads Quicklisp, changes `*print-*` settings, or merely prints something
    would make evaluation results environment-dependent (and could corrupt the
    marker protocol). Anything an init file would have provided can be loaded
    explicitly as an ordinary first request instead — which also means it's
    captured in the input log and, unlike an init file, becomes image state
    that survives suspend/resume. (`resume` never processes init files either:
    the saved image's custom toplevel bypasses the startup sequence that would
    read them, and the version probe used for core-compatibility checks runs
    with the same flags.)

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
    recycled by an unrelated process after a crash reads as STOPPED instead of
    RUNNING — and can't be `SIGTERM`ed by `stop`. Also triggers cheap
    housekeeping: a size-based log-rotation check (see §8.5) and pruning of
    `processed/` down to `SBCL_PROCESSED_RETAIN` files, so anything that polls
    `status` keeps both bounded for free.

- `suspend [core-path]`
  - Saves an executable core image and stops the process (see §8.4). Defaults
    to `cores/bridge-<timestamp>.core`.

- `resume [core-path]`
  - Resumes from a saved core image. Defaults to the most recent one in
    `cores/`. Watches `SBCL_BRIDGE_DIR` (always exported for the resumed
    process, as an absolute path), not necessarily the directory baked into
    the image at suspend time — see "Moved workspaces" in §8.4.

- `interrupt [reqid]`
  - Cancels whatever request is currently running, or a specific one by id
    (see §8.2).

- `logs [-f] [lines]`
  - Prints the last N lines (default 50) of `sbcl-output.log` for this
    `SBCL_BRIDGE_DIR`, or follows it live with `-f` (like `tail -f`). Purely a
    convenience so you don't have to compose the log path by hand.

- `rotate-logs [--force]`
  - Rotates logs now. Without `--force`, only rotates logs that have actually
    exceeded `SBCL_LOG_MAX_BYTES`, and never while a request is queued or in
    flight (so a waiting client can't have the log truncated out from under it
    — see §8.5). `--force` rotates regardless of size *and* busyness, with a
    warning if a request is in flight.

### Environment variables

- `SBCL_BRIDGE_DIR` — default `.`
  - Directory the bridge monitors.

- `SBCL_BRIDGE_LISP` — default: alongside this script
  - Path to `sbcl-bridge.lisp`.

- `SBCL_BIN` — default `sbcl`
  - The SBCL executable to run.

- `SBCL_CORE_RETAIN` — default `3`
  - Number of suspended core images to keep; oldest are pruned after a
    successful new suspend. Pruning also removes orphaned `.version` sidecars
    (a sidecar is written just *before* `save-lisp-and-die`, so a failed save
    can leave one behind with no matching core).

- `SBCL_PROCESSED_RETAIN` — default `200`
  - Number of archived request files (`processed/*.lisp`, including `error-*`
    and `leftover-*`) to keep; the oldest beyond that are pruned on every
    `status` call. Nothing bridge-side ever deletes archives, so without this
    an agent hammering the bridge would accumulate them without bound.

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

0. Before touching anything, checks that `SBCL_BRIDGE_DIR` actually looks like
   it's being watched by a *live* bridge, rather than just assuming a
   directory that happens to exist is one. A directory can exist and still
   have no bridge behind it — nobody ever started one there, or one used to
   run but crashed or was `stop`ped — and without this check a submission
   against a dead bridge would otherwise sit until `SBCL_TIMEOUT` and then
   report a misleading "timed out waiting for response" (exit 2) instead of
   the real problem. Concretely, the check:
   - fails if `SBCL_BRIDGE_DIR` doesn't exist at all;
   - fails if there's no `.sbcl-bridge.pid` in it;
   - fails if the recorded pid isn't `kill -0`-alive (a stale pidfile from a
     crashed or manually-`kill`ed process);
   - fails if, per `/proc/<pid>/cmdline` where readable, the alive process
     doesn't look like `sbcl` at all — guarding against the same PID-reuse
     edge case `ctl.sh status` guards against (§9): a crash followed by the OS
     recycling that pid for an unrelated process.

   Each failure prints a specific reason and exits 6, pointing at `ctl.sh
   start` where that's the likely fix. This is a **liveness check, not a
   guarantee** — the bridge can still crash, hang, or belong to a completely
   different `SBCL_BRIDGE_LISP` between this check and the actual submission a
   moment later — but it turns the most common misconfiguration (pointing the
   client at the wrong, or no longer running, bridge) into an immediate,
   specific error instead of a slow, generic timeout.

1. Scans the leading `;;; KEY: value` header comments of the submitted code
   (any mode — `file`, `eval`, or stdin) with the same parser rules the bridge
   uses, and honors what it finds: an embedded `;;; REQID:` is **reused** as
   the request id rather than shadowed by a generated one, and an embedded
   `;;; TIMEOUT:` feeds into the client's own wait budget (step below). If the
   code carries no `REQID`, the client generates a unique one (nanosecond
   timestamp + its own PID + a random component; on non-GNU `date` without
   `%N` support, the latter two still keep ids unique).

2. Writes the code to a temp file — prepending a `REQID` header only when it
   generated one, and a `TIMEOUT` header only when `SBCL_REQUEST_TIMEOUT` is
   set — then atomically hard-links it into place. `ln` fails if
   `next-sbcl-input.lisp` already exists, so a request that's queued but not
   yet claimed by the bridge is never overwritten — if the slot is busy, the
   client polls until the bridge claims the queued request (within the overall
   `SBCL_TIMEOUT` budget), so sequential callers queue up safely instead of
   clobbering each other.

3. Records the current byte size of `sbcl-output.log` so it only ever scans
   *new* content — cheap even in a long-lived session with a huge log. If the
   log is rotated (truncated) while the client is waiting, it detects that the
   file shrank below its remembered offset and rescans from the top rather
   than waiting forever past EOF.

4. Polls until it sees the matching `END-OUTPUT` marker, then prints
   everything between `BEGIN-OUTPUT` and `END-OUTPUT` and exits with a
   status-appropriate code. The markers are matched *through* the delimiter
   that follows the id (`id=<reqid> `), so a reqid that happens to be a strict
   prefix of another reqid can never match the wrong request's block.

### Embedded headers: self-describing request files

A request file can carry its own headers, and submitting it through the client
Just Works — this is the idiomatic way to package a setup script that knows
its own identity and how long it's allowed to take:

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

The response markers and the `processed/` archive carry `project-setup`, and
the client waits up to 50 seconds (45 + 5) rather than abandoning the request
at its default 30 — previously the bridge would honor the embedded `TIMEOUT`
while the client, unaware of it, gave up first with exit 2.

Precedence for the evaluation timeout, highest first: `SBCL_REQUEST_TIMEOUT`
(env) → embedded `;;; TIMEOUT:` header → the bridge's default. (The env value
wins mechanically: the client prepends it ahead of the code, and the bridge
honors the first `TIMEOUT` header it sees.) `SBCL_TIMEOUT`, when set, still
overrides the client's *wait budget* unconditionally.

One caveat with a fixed, reused `REQID`: response correlation is unaffected
(the client only scans log output appended after its own submission), but each
run's `processed/` archive overwrites the previous one, and log entries from
different runs share the same id — fine for setup scripts, less ideal for
requests you want to tell apart later.

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

This is a deliberate, disjoint scheme meant to be a stable contract for
scripted or agent callers: each code means exactly one thing, never two.
Codes **0–5** mean the request was delivered and the bridge reported an
outcome for it. Codes **6–7** mean the request was **never delivered** —
nothing was evaluated, and there is no `BEGIN-OUTPUT`/`END-OUTPUT` pair in the
log for the attempt.

Bridge reported an outcome (0–5):

- **0** — `status=ok`

- **1** — `status=error`
  - An `ERROR` condition was signalled while evaluating the submitted code.

- **2** — no response in time
  - The request **was** successfully submitted, but no response arrived within
    the wait budget (`SBCL_TIMEOUT`, or the computed default). The bridge may
    still be working on it — this is this *script* giving up waiting, not the
    bridge reporting a timeout (see the note on exit 3 below).

- **3** — `status=timeout`
  - The bridge-side per-request timeout expired (`SBCL_REQUEST_TIMEOUT` or an
    embedded `TIMEOUT` header).

- **4** — `status=cancelled`
  - Cancelled via `ctl.sh interrupt`.

- **5** — `status=fatal-condition`
  - A non-`ERROR` `SERIOUS-CONDITION` occurred.

Request never delivered (6–7) — a client-local failure, no bridge interaction
happened for this attempt:

- **6** — usage or preflight error
  - Bad command-line usage, a missing `SBCL_BRIDGE_DIR`, or no live bridge
    found watching it (the step-0 liveness check in §7 above). This means
    **fix your setup** — retrying without changing anything will keep failing
    the same way.

- **7** — could not submit in time
  - The request was fully formed locally, but the input slot never freed up
    within the wait budget because another request stayed queued the whole
    time. This means **the bridge is just busy** — retrying later, or `ctl.sh
    interrupt`-ing whatever's queued, may help; nothing here is broken.

Two related distinctions are worth internalizing:

- **Exit 2 vs. exit 3**: 2 is this *script* giving up waiting; 3 is the
  *bridge* reporting that it gave up evaluating. If you set
  `SBCL_REQUEST_TIMEOUT` without also raising `SBCL_TIMEOUT`, the client
  auto-adjusts its own wait to `SBCL_REQUEST_TIMEOUT + 5` so it doesn't give
  up on exit 2 right as the bridge's own timeout is about to report properly
  on exit 3.

- **Exit 6 vs. exit 7**: both mean nothing was evaluated, but 6 is a *setup*
  problem (nothing will change on retry until you fix it) and 7 is
  *contention* (the bridge is healthy but occupied, and simply retrying,
  waiting, or raising `SBCL_TIMEOUT` may well succeed next time).

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

Two edge cases in how the `TIMEOUT` header is interpreted, worth knowing: a
value of `0` (or anything negative) **disables** the timeout, exactly like
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
that calls `run-bridge` again using the poll-interval/timeout/backtrace-frames
settings that were cached in global variables when the bridge started, so
resuming re-enters the exact same polling loop with no `--load`/`--eval` flags
needed — **except for the watched directory**, which is instead taken from the
resuming process's own `SBCL_BRIDGE_DIR` environment variable when one is set
(see "Moved workspaces" below). The saved image is a fully self-contained
executable (`:executable t :save-runtime-options t`) — resuming it is just
running the file; that same flag also means an `--eval`-based override is not
merely unnecessary but flatly impossible, since `:save-runtime-options t`
makes the executable refuse to parse *any* runtime option (including `--eval`)
when run directly. Reading the environment from ordinary Lisp code after the
runtime has already started is the one mechanism that works regardless of
invocation style.

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
  contrib (`sb-posix`, `uiop`, `asdf`, `sb-bsd-sockets`, etc. — and note that
  many Quicklisp systems pull these in transitively, e.g. `cl-postgres` needs
  `sb-rotate-byte`) that wasn't already loaded *before* the suspend will fail
  with `Don't know how to REQUIRE ...` after a resume, even though the exact
  same code works perfectly on a fresh `start`.

  `write-version-sidecar` records the home directory in effect at save time
  (normalized via `truename`, and falling back to the `SBCL_HOME` this process
  was itself resumed with, so the record survives chains of suspend/resume
  cycles), and `ctl.sh resume` restores a home into the `SBCL_HOME`
  environment variable before launching. Crucially, the recorded value is
  **not trusted blindly**: the machine that suspended the core may not be the
  machine resuming it. The canonical case is a shared-workspace workflow —
  suspend on the host, resume the identical core inside a container (or vice
  versa) — where the two sides' `sbcl` binaries live at different prefixes
  (`/usr/local` build on one side, the distro package under `/usr` on the
  other), so the recorded `<prefix>/lib/sbcl/` simply doesn't exist on the
  resuming side; or it exists but holds contrib fasls built by a different
  SBCL version, which the resumed image can't load.  `resume` therefore
  *validates* every candidate (the directory must exist and contain
  `contrib/`) and picks by provenance: if the local `sbcl`'s build matches the
  image's, the **local installation's** home is preferred (its fasls are
  guaranteed compatible, wherever it lives), with the sidecar as fallback; if
  the builds differ, the **sidecar's** home is preferred (the only place with
  matching-version fasls, if it still exists), with the local home as a
  warned-about last resort. A caller-provided `SBCL_HOME` always wins but is
  sanity-checked, and if nothing validates, `resume` says so loudly instead of
  exporting a dead path.

  The more robust practice, when it's an option: load (via `ql:quickload` or
  plain `require`) everything your workload needs *before* suspending. Once a
  contrib is loaded into the image, its code is baked into the heap and never
  needs to be found on disk again after a resume — this is why suspending only
  after your environment is fully set up (rather than right after a bare
  `start`) is the better habit to build.

- **Moved workspaces: `SBCL_BRIDGE_DIR` on resume.** `SBCL_HOME` isn't the
  only thing baked into a suspended image that can go stale when the image
  moves — the directory the bridge watches is baked in too, as
  `*bridge-directory*`, precisely so a resume needs no arguments. In the same
  shared-workspace workflow as above (a host and a container mounting the same
  directory at *different* paths — `/home/user/workspace` on the host,
  `/workspace` in the container, say), a core suspended on one side and
  resumed on the other would, without correction, come back healthy, running,
  and watching a directory that doesn't exist (or exists but is the wrong one)
  on the resuming side — every request submitted there would simply never be
  seen, with no error anywhere.

  `resume-bridge` corrects for this the same way `SBCL_HOME` is corrected: if
  the resuming process's own environment has a non-empty `SBCL_BRIDGE_DIR`,
  that directory is used instead of the one saved in the image, and a `;;;
  RESUME: SBCL_BRIDGE_DIR=... overrides ...` line is logged so the
  substitution is visible. `ctl.sh resume` always exports `SBCL_BRIDGE_DIR`
  for the child it launches — as an absolute, symlink-resolved path, computed
  once via `cd "$BRIDGE_DIR" && pwd` — regardless of whether the caller's own
  shell happened to export it, so this works reliably without depending on the
  caller's environment setup.  `ctl.sh start` exports the same thing for a
  fresh bridge, for a reason that matters here too: whatever directory a
  *future* suspend of this bridge bakes in will itself be this same absolute,
  correct path, keeping the chain accurate across arbitrarily many
  suspend/resume cycles and moves. (This override is genuinely just for the
  directory. Everything else `resume-bridge` carries over —
  poll-interval/timeout/backtrace-frames — is ordinary session configuration,
  not a location, and continues to persist unconditionally; see the docstrings
  on `*bridge-poll-interval*` and friends if you want the full reasoning.)

  Fixing this override surfaced a second, independent bug worth knowing about
  even though it's now fixed: naively coercing a directory string into a
  pathname in Common Lisp is a real trap. `"/workspace"` (no trailing slash —
  the natural way to write an environment variable, and exactly what
  `SBCL_BRIDGE_DIR` conventionally looks like) parses as a file *named*
  `workspace`, not a directory, and a plausible-looking fix using
  `merge-pathnames` to coerce it back into a directory pathname does **not**
  actually work — `merge-pathnames`'s component-substitution rule pulls the
  stray name back in regardless. Left uncaught, every path the bridge computes
  from such a directory (`next-sbcl-input.lisp`, the output log, `processed/`,
  everything) silently loses its last path segment, and the bridge ends up
  watching (and writing logs into) the *parent* of the intended directory — a
  corruption that produces no error, just a bridge that looks healthy and
  never sees any requests. `ctl.sh` was never affected (it has always appended
  a trailing slash by convention when starting a fresh bridge), which is
  exactly why this stayed latent until the `SBCL_BRIDGE_DIR` override — which
  reads a raw environment variable, trailing slash or not — started exercising
  it. `ensure-directory-pathname` now performs the coercion correctly (by
  reconstructing the name and type as an explicit final directory component,
  rather than trying to get `merge-pathnames` to strip them), and every
  directory argument in the bridge — fresh start, resume, and this override —
  goes through it.

  A third bug turned up in this same small area, worth documenting for the
  same reason as the second: the check for *whether* to apply the override
  originally compared `SBCL_BRIDGE_DIR` against the directory saved in the
  image as raw strings, which routinely differ in spelling even when they name
  the exact same directory — a fresh `start` bakes in a trailing slash
  (`cmd_start` appends one explicitly), but `SBCL_BRIDGE_DIR` as exported for
  a `resume` comes from a plain `pwd`, which never has one. The practical
  effect: resuming into the *same* directory a fresh start had just used would
  print a spurious `RESUME: SBCL_BRIDGE_DIR=... overrides the directory saved
  in this image` line — confusing on its own, and doubly so because it then
  went away on every *subsequent* resume, since that first spurious override
  overwrote the saved directory with the no-trailing-slash spelling, which
  then happened to string-match from then on regardless of whether the
  environment had actually changed. The comparison now goes through the same
  `paths-equal-p` (truename-based, so spelling differences like this one don't
  matter) used for the analogous `SBCL_HOME`/Quicklisp-home comparisons
  elsewhere in this tooling.

  A fourth bug, also in this immediate area and also found via a log line in
  production — `;;; SUSPENDING to /workspace/sbcl-bridge//cores/bridge-....core`
  — is worth documenting for the same reason as the previous two:
  `SBCL_BRIDGE_DIR` with a trailing slash (`SBCL_BRIDGE_DIR=/foo/bar/` is not
  an unreasonable thing to write) used to propagate that trailing slash into
  every path both `sbcl-bridge-ctl.sh` and `sbcl-client.sh` derive from it,
  since each was built by plain string concatenation
  (`"$BRIDGE_DIR/whatever"`) directly from whatever the caller
  supplied. Harmless to the filesystem itself — a double slash resolves
  identically to a single one on any POSIX system — but an avoidable, ugly
  rough edge, and one that a previous fix for a related bug (the
  `SBCL_BRIDGE_DIR`-on-resume override, above) had already partially addressed
  without going far enough: it introduced a second, separately normalized
  variable (`BRIDGE_DIR_ABS`) for use at just the couple of call sites that
  fix specifically needed, while every *other* path in the script kept
  building from the original, un-normalized `BRIDGE_DIR` — which is exactly
  how a caller-supplied trailing slash could still reach a log line.  Both
  scripts now normalize the directory to an absolute, symlink-resolved path
  exactly once, immediately, in the *same* variable everything else already
  used, before anything else derives a path from it — removing the possibility
  of this mistake by removing the second variable, rather than by remembering
  to use it everywhere.

  Beyond `SBCL_HOME` and the watched directory, one more category of
  moved-image risk exists but is **not** something `sbcl-bridge` itself can
  fix, because it lives entirely in what *your own* setup code does: anything
  a setup script bakes in as an absolute path outside of Quicklisp's home and
  ASDF's fasl cache — both of which this tooling *does* relocate automatically
  (§8.7, §8.8) — such as a project-specific `local-projects/` symlink target,
  or a hardcoded path inside your own system definitions. If a setup script is
  run once, baked into a suspended image, and then the image is resumed
  somewhere those paths don't resolve the same way, you can hit an analogous
  class of failure — just one this tooling has no visibility into. The
  practical mitigation is the mirror image of the advice above: either make
  sure such paths resolve to *identical* absolute locations in every
  environment that will resume the image — unlike the bridge's own workspace,
  `QUICKLISP_HOME`, and `XDG_CACHE_HOME`, which are all expected to differ —
  or re-run the setup script fresh after resuming in a new environment rather
  than relying on state baked in before the move.

  One thing that turned out **not** to need any fix, verified directly rather
  than assumed: `*default-pathname-defaults*`, which governs how relative
  pathnames resolve, is not preserved across a resume the way the bridge's own
  state is — SBCL resets it to the resuming process's actual working directory
  at every startup, saved image or not. Any relative-path handling in your own
  request code gets this self-correction for free.

- **Core retention.** `ctl.sh suspend` prunes down to `SBCL_CORE_RETAIN`
  (default 3) most recent images — but only *after* confirming the new one
  saved successfully, so a failed suspend never costs you your last good
  image. Pruning also sweeps up orphaned `.version` sidecars: the sidecar is
  written just *before* `save-lisp-and-die`, so a save that fails partway
  (e.g. because a user-spawned thread was still alive) leaves a
  `foo.core.version` with no `foo.core`, which would otherwise linger forever.

- **No leftovers from a normal suspend.** Because `save-lisp-and-die` exits
  the process, the bridge loop never gets to archive the suspend request's own
  claimed file the usual way. `suspend-bridge` therefore archives its own
  `next-sbcl-input.working` under its reqid (`processed/<reqid>.lisp`)
  immediately before saving — so a suspend/resume cycle driven by `ctl.sh
  suspend` (or any request that calls `suspend-bridge`) leaves nothing behind
  for the resumed bridge to sweep up. This is done as the very last step
  before the save: if anything earlier in `suspend-bridge` fails, the request
  errors out through the normal path with its working file still in place, and
  the loop's usual archive rename (which now checks the file still exists)
  handles it.

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

### 8.7 Quicklisp integration

If `QUICKLISP_HOME` is set in the environment, the bridge makes a best-effort
attempt, on every `run-bridge` start — a fresh `start` or a `resume`, either
one — to have a working Quicklisp available there and pointed there. With
`QUICKLISP_HOME` unset, none of this runs; the feature is entirely opt-in by
that variable's presence.

```bash
export QUICKLISP_HOME=/workspace/quicklisp
./sbcl-bridge-ctl.sh start
# sbcl-output.log:
# ;;; QUICKLISP: loaded, home=/workspace/quicklisp/
```

**Why this exists.** Quicklisp turned out to have exactly the same moved-image
problem as `SBCL_HOME` and the bridge's own watched directory (§8.4) — a
shared workspace mounted at different paths in different environments means
`QUICKLISP_HOME` can legitimately differ between a suspend and a resume — but
with a sharper edge: getting it wrong doesn't fail loudly, it fails by
`ql:quickload` quietly reading from (or writing to) the wrong directory. A
hand-rolled setup script has to get this right on its own; building it into
the bridge means every request-time script can just assume Quicklisp is
already correctly configured for whatever `QUICKLISP_HOME` says right now.

**Three cases, all handled by the same `ensure-quicklisp-configured` call:**

1. **Nothing installed at `QUICKLISP_HOME` yet.** The bridge attempts a fresh
   install, locating a `quicklisp.lisp` bootstrap installer by checking, in
   order: `QUICKLISP_LISP` (an environment variable naming its exact path);
   `/usr/share/common-lisp/source/quicklisp/quicklisp.lisp` (where
   Debian/Ubuntu's package puts it, if installed that way); a copy already
   cached from a previous run at `<bridge-directory>/quicklisp-installer.lisp`
   (see §2.4); and, only if all of those come up empty, a fresh download — via
   `curl` or `wget` (whichever is found first on `PATH`) — into that same
   cache location, from `https://beta.quicklisp.org/quicklisp.lisp` by
   default, or `QUICKLISP_INSTALLER_URL` if that environment variable is set
   (useful for pointing at an internal mirror when the real one isn't
   reachable). Downloaded to a temp file and renamed into place atomically, so
   an interrupted download never leaves a broken file to be mistaken for a
   good one on the next attempt. Once an installer is loaded,
   `quicklisp-quickstart:install :path QUICKLISP_HOME` does the rest.

2. **Already installed at `QUICKLISP_HOME`, but not yet loaded in this
   image.** An ordinary `(load ".../setup.lisp")` — the same thing a
   hand-rolled setup request would otherwise have to do itself.

3. **Already loaded in this image (a resume where Quicklisp was loaded before
   suspend).** If `QUICKLISP_HOME` now names a *different* directory than
   what's baked into the image, the already-loaded client is redirected there
   rather than reloaded — see "The sync, and why it's not just one `setf`"
   below.

Every step is best-effort and defensive by design, matching the philosophy
already established for `SBCL_HOME` restoration: nothing here is allowed to
prevent the bridge from starting or reaching its main loop. A failure at any
point — no installer locatable, a network failure partway through an install,
a `(load ...)` error — is logged to `sbcl-output.log` with a `;;; QUICKLISP:
...` line explaining what happened, and the bridge continues normally, usable
for any request that doesn't need Quicklisp. The very next resume or restart
gets another chance.

**The sync, and why it's not just one `setf`.** Redirecting an already-loaded
Quicklisp client to a new `QUICKLISP_HOME` is not simply `(setf
ql:*quicklisp-home* new-path)`, and this was verified directly against the
actual Quicklisp client source rather than assumed. Two things turned out to
matter:

- `ql:*local-project-directories*` is a Quicklisp-internal `defparameter`,
  computed *once*, at load time, via `(qmerge "local-projects/")` — not
  recomputed on every access. Left alone, it keeps pointing at the old
  `local-projects/` forever, silently, no matter what `*quicklisp-home*` is
  set to afterward. The bridge resets it explicitly alongside the home
  directory itself.

- Dist objects, reassuringly, need **no** equivalent fix.  `ql-dist:all-dists`
  doesn't cache a persistent list anywhere — it rebuilds dist objects from
  scratch, via `qmerge` again, on *every single call*
  (`standard-dist-enumeration-function` just re-scans `(qmerge
  "dists/*/distinfo.txt")` each time it's invoked). So a plain `ql:quickload`
  of anything not already loaded correctly follows an updated
  `*quicklisp-home*` on its own, with no help needed — verified by building
  two independent fake dists in two separate fake `QUICKLISP_HOME` trees and
  confirming `ql-dist:all-dists` switched from one to the other immediately
  after changing `*quicklisp-home*`, with zero other calls in between.

  The sync also re-runs `ql:setup`, which is cheap and has two genuinely
  useful side effects beyond the two points above: it creates
  `local-projects/` at the new home if it doesn't already exist there, and
  re-runs any `local-init/*.lisp` files found there — relevant if the two
  environments have different local Quicklisp customizations.

**A note on hand-rolled setup requests.** With this feature in place, a setup
request that used to bootstrap Quicklisp itself — typically an `#-quicklisp
(load ".../setup.lisp")` block guarding a one-time load — no longer needs that
block at all: by the time any request runs, Quicklisp is already loaded and
pointed at the right place if `QUICKLISP_HOME` is set.  Such a request can be
simplified to just the `ql:quickload` calls for whatever systems it
needs. Existing scripts that still carry the old bootstrap block keep working
exactly as before — the `#-quicklisp` guard on that block means it simply
never runs once Quicklisp is already loaded, which after this feature, it
always will be.

**A note on reader safety, for anyone reading `sbcl-bridge.lisp` itself.**
Every Quicklisp-related symbol the bridge touches (`ql:quickload`,
`ql-setup:*quicklisp-home*`, `quicklisp-quickstart:install`, and so on) is
resolved indirectly through `find-package`/`find-symbol` on plain strings,
never written as an ordinary package-qualified symbol like `ql:setup` in the
source text. This is not a style preference: in Common Lisp, a literal
reference to a symbol in a package that doesn't exist is a **reader** error,
not a runtime one — it happens while the file is merely being read, before any
code from it has run. Writing `ql:setup` directly into `sbcl-bridge.lisp`'s
source would make the entire file fail to load on any system where Quicklisp
isn't already present — breaking the bridge for every user, including everyone
who never sets `QUICKLISP_HOME` — rather than failing gracefully only for the
one feature that actually needs it.

**What this doesn't cover.** Anything a setup script itself bakes in as an
absolute path (e.g. a project-specific `local-projects/` symlink target) is
outside what this feature manages — see §8.4's closing note on this same
category of risk. Compiled fasl caches under `XDG_CACHE_HOME`, previously also
in this category, are now handled — see §8.8.

### 8.8 ASDF cache relocation

If `XDG_CACHE_HOME` is set in the environment and ASDF is already loaded in
this image — whether as a side effect of Quicklisp (§8.7), or standalone via a
plain `(require :asdf)` — the bridge makes sure ASDF's compiled-fasl output
cache is pointed at the *current* `XDG_CACHE_HOME` on every `run-bridge`
start, the same way it does for Quicklisp's own home directory.

```bash
export XDG_CACHE_HOME=/workspace/cache
./sbcl-bridge-ctl.sh start
# (nothing logged yet -- ASDF isn't loaded until something requires it)
./sbcl-client.sh eval '(require :asdf)'
./sbcl-bridge-ctl.sh suspend
# ... resume somewhere XDG_CACHE_HOME is /different/cache ...
./sbcl-bridge-ctl.sh resume
# sbcl-output.log:
# ;;; ASDF: XDG_CACHE_HOME changed: /workspace/cache/common-lisp/... -> /different/cache/common-lisp/...
```

**Why this exists.** This surfaced directly from real use of the
`QUICKLISP_HOME`/`XDG_CACHE_HOME` relocation described in §8.7: even with
Quicklisp itself correctly redirected, a resumed bridge kept compiling (or
looking for) fasls under the *old* cache directory. Investigated the same way
as the Quicklisp case — reading ASDF/UIOP's actual source
(`github.com/fare/asdf`, version 3.3.6.2, matching what current SBCL bundles)
rather than assuming — rather than patched around blind.

**What's actually cached, and why fixing it takes two steps, not one.** UIOP's
`uiop/configuration` computes a special variable, `uiop:*user-cache*`, via
`(xdg-cache-home "common-lisp" :implementation)` — reading `XDG_CACHE_HOME`
fresh — but only *once*: either when `uiop/configuration` is first loaded, or,
in UIOP's own dump/restore workflow, via a registered image-restore hook. That
second mechanism is exactly where this breaks down for `sbcl-bridge`: the
function that would re-invoke the hook and refresh `*user-cache*` on a resume,
`uiop:restore-image`, is something a program has to call explicitly from its
*own* `:toplevel` — and `resume-bridge` doesn't; it's a plain custom
`:toplevel` calling `run-bridge` directly, with no dependency on UIOP's
dump/restore machinery. So `*user-cache*` just sits there, stale, exactly like
`ql:*local-project-directories*` did in §8.7.

Worse than the Quicklisp case in one respect, and this was verified directly
rather than assumed, the same way the Quicklisp-home fix was: fixing
`*user-cache*` alone is not enough. ASDF's `asdf/output-translations`
maintains its *own* cache, the actual in-use translation table, computed from
`*user-cache*` the first time `asdf:ensure-output-translations` runs — which
happens automatically inside `asdf:find-system`, i.e. the first time anything
is quickloaded or `asdf:load-system`'d. That computation happens once and is
cached from then on; changing `*user-cache*` afterward, alone, has no effect
on it. Confirmed by direct testing: computing output-translations under one
`XDG_CACHE_HOME`, then changing `XDG_CACHE_HOME` and recomputing
`*user-cache*` alone, still translated a test source path into the *old* cache
directory — only additionally calling `asdf:initialize-output-translations`
actually re-derives the real, in-use translation table from the refreshed
`*user-cache*`. The bridge does both, via the stable, `EXTERNAL`-confirmed
public symbols `uiop:xdg-cache-home`, `uiop:*user-cache*`, and
`asdf:initialize-output-translations` — deliberately not the internal (and
version-fragile) `uiop:compute-user-cache`, which turns out not to even be
exported from the friendly `UIOP` package name at all.

**The comparison that decides whether anything needs fixing is deliberately
not the same one used for `SBCL_HOME`/`QUICKLISP_HOME`.** Those use a
`TRUENAME`-based comparison (`paths-equal-p`) specifically so spelling
differences like a trailing slash don't cause false positives — but `TRUENAME`
requires the path to exist, and the ASDF cache directory routinely doesn't:
ASDF creates it lazily, the first time it actually writes a fasl there, not
when merely computing where one *would* go. A `TRUENAME`-based comparison here
would fail to resolve both sides in that common case and spuriously report a
change on every resume even when `XDG_CACHE_HOME` never moved — caught
directly, the same way the trailing-slash bug in §8.4 was, by actually running
the "nothing changed" case rather than only the "something changed" one. Since
both values being compared come from the identical `uiop:xdg-cache-home` call
(just at different times), a plain pathname `EQUAL` is the correct,
existence-independent comparison, and is what's used instead.

**As with Quicklisp,** every symbol this touches is resolved indirectly
(`dynamic-symbol`/`dynamic-value`/`dynamic-call`, the same helpers §8.7 uses,
promoted to this file's general Helpers section since they're no longer
Quicklisp-specific) rather than written as a literal `asdf:` or `uiop:` symbol
in the source — for the identical reader-error reason: ASDF is not auto-loaded
by SBCL, and plenty of systems never `(require :asdf)` at all.

**What this doesn't cover.** ASDF's `*source-registry*` — where ASDF looks to
*find* systems, as opposed to where it puts compiled output — has an analogous
once-computed cache, checked directly against the source the same way this
section's own findings were, but driven by `CL_SOURCE_REGISTRY`, not
`XDG_CACHE_HOME`. It's not out of scope, exactly — see §8.9, which relocates
it independently, since it's a genuinely separate mechanism with its own
trigger variable, not a side effect of anything above.

### 8.9 `CL_SOURCE_REGISTRY` relocation

If `CL_SOURCE_REGISTRY` is set in the environment and ASDF is already loaded
in this image, the bridge makes sure ASDF's source-registry — where it looks
to *find* systems, independent of Quicklisp entirely — reflects the *current*
`CL_SOURCE_REGISTRY` on every `run-bridge` start, the same way §8.7 and §8.8
relocate Quicklisp's home and ASDF's fasl cache.

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

**Why this is a separate feature, not folded into §8.7 or §8.8.**
`CL_SOURCE_REGISTRY` serves users who never touch Quicklisp at all — a
hand-picked list of local project directories ASDF should search for `.asd`
files, entirely independent of where Quicklisp's own dist-managed systems
live. Making it relocatable is worth doing on its own merits: it's what lets a
coding agent rely on `CL_SOURCE_REGISTRY` for its own project systems without
needing to care whether the bridge happens to move between environments — most
users won't be doing the kind of shared-workspace, cache-portability stress
test that motivated §8.7 and §8.8 in the first place, but plenty rely on
`CL_SOURCE_REGISTRY` regardless, and this makes that reliable too.

**The mechanism, and the two respects in which it differs from §8.8's.**
Investigated identically to the ASDF cache case: ASDF's `asdf/source-registry`
computes a special variable, `asdf:*source-registry*` — a hash table mapping
system names to `.asd` pathnames — the first time anything calls
`asdf:find-system`, via `asdf:ensure-source-registry`. That computation
happens once; `ensure-source-registry` is explicitly documented, in ASDF's own
source comments, as a no-op once `*source-registry*` is already a hash table,
regardless of whether `CL_SOURCE_REGISTRY` has changed since. UIOP's own
mechanism for resetting this before a save — `clear-configuration`, which
`clear-source-registry` is registered against — is wired to an image-*dump*
hook (`uiop:dump-image`'s, specifically), which `resume-bridge`'s plain
`sb-ext:save-lisp-and-die` call never goes through, so it never fires for us —
the same reason the analogous image-*restore* hook never fires for
`uiop:*user-cache*` in §8.8. Confirmed directly, the same way that was: built
two real directories, each with its own trivial `.asd` system, pointed
`CL_SOURCE_REGISTRY` at one, loaded it, then changed `CL_SOURCE_REGISTRY` to
the other and called `ensure-source-registry` again alone — the system that
only existed in the new location was still not found. Only an explicit
`clear-source-registry` followed by `initialize-source-registry` picked it up,
and that's what the bridge does.

Two things differ from the `XDG_CACHE_HOME` case, both worth knowing:

- **No single ASDF-owned variable to compare against.** `uiop:*user-cache*`
  gave §8.8 something to directly compare a freshly-computed value against;
  `*source-registry*` is the computed hash-table *result*, not an input, and
  comparing two hash tables for content-equality is a different (and less
  useful) question than comparing configuration strings. So this bridge keeps
  its own record, `*synced-cl-source-registry*`, of the raw environment string
  last synced against — preserved across suspend/resume like everything else
  baked into the image.

- **No single ASDF-owned variable to compare against.** `uiop:*user-cache*`
  gave §8.8 something to directly compare a freshly-computed value against;
  `*source-registry*` is the computed hash-table *result*, not an input, and
  comparing two hash tables for content-equality is a different (and less
  useful) question than comparing configuration strings. So this bridge keeps
  its own record, `*synced-cl-source-registry*`, of the raw environment string
  last synced against — preserved across suspend/resume like everything else
  baked into the image. That comparison is a plain string `equal`,
  deliberately not `paths-equal-p` (§8.4's truename-based comparison) — and
  not just because `paths-equal-p` requires the path to exist, the reason it
  was wrong for §8.8's cache directory. Here it would be wrong on its own
  terms: `CL_SOURCE_REGISTRY`'s own syntax gives a single trailing slash and a
  double trailing slash different meanings (`:directory` versus `:tree` — see
  the quick-reference callout in §11), so resolving `/foo/` and `/foo//` down
  to the same canonical path, the way `truename` would, would erase a
  distinction ASDF itself treats as meaningful, not merely normalize away an
  incidental spelling difference.

- **That record is deliberately updated regardless of whether ASDF happens to
  be loaded yet.** This one was a real bug caught before shipping, not just a
  theoretical concern: `ensure-cl-source-registry-configured` runs once per
  `run-bridge` start or resume, almost always *before* a user's own request
  has gotten around to loading ASDF at all. An earlier version only recorded
  its baseline when ASDF was already loaded — which, at the one moment this
  function actually runs on an ordinary fresh start, it essentially never is.
  The result: the baseline stayed unset for the entire pre-suspend session
  even though a request loaded ASDF and correctly computed its source-registry
  from that same, unchanged `CL_SOURCE_REGISTRY` moments later — and the
  *next* resume, even with `CL_SOURCE_REGISTRY` completely unchanged, compared
  a real string against that stale unset baseline and reported a spurious
  "changed" every time. Recording the baseline unconditionally — regardless of
  ASDF's load state — and gating only the *fix itself* (not the bookkeeping)
  on ASDF being loaded fixed it. Caught the same way the §8.4 trailing-slash
  bug was: by deliberately testing the "nothing actually changed" case, not
  just the "something changed" one.

**What this doesn't cover.** Quicklisp-managed systems bypass
`*source-registry*` entirely via the search-functions mechanism
`sync-quicklisp-home` already re-registers (§8.7's `ql:setup` call) — this
section is specifically for systems ASDF finds through `CL_SOURCE_REGISTRY`
itself.

---

## 9. Known limitations & caveats

Worth internalizing before you rely on this in production:

- **Single request in flight at a time**, by design. The client blocks until
  it sees its response. Submission is arbitrated by an atomic hard-link (`ln`
  fails if `next-sbcl-input.lisp` already exists), so concurrent callers can
  no longer clobber each other's queued requests — a caller that finds the
  slot busy simply polls until it frees up, within its `SBCL_TIMEOUT`
  budget. There's still no fairness guarantee between many simultaneous
  waiters (whichever `ln` wins the race goes next), and evaluation itself
  remains strictly one request at a time.

- **No sandboxing.** Submitted code runs with the full privileges of the SBCL
  process — filesystem, network, `sb-ext:run-program`, all of it. Presumably
  intentional for a coding-agent tool, but if you want a safety margin, add it
  at the Docker layer (unprivileged user, cgroup memory/CPU limits, restricted
  network namespace) rather than in the bridge itself.

- **No isolation between requests, by design.** Global state — packages,
  `*package*` and other special variables, definitions, loaded systems —
  persists across requests (§2.5). That's the feature; the caveat is that a
  request can leave the environment in a state a later request doesn't expect.

- **Response markers can be spoofed by the code being evaluated.** The
  protocol is plain text on a shared log: evaluated code that prints a line
  like `;;; END-OUTPUT id=<its own id> status=ok` will terminate the waiting
  client's scan early with a forged status (and its remaining real output,
  including the true status line, will be ignored). This can't be fully closed
  with a client-side secret, because the evaluated code can recover its own
  reqid from `sbcl-input.log` or its claimed request file on disk.  Treat
  evaluated code as trusted — which it inherently is anyway given the
  no-sandboxing point above. If an agent evaluates content derived from
  untrusted input (a prompt-injection surface), validate results independently
  rather than trusting the reported `status=` alone.

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
  `SBCL_HOME` restoration lives in the shell script, not the core image itself
  — or if *neither* the sidecar's recorded home *nor* the local sbcl
  installation's home is usable on the resuming machine (resume warns loudly
  in that case). When in doubt, load everything your workload needs in a fresh
  image before suspending (see §8.4).

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
  prove the process is *this* bridge — an unrelated sbcl process that happened
  to recycle the PID would still pass. If you resume from a custom core path,
  keep the `.core` suffix so the check recognizes it; on systems without
  `/proc`, the check degrades to a bare `kill -0`.

- **A fresh Quicklisp install needs real network access to
  `beta.quicklisp.org`** (§8.7). This is only reached as a last resort — if
  `QUICKLISP_LISP`, the Debian/Ubuntu path, or a previously cached download
  already provide a `quicklisp.lisp` installer, no network call happens at all
  — but in a network-restricted container, none of those may apply on the very
  first run. If outbound access to `beta.quicklisp.org` isn't available,
  pre-fetch `quicklisp.lisp` some other way and either point `QUICKLISP_LISP`
  at it or place it at the Debian/Ubuntu path, set `QUICKLISP_INSTALLER_URL`
  to an internal mirror, or install Quicklisp into `QUICKLISP_HOME` by some
  other means entirely before ever starting the bridge — case 2 in §8.7
  (already installed, just needs loading) doesn't touch the network at all.

- **`SB-EXT:RUN-PROGRAM`'s PATH search silently falls through to the next
  candidate if the first one it finds exists but can't actually be executed**
  — a read-only or `noexec`-mounted temp directory is enough to trigger this.
  This isn't specific to Quicklisp support, but it's where it was actually
  found: an early version of `sbcl-bridge-test.sh` tried to force a download
  failure by putting always-failing stand-in `curl`/`wget` scripts earlier on
  `PATH`, which worked on some machines and silently didn't on others — the
  fake binary was found but skipped as unexecutable, and the real `curl`
  further down `PATH` ran instead, quietly succeeding at a real install. This
  is a real, general gotcha worth knowing if you're ever tempted to shadow a
  binary on `PATH` for similar reasons elsewhere.

  The fix that followed — pointing `QUICKLISP_INSTALLER_URL` at an unreachable
  local address instead of hiding the tools — turned out to be necessary but
  not sufficient, which is worth knowing on its own: that variable only
  controls step 4 of the installer search (§8.7) — downloading the bootstrap
  *script*. It has no effect if steps 1–3 already supply one, and a machine
  with Quicklisp's Debian/Ubuntu package installed at the usual system path
  does exactly that, bypassing the override entirely. Worse, even when the
  override *does* apply, it only blocks fetching the script — once any
  installer is in hand, from any source, calling `quicklisp-quickstart:install`
  does its own separate round of network I/O against URLs hardcoded inside
  that script, which nothing here has a hook into. There is no portable,
  machine-independent way to force Quicklisp installation to fail from outside
  it. The smoke test's Quicklisp checks reflect this: rather than asserting
  one specific outcome, they accept either a successful install or a graceful
  failure as correct, and assert the one thing that's actually guaranteed
  either way — the bridge stays usable. A genuine, successful install on a
  machine that has a real path to one isn't a bug to work around; it's this
  feature working as intended.

- **Absolute paths a setup script bakes in on its own are outside anything
  this tooling can see** — e.g. a project-specific `local-projects/` symlink
  target, or a hardcoded path inside your own system definitions. Everything
  this tooling itself controls (the bridge's watched directory, `SBCL_HOME`,
  Quicklisp's home and local-project directories, ASDF's fasl cache, ASDF's
  source-registry) is relocated automatically on resume — see §8.4, §8.7,
  §8.8, §8.9 — but state your *own* code bakes in has no equivalent built-in
  correction.

---

## 10. Troubleshooting

- **`sbcl-client.sh` exits 6 with "No bridge appears to be running" / "Stale
  .sbcl-bridge.pid" / "doesn't look like an sbcl process"**
  - The client's preflight liveness check (§7, step 0) caught the problem
    before ever submitting anything — nothing was evaluated, and nothing was
    lost. Run `ctl.sh status` to see what's actually going on, and `ctl.sh
    start` if nothing is running. The "doesn't look like an sbcl process"
    variant means the pid in `.sbcl-bridge.pid` is alive but isn't `sbcl` —
    almost always a stale pidfile whose original process crashed and whose pid
    the OS has since recycled for something unrelated; `ctl.sh start` (which
    removes a stale pidfile before launching) resolves it.

- **`sbcl-client.sh` exits 7 ("timed out ... waiting for the input slot")**
  - The request was never delivered: another request stayed queued, unclaimed,
    for the whole wait budget. The bridge is alive and busy, not broken —
    raise `SBCL_TIMEOUT`, wait and retry, or `ctl.sh interrupt` whatever's
    occupying it if it shouldn't be taking this long.

- **`sbcl-client.sh` exits 2 ("timed out ... waiting for response")**
  - The request **was** delivered (the client's preflight check already ruled
    out "not running at all", and exit 7 already covers "never got past the
    queue") — this means either the evaluation is still genuinely running, or
    the bridge died *during* the wait (after passing the preflight check but
    before or while processing the request). Raise `SBCL_TIMEOUT` if it's just
    slow, check whether something needs `ctl.sh interrupt`, or run `ctl.sh
    status` to rule out the bridge having died — it'll show `STOPPED` in that
    case.

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
    §8.4 — including the shared-workspace case where the core was suspended on
    a *different machine* (host vs. container) whose sbcl lives at a different
    prefix: `resume` detects that the sidecar's recorded path is unusable here
    and restores the local installation's home instead. If you're still seeing
    it: (1) confirm you resumed via `ctl.sh resume`, not by running the
    `.core` file directly or via `sbcl --core ...` by hand — the restoration
    lives in the shell script; (2) look for the resume-time `WARNING: no
    usable SBCL_HOME found` message, which means neither the sidecar's path
    nor the local sbcl's home exists here with a `contrib/` inside it; (3)
    check whether an inherited `SBCL_HOME` in your environment is pointing
    somewhere stale — a caller-provided value is respected even when it's
    wrong (with a warning). Otherwise, load the failing library before
    suspending next time.

- **A resumed bridge shows `RUNNING` and looks healthy, but requests submitted
  through `sbcl-client.sh` always time out (exit 2), and `sbcl-output.log`
  shows nothing beyond `SBCL-BRIDGE STARTED`**
  - Classic symptom of the resumed bridge watching a different directory than
    the one you're submitting requests to — most often the shared-workspace
    scenario in §8.4's "Moved workspaces": the core was suspended watching one
    path and resumed where that path means something else (or nothing). Check
    the `dir=` value on the `SBCL-BRIDGE STARTED` line in `sbcl-output.log`
    against the `SBCL_BRIDGE_DIR` you're actually submitting requests against
    — if they don't match, either `ctl.sh resume` wasn't given the right
    `SBCL_BRIDGE_DIR` (remember it must be set *before* the `resume` command,
    not just before the `eval` — the directory is fixed for the life of that
    process), or you're running an older build of
    `sbcl-bridge-ctl.sh`/`sbcl-bridge.lisp` predating this override existing
    at all.

- **`(require "UIOP")` (or `ql:quickload`) fails inside a request even though
  `QUICKLISP_HOME` is set correctly**
  - Check `sbcl-output.log` for a `;;; QUICKLISP: ...` line from the most
    recent start or resume (§8.7) — it explains exactly what happened:
    `loaded, home=...` means Quicklisp is ready and this is a different
    problem; `install failed: ...` or `could not find or download a
    quicklisp.lisp installer` means no network reached `beta.quicklisp.org`
    and none of `QUICKLISP_LISP`, the Debian/Ubuntu path, or a cached download
    provided one either — see the network-access limitation in §9.  If you
    don't see any `;;; QUICKLISP:` line at all, `QUICKLISP_HOME` wasn't
    actually set in the environment the bridge process itself was started with
    (double-check it's exported, and exported *before* `ctl.sh
    start`/`resume`, not just before submitting the request).

- **Compiled systems keep rebuilding from source after a resume, or fasls pile
  up in an old, no-longer-relevant directory**
  - Classic symptom of ASDF's fasl cache still pointing at a stale
    `XDG_CACHE_HOME` (§8.8). Check `sbcl-output.log` for a `;;; ASDF:
    XDG_CACHE_HOME changed: ... -> ...` line around the most recent resume —
    if it's there, the relocation happened and this is a different problem; if
    it isn't, either `XDG_CACHE_HOME` wasn't actually set in the environment
    the bridge itself was started/resumed with (same double-check as the
    `QUICKLISP_HOME` entry above), or ASDF was never loaded in this image in
    the first place (nothing to relocate — it'll compute correctly fresh the
    moment something does `(require :asdf)`).

- **`asdf:find-system` can't find a project system after a resume, even though
  `CL_SOURCE_REGISTRY` is set correctly for this environment**
  - Same shape as the previous entry, for ASDF's source-registry instead of
    its fasl cache (§8.9). Check `sbcl-output.log` for a `;;; ASDF:
    CL_SOURCE_REGISTRY changed: ... -> ...` line around the most recent
    resume; if it isn't there, check the same two things as above (actually
    exported before `ctl.sh start`/`resume`, and ASDF actually loaded in this
    image already).

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
export QUICKLISP_HOME=/path/to/quicklisp            # optional; see §8.7
export XDG_CACHE_HOME=/path/to/cache                # optional; see §8.8
export CL_SOURCE_REGISTRY=/path/to/systems//        # optional; see §8.9

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

Client exit codes (§7 has the full contract):

- **0** — ok
- **1** — evaluation error (`status=error`)
- **2** — submitted, but no response within `SBCL_TIMEOUT`
- **3** — bridge-side timeout (`SBCL_REQUEST_TIMEOUT`)
- **4** — cancelled (`ctl.sh interrupt`)
- **5** — fatal non-error condition
- **6** — usage / preflight error — never submitted, fix your setup
- **7** — couldn't submit within `SBCL_TIMEOUT` — bridge just busy, retry
