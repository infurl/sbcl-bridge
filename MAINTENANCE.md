# SBCL Bridge: maintenance notes

Design rationale, theory of operation, and every bug found building this,
for whoever is changing this code rather than just using it. For usage,
see [README.md](README.md).

## Why this exists

Swank (the protocol behind SLIME/SLY) is designed for interactive debugging
from an editor: it's stateful, bidirectional, and layers a lot of its own
messaging on top of whatever you actually wanted to evaluate. That's exactly
wrong for a tool harness, where something like a coding agent just wants to
say "run this code" and get back "here's what happened" — cleanly,
synchronously, and without needing to speak a debugger protocol.

SBCL Bridge instead uses the simplest mechanism that works reliably in a
container with no REPL, no TTY, and no systemd: **plain files**, with a
background loop watching a directory.

## Theory of operation

### The core idea

A single SBCL process runs forever, executing `sbcl-bridge:run-bridge`
instead of an interactive REPL. That function polls a directory for a
specific filename. When a caller wants code evaluated, it writes the code to
a temp file in the same directory, then atomically hard-links it to
`next-sbcl-input.lisp` (`ln` on the same filesystem — the bridge never sees
a half-written file, and, because `ln` *fails* if the target already
exists, a request that's queued but not yet claimed is never overwritten;
the client just waits for the slot).

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

### Why polling instead of inotify

Polling (every 0.2s by default) is simpler, has no extra library dependency,
and is cheap enough that the overhead is irrelevant next to how long an actual
Lisp evaluation takes. `inotify` would shave milliseconds off best-case
latency at the cost of an extra dependency and more moving parts — not a good
trade for this use case.

### Why `--non-interactive` doesn't cause the process to exit

Normally `sbcl --non-interactive` runs your `--load`/`--eval` forms and
exits. That's fine here, because `run-bridge` **never returns** under normal
operation — it's an infinite loop. There's no REPL reading from stdin that
could hit EOF and quit; the process only ever stops via `sbcl-bridge-ctl.sh
stop`'s graceful escalation (cancel any in-flight request, then a dropped
`stop-request` file the loop itself checks for an in-Lisp exit, falling back
to `SIGTERM` and finally `SIGKILL` only if a phase doesn't finish within
`SBCL_STOP_TIMEOUT`) or by explicitly calling `suspend-bridge`.

## Internal design notes worth knowing

- **Single-threaded evaluation, one watchdog thread.** All actual code
  evaluation happens on the bridge's main thread. A second "bridge-watchdog"
  thread runs alongside it purely to watch for the `cancel-request` control
  file and, when needed, asynchronously interrupt the main thread.
- **Bridge output is serialized by a recursive lock.** SBCL streams aren't
  thread-safe, and both the main thread and the watchdog write to
  `*standard-output*`, so every bridge-emitted line is written under one
  shared lock. The lock is *recursive* because a cancellation interrupt can
  land on the main thread while it already holds the lock mid-line; the
  unwinding handler then re-acquires it to print its own lines — a plain
  mutex would self-deadlock there. What *evaluated code* prints is
  deliberately not locked, so a request's own prints can still theoretically
  interleave with a watchdog one-liner — but bridge lines can no longer
  garble each other.
- **`handler-bind`, not `handler-case`, around evaluation.** `handler-case`
  unwinds the stack *before* running its handler body — which would make
  backtrace capture useless. `handler-bind` runs its handler in the original
  signalling context, stack intact, which is what makes real backtraces
  meaningful.
- **A debugger-hook backstop, installed twice.** SBCL's own default behavior
  on a truly unhandled condition in `--non-interactive` mode is already to
  print a backtrace and exit rather than hang — but the bridge installs its
  own hook so that if something ever escapes all of the normal handling
  (which would be a bug), the log still records which request was active
  before the process exits. Installed in *both* `cl:*debugger-hook*` and
  `sb-ext:*invoke-debugger-hook*` since the precise consultation order
  between the two has shifted across SBCL versions.
- **Quicklisp support never references a Quicklisp symbol directly.**
  `ql:quickload`, `ql-setup:*quicklisp-home*`, `quicklisp-quickstart:install`
  and everything else Quicklisp-related is resolved at runtime via
  `find-package`/`find-symbol` on plain strings. A literal package-qualified
  symbol referencing a package that doesn't exist is a **reader** error in
  Common Lisp — it would happen while `sbcl-bridge.lisp` itself is being
  loaded, before any code runs, breaking the bridge for every user regardless
  of whether they ever set `QUICKLISP_HOME`. String-based resolution defers
  that lookup until the package is known to exist (or gracefully handles it
  not existing at all).

## `ctl.sh`'s exit-code philosophy, and why it differs from the client's

`ctl.sh` uses `0`/`1` uniformly across every subcommand — the conventional
shell-tool convention (like `git`, `docker`, `systemctl`), not the
finely-subdivided scheme `sbcl-client.sh` uses. This is a deliberate
difference, not an oversight: `ctl.sh` is a lifecycle tool whose callers are
humans and `Makefile`/`docker` orchestration that branch on "did this
succeed", with the specific reason always in the stderr message.
`sbcl-client.sh`, by contrast, runs in the hot path of an agent's
request/response loop, where the caller genuinely needs to distinguish
outcomes programmatically (`retry` vs. `give up` vs. `treat as an evaluation
error`) without parsing text — which is what earns its exit codes a fully
enumerated, disjoint contract.

## Deep dives

### Cancellation: how it works

A background "bridge-watchdog" thread (started alongside the main loop)
polls for a small control file (`cancel-request`). When it appears, the
watchdog checks whether its target (blank = "whatever's current", or a
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

### Condition handling & backtraces: why this matters, and three layers of protection

A coding agent will, by the nature of what it's doing, frequently submit
code that doesn't work. The bridge needs to survive that indefinitely, and
the error report needs to be useful enough for the agent to fix its own
mistake without another round trip.

1. **Comprehensive condition catching.** `STORAGE-CONDITION` (heap/stack
   exhaustion — notably *not* a subtype of `ERROR` in ANSI Common Lisp) and
   any other `SERIOUS-CONDITION` are also caught per-request, so a single
   catastrophic request — including a real stack overflow from unbounded
   recursion — can't silently take the whole process down. Confirmed by
   deliberately blowing the control stack in testing: caught cleanly,
   reported as `status=fatal-condition`, bridge still serving requests
   immediately after.
2. **Backtrace capture**, via `handler-bind` *before* the stack unwinds.
   Also **filtered**: it stops as soon as it reaches the bridge's own
   internal machinery (frames for `run-forms`, `eval-and-report`, and
   everything below them are never useful to someone debugging their own
   submitted code). If the (unexported, and thus not permanently
   guaranteed-stable) SBCL internals this filtering relies on are ever
   unavailable, it falls back automatically to an unfiltered
   `sb-debug:print-backtrace`.
3. **`*debugger-hook*` backstop.** If something somehow still escapes all of
   the above (which would indicate a real gap), the hook logs the active
   request id and a note before the process exits, rather than the process
   hanging in a debugger prompt with no terminal attached to answer it.

**Backtrace implementation history, worth knowing if you're touching this
area again:** backtraces come from `sb-debug:print-backtrace`, a stable,
exported SBCL API. An earlier version of this codebase instead hand-walked
frames via the unexported `sb-debug::map-backtrace`/
`sb-debug::print-frame-call`, filtering out bridge-internal frames by
searching each one's printed text for the substring `"SBCL-BRIDGE"` — that
approach was retired after being found, empirically, to silently produce an
*empty* backtrace whenever this file was loaded whole via `--load` (i.e. on
every normal bridge startup), while the identical code worked fine compiled
standalone. Root cause not tracked down (some interaction between
whole-file compilation and `map-backtrace`'s own stack walk);
`print-backtrace` was simply confirmed to work correctly in exactly the case
that was failing, and is simpler besides — its own `:count` already bounds
output length, and the retired substring filter never actually matched
anything in the first place (`print-frame-call` renders frame text without
package qualification, so `"SBCL-BRIDGE"` could never appear in it).

### Suspend & resume: how it works, and four real bugs

`sb-ext:save-lisp-and-die` snapshots the entire heap and then terminates the
process. Crucially, it does *not* resume execution from wherever you called
it — on reload, execution always restarts from a designated top-level entry
point. `suspend-bridge` takes advantage of this by pointing that entry point
(`:toplevel`) at `resume-bridge`, a small wrapper that calls `run-bridge`
again using the poll-interval/timeout/backtrace-frames settings that were
cached in global variables when the bridge started, so resuming re-enters
the exact same polling loop with no `--load`/`--eval` flags needed — except
for the watched directory, which is instead taken from the resuming
process's own `SBCL_BRIDGE_DIR` environment variable when one is set (see
"Moved workspaces" below). The saved image is a fully self-contained
executable (`:executable t :save-runtime-options t`) — resuming it is just
running the file; that same flag also means an `--eval`-based override is
not merely unnecessary but flatly impossible, since `:save-runtime-options
t` makes the executable refuse to parse *any* runtime option (including
`--eval`) when run directly. Reading the environment from ordinary Lisp code
after the runtime has already started is the one mechanism that works
regardless of invocation style.

**Practical mechanics:**

- `suspend` is itself submitted through the normal request pipeline, so it
  naturally queues behind anything already in flight rather than
  interrupting it — submitted with the same atomic hard-link technique the
  client uses, so `ctl.sh suspend` fails cleanly, with no race window, if
  another request is already queued.
- **A timed-out `suspend` is withdrawn, not left armed.** If the process
  hasn't exited within `SBCL_SUSPEND_TIMEOUT`, `ctl.sh suspend` reports
  failure *and removes the suspend request if it's still queued* —
  otherwise the bridge would save-and-exit by surprise whenever the
  in-flight request eventually finished, long after the command reported
  failure. If the bridge has already claimed the suspend request by then,
  `ctl.sh` says so instead.
- `save-lisp-and-die` refuses to run while other threads are alive.
  `suspend-bridge` stops the watchdog thread first automatically.
- **Version metadata.** A sidecar file (`<core-path>.version`) records
  `(lisp-implementation-version)`, `(machine-type)`, and
  `(sb-int:sbcl-homedir-pathname)` at save time.
- **No leftovers from a normal suspend.** `suspend-bridge` archives its own
  `next-sbcl-input.working` under its reqid immediately before saving, as
  the very last step — if anything earlier in `suspend-bridge` fails, the
  request errors out through the normal path with its working file still in
  place.

**Contrib modules and `SBCL_HOME` — the one genuinely surprising gotcha in
the whole system.** A resumed executable image has **no idea where SBCL's
contrib modules live on disk** — `(sb-int:sbcl-homedir-pathname)` comes back
`NIL` in a resumed image, because that value is normally derived from the
location of the *running sbcl binary itself*, and a saved image is just a
data blob that can be executed from anywhere. Anything that calls
`cl:require` for a contrib that wasn't already loaded *before* the suspend
will fail with `Don't know how to REQUIRE ...` after a resume, even though
the exact same code works perfectly on a fresh `start`.

`write-version-sidecar` records the home directory in effect at save time
(normalized via `truename`, falling back to the `SBCL_HOME` this process was
itself resumed with, so the record survives chains of suspend/resume
cycles), and `ctl.sh resume` restores a home into the `SBCL_HOME`
environment variable before launching. Crucially, the recorded value is
**not trusted blindly**: the machine that suspended the core may not be the
machine resuming it — the canonical case is a shared-workspace workflow
(suspend on the host, resume the identical core inside a container, or vice
versa) where the two sides' `sbcl` binaries live at different prefixes.
`resume` therefore *validates* every candidate (the directory must exist and
contain `contrib/`) and picks by provenance: if the local `sbcl`'s build
matches the image's, the local installation's home is preferred, with the
sidecar as fallback; if the builds differ, the sidecar's home is preferred
(the only place with matching-version fasls, if it still exists), with the
local home as a warned-about last resort. A caller-provided `SBCL_HOME`
always wins but is sanity-checked, and if nothing validates, `resume` says
so loudly instead of exporting a dead path.

The more robust practice, when it's an option: load everything your
workload needs *before* suspending — once a contrib is loaded into the
image, its code is baked into the heap and never needs to be found on disk
again after a resume.

**Moved workspaces: `SBCL_BRIDGE_DIR` on resume.** The directory the bridge
watches is baked into a suspended image too, as `*bridge-directory*`,
precisely so a resume needs no arguments. In a shared-workspace workflow (a
host and a container mounting the same directory at *different* paths), a
core suspended on one side and resumed on the other would, without
correction, come back healthy, running, and watching a directory that
doesn't exist (or is wrong) on the resuming side — every request submitted
there would simply never be seen, with no error anywhere.

`resume-bridge` corrects for this the same way `SBCL_HOME` is corrected: if
the resuming process's own environment has a non-empty `SBCL_BRIDGE_DIR`,
that directory is used instead of the one saved in the image, and a `;;;
RESUME: SBCL_BRIDGE_DIR=... overrides ...` line is logged. `ctl.sh resume`
always exports `SBCL_BRIDGE_DIR` for the child it launches — as an absolute,
symlink-resolved path, computed once via `cd "$BRIDGE_DIR" && pwd` —
regardless of whether the caller's own shell happened to export it.
`ctl.sh start` exports the same thing for a fresh bridge, so whatever
directory a *future* suspend bakes in is itself this same absolute, correct
path, keeping the chain accurate across arbitrarily many suspend/resume
cycles and moves.

**Four bugs found fixing this area, each worth knowing:**

1. Naively coercing a directory string into a pathname in Common Lisp is a
   real trap. `"/workspace"` (no trailing slash) parses as a file *named*
   `workspace`, not a directory, and a plausible-looking fix using
   `merge-pathnames` to coerce it back into a directory pathname does
   **not** actually work — `merge-pathnames`'s component-substitution rule
   pulls the stray name back in regardless. Left uncaught, every path the
   bridge computes from such a directory silently loses its last path
   segment, and the bridge ends up watching (and writing logs into) the
   *parent* of the intended directory — a corruption that produces no
   error, just a bridge that looks healthy and never sees any requests.
   `ensure-directory-pathname` now performs the coercion correctly (by
   reconstructing the name and type as an explicit final directory
   component), and every directory argument in the bridge goes through it.
2. The check for *whether* to apply the `SBCL_BRIDGE_DIR` override
   originally compared it against the directory saved in the image as raw
   strings, which routinely differ in spelling even when they name the
   exact same directory (a fresh `start` bakes in a trailing slash;
   `SBCL_BRIDGE_DIR` for a `resume` comes from a plain `pwd`, which never
   has one). Effect: resuming into the *same* directory a fresh start had
   just used printed a spurious override line — confusing, and doubly so
   because it then went away on every *subsequent* resume, since that first
   spurious override overwrote the saved directory with the no-trailing-
   slash spelling. Fixed by going through the same `paths-equal-p`
   (truename-based) comparison used for the analogous `SBCL_HOME`/
   Quicklisp-home comparisons.
3. Found via a log line in production — `;;; SUSPENDING to
   /workspace/sbcl-bridge//cores/bridge-....core` — `SBCL_BRIDGE_DIR` with a
   trailing slash used to propagate that trailing slash into every path
   both scripts derive from it, since each was built by plain string
   concatenation directly from whatever the caller supplied. Harmless to
   the filesystem, but an avoidable rough edge that a previous, narrower fix
   had only partially addressed. Both scripts now normalize the directory
   to an absolute, symlink-resolved path exactly once, immediately, before
   anything else derives a path from it.
4. One thing that turned out **not** to need any fix, verified directly
   rather than assumed: `*default-pathname-defaults*` is not preserved
   across a resume the way the bridge's own state is — SBCL resets it to
   the resuming process's actual working directory at every startup, saved
   image or not.

**One category of moved-image risk this tooling can't fix**: anything a
setup script bakes in as an absolute path outside of Quicklisp's home and
ASDF's fasl cache (both relocated automatically) — a project-specific
`local-projects/` symlink target, or a hardcoded path inside your own system
definitions. Either make sure such paths resolve identically in every
environment that will resume the image, or re-run the setup script fresh
after resuming somewhere new.

### Log rotation: how it works, and why it has to work this way

The bridge process holds `sbcl-output.log` open for its *entire* lifetime
via shell redirection (`>> sbcl-output.log`). If you simply `mv` that file
aside, the running process's file descriptor keeps writing into the same
underlying inode — now sitting under the renamed name — forever; a fresh
`sbcl-output.log` you create afterward would just sit empty. This is the
standard "copytruncate" problem, and the standard workaround: copy the
current contents aside (gzipped, into `logs/`), then truncate the
*original* file in place. The running process's descriptor still points at
that same inode, so its next write lands cleanly in what is now an empty
file. Verified directly: submitted a request, rotated, submitted another —
the second response landed in the freshly truncated live log, not the
rotated copy.

Rotation is skipped while a request is queued or in flight: truncating the
live log at that moment would strand a waiting `sbcl-client.sh`, since the
client remembers the byte offset it started scanning from and a response
written before the rotation would be carried off into the archive. As a
second line of defense, the client itself detects truncation and rescans
from the top if the log is ever smaller than its recorded offset. The one
accepted caveat (shared with real `logrotate` in copytruncate mode): a
write landing in the small window between the copy and the truncate can be
lost — vanishingly small in practice, since rotation doesn't run mid-request
unless forced.

`sbcl-input.log` doesn't strictly need copytruncate (the bridge reopens it
fresh via `with-open-file` on every single write), but it's rotated the
same way for consistency.

### Quicklisp integration: why this exists, the three cases, and the sync mechanism

**Why this exists.** Quicklisp turned out to have exactly the same
moved-image problem as `SBCL_HOME` and the bridge's own watched directory —
a shared workspace mounted at different paths in different environments
means `QUICKLISP_HOME` can legitimately differ between a suspend and a
resume — but with a sharper edge: getting it wrong doesn't fail loudly, it
fails by `ql:quickload` quietly reading from (or writing to) the wrong
directory. Building this into the bridge means every request-time script
can just assume Quicklisp is already correctly configured for whatever
`QUICKLISP_HOME` says right now.

**Three cases, all handled by the same `ensure-quicklisp-configured` call:**

1. **Nothing installed at `QUICKLISP_HOME` yet.** The bridge attempts a
   fresh install, locating a `quicklisp.lisp` bootstrap installer by
   checking, in order: `QUICKLISP_LISP` (an env var naming its exact path);
   the Debian/Ubuntu package path; a copy already cached from a previous
   run at `<bridge-directory>/quicklisp-installer.lisp`; and, only if all of
   those come up empty, a fresh download via `curl`/`wget` into that same
   cache location, from `https://beta.quicklisp.org/quicklisp.lisp` by
   default or `QUICKLISP_INSTALLER_URL` if set. Downloaded to a temp file
   and renamed into place atomically, so an interrupted download never
   leaves a broken file to be mistaken for a good one.
2. **Already installed, but not yet loaded in this image.** An ordinary
   `(load ".../setup.lisp")`.
3. **Already loaded in this image (a resume where Quicklisp was loaded
   before suspend).** If `QUICKLISP_HOME` now names a *different* directory
   than what's baked into the image, the already-loaded client is
   redirected there rather than reloaded.

Every step is best-effort and defensive: nothing here is allowed to prevent
the bridge from starting or reaching its main loop. A failure at any point
is logged with a `;;; QUICKLISP: ...` line, and the bridge continues
normally. The very next resume or restart gets another chance.

**The sync, and why it's not just one `setf`.** Redirecting an already-
loaded Quicklisp client to a new `QUICKLISP_HOME` is not simply `(setf
ql:*quicklisp-home* new-path)`, verified directly against the actual
Quicklisp client source rather than assumed:

- `ql:*local-project-directories*` is a Quicklisp-internal `defparameter`,
  computed *once*, at load time. Left alone, it keeps pointing at the old
  `local-projects/` forever, no matter what `*quicklisp-home*` is set to
  afterward. The bridge resets it explicitly alongside the home directory.
- Dist objects, reassuringly, need **no** equivalent fix — `ql-dist:all-
  dists` rebuilds dist objects from scratch, via `qmerge`, on *every single
  call*. Verified by building two independent fake dists in two separate
  fake `QUICKLISP_HOME` trees and confirming `ql-dist:all-dists` switched
  immediately after changing `*quicklisp-home*`.
- The sync also re-runs `ql:setup` (cheap), which creates `local-projects/`
  at the new home if missing and re-runs any `local-init/*.lisp` there.

**A note on hand-rolled setup requests.** A setup request that used to
bootstrap Quicklisp itself (typically an `#-quicklisp (load
".../setup.lisp")` guard) no longer needs that block: by the time any
request runs, Quicklisp is already loaded and pointed at the right place if
`QUICKLISP_HOME` is set. Existing scripts that still carry the old guard
keep working exactly as before, since the guard simply never fires once
Quicklisp is already loaded.

**What this doesn't cover.** Anything a setup script itself bakes in as an
absolute path is outside what this feature manages — see "Suspend & resume"
above.

### ASDF cache relocation: mechanism, and why it's two steps not one

**Why this exists.** This surfaced directly from real use of the Quicklisp
relocation above: even with Quicklisp itself correctly redirected, a
resumed bridge kept compiling (or looking for) fasls under the *old* cache
directory. Investigated by reading ASDF/UIOP's actual source
(`github.com/fare/asdf`, version 3.3.6.2) rather than assuming.

**What's actually cached, and why fixing it takes two steps.** UIOP's
`uiop/configuration` computes `uiop:*user-cache*` via `(xdg-cache-home
"common-lisp" :implementation)` — reading `XDG_CACHE_HOME` fresh — but only
*once*, either when `uiop/configuration` is first loaded or, in UIOP's own
dump/restore workflow, via a registered image-restore hook. That second
mechanism is exactly where this breaks down for `sbcl-bridge`: the function
that would refresh `*user-cache*` on a resume, `uiop:restore-image`, is
something a program has to call explicitly from its *own* `:toplevel` —
and `resume-bridge` doesn't; it's a plain custom `:toplevel` calling
`run-bridge` directly. So `*user-cache*` just sits there, stale.

Worse than the Quicklisp case, verified directly the same way: fixing
`*user-cache*` alone is not enough. ASDF's `asdf/output-translations`
maintains its *own* cache, the actual in-use translation table, computed
from `*user-cache*` the first time `asdf:ensure-output-translations` runs
(automatically inside `asdf:find-system`). That computation happens once
and is cached from then on; changing `*user-cache*` afterward, alone, has
no effect on it. Confirmed by computing output-translations under one
`XDG_CACHE_HOME`, then changing it and recomputing `*user-cache*` alone —
still translated to the *old* cache directory. Only additionally calling
`asdf:initialize-output-translations` re-derives the real, in-use
translation table. The bridge does both, via the stable, public symbols
`uiop:xdg-cache-home`, `uiop:*user-cache*`, and
`asdf:initialize-output-translations` — deliberately not the internal (and
version-fragile) `uiop:compute-user-cache`, which turns out not to even be
exported from `UIOP` at all.

**The comparison that decides whether anything needs fixing is deliberately
not the truename-based one used for `SBCL_HOME`/`QUICKLISP_HOME`** —
`TRUENAME` requires the path to exist, and the ASDF cache directory
routinely doesn't (ASDF creates it lazily, the first time it actually
writes a fasl there). A `TRUENAME`-based comparison here would fail to
resolve both sides in that common case and spuriously report a change on
every resume even when `XDG_CACHE_HOME` never moved — caught directly by
actually running the "nothing changed" case, not just the "something
changed" one. Since both values being compared come from the identical
`uiop:xdg-cache-home` call (just at different times), a plain pathname
`EQUAL` is the correct, existence-independent comparison used instead.

**What this doesn't cover.** ASDF's `*source-registry*` has an analogous
once-computed cache, but driven by `CL_SOURCE_REGISTRY`, not
`XDG_CACHE_HOME` — a genuinely separate mechanism with its own trigger
variable, relocated independently (see below).

### `CL_SOURCE_REGISTRY` relocation: why separate, and the mechanism

**Why this is a separate feature, not folded into Quicklisp or the ASDF
cache.** `CL_SOURCE_REGISTRY` serves users who never touch Quicklisp at
all — a hand-picked list of local project directories ASDF should search
for `.asd` files, entirely independent of where Quicklisp's own
dist-managed systems live. Most users won't be doing the kind of
shared-workspace, cache-portability stress test that motivated the
Quicklisp/ASDF-cache relocations, but plenty rely on `CL_SOURCE_REGISTRY`
regardless.

**The mechanism, and two respects in which it differs from the ASDF cache
case.** ASDF's `asdf/source-registry` computes `asdf:*source-registry*` — a
hash table mapping system names to `.asd` pathnames — the first time
anything calls `asdf:find-system`, via `asdf:ensure-source-registry`. That
computation happens once; `ensure-source-registry` is explicitly documented,
in ASDF's own source comments, as a no-op once `*source-registry*` is
already a hash table, regardless of whether `CL_SOURCE_REGISTRY` has
changed since. UIOP's own reset mechanism (`clear-configuration`) is wired
to an image-*dump* hook, which `resume-bridge`'s plain
`sb-ext:save-lisp-and-die` call never goes through — the same reason the
analogous image-*restore* hook never fires for `uiop:*user-cache*`.
Confirmed directly: built two real directories, each with its own trivial
`.asd` system, pointed `CL_SOURCE_REGISTRY` at one, loaded it, then changed
`CL_SOURCE_REGISTRY` to the other and called `ensure-source-registry` again
alone — the system that only existed in the new location was still not
found. Only an explicit `clear-source-registry` followed by
`initialize-source-registry` picked it up.

Two things differ from the `XDG_CACHE_HOME` case:

- **No single ASDF-owned variable to compare against.** `*source-registry*`
  is the computed hash-table *result*, not an input, so this bridge keeps
  its own record, `*synced-cl-source-registry*`, of the raw environment
  string last synced against — preserved across suspend/resume like
  everything else baked into the image.
- **That record is deliberately updated regardless of whether ASDF happens
  to be loaded yet.** A real bug caught before shipping:
  `ensure-cl-source-registry-configured` runs once per `run-bridge` start or
  resume, almost always *before* a user's own request has loaded ASDF at
  all. An earlier version only recorded its baseline when ASDF was already
  loaded — which, at the one moment this function actually runs on an
  ordinary fresh start, it essentially never is. Result: the baseline
  stayed unset for the entire pre-suspend session even though a request
  loaded ASDF and correctly computed its source-registry from that same,
  unchanged `CL_SOURCE_REGISTRY` moments later — and the *next* resume,
  even with `CL_SOURCE_REGISTRY` completely unchanged, compared a real
  string against that stale unset baseline and reported a spurious
  "changed" every time. Recording the baseline unconditionally — regardless
  of ASDF's load state — and gating only the *fix itself* on ASDF being
  loaded fixed it. Caught the same way the trailing-slash bug above was: by
  deliberately testing the "nothing actually changed" case, not just the
  "something changed" one.

**What this doesn't cover.** Quicklisp-managed systems bypass
`*source-registry*` entirely via the search-functions mechanism
`sync-quicklisp-home` already re-registers — this section is specifically
for systems ASDF finds through `CL_SOURCE_REGISTRY` itself.

## Known limitations & caveats: the maintainer-relevant ones

(See README.md for the user-relevant subset.)

- **`suspend` failing under long-uptime thread churn — root cause.**
  `deinit` (called by `save-lisp-and-die`) walks
  `*joinable-threads*`/`*all-threads*`, lock-free structures the SBCL
  maintainers' own source comments flag as susceptible to an ABA race
  under high thread churn — exactly the pattern a long-lived Hunchentoot
  server (or any thread-per-task workload) produces. Confirmed
  reproducible on every retry against the same affected process (not a
  one-off race), and confirmed **not** fixed by stopping every application
  thread first, `(sb-ext:gc :full t)`, or a `sleep` before retrying —
  `(sb-thread:list-all-threads)` already showed only the main thread every
  time. A closely related (not identical) symptom on a Hunchentoot server
  was confirmed and fixed by an SBCL core developer on sbcl-help back in
  2020/2.1.x; no bug-tracker entry matching this exact `THREAD-P THREAD`
  text was found, so this may be an unreported resurgence in the same
  subsystem. The SBCL manual's own more general answer to "how do I save
  from a live server without killing it" is forking a clean child process
  to do the save instead — not implemented here, since restart-then-suspend
  already covers the actual common use pattern (periodic snapshots, not
  zero-downtime saves).
- **PID-file identity check is a heuristic for `status`/`stop`'s purposes,
  stronger but still not airtight at startup.** They verify the recorded
  PID looks like the bridge (command line matching `sbcl` or `*.core`),
  which defeats ordinary PID recycling for their purposes but can't
  positively prove the process is *this* bridge; on systems without
  `/proc`, it degrades to a bare `kill -0`. `run-bridge` itself uses a
  stronger check at startup — before claiming (or refusing to claim) an
  existing PID file, it reads `/proc/<pid>/environ` and compares
  `SBCL_BRIDGE_DIR` directly, correctly distinguishing "another live bridge
  watching this same directory" from "a recycled PID belonging to something
  unrelated" — falling back to the weaker cmdline heuristic only if
  `/proc/<pid>/environ` itself is unreadable.
- **The startup duplicate-bridge guard narrows the launch race, it doesn't
  eliminate it.** Two processes racing to start a bridge against the same
  directory can each still get as far as spawning a full SBCL process
  before either reaches the PID-file claim inside `run-bridge` — the loser
  self-terminates within its first startup instead of running forever
  (closing the actual failure mode: two bridges both polling the same
  request queue indefinitely), but a brief double-spawn window remains. A
  fully rigorous fix would need a lifetime-held OS-level lock (`flock` via
  `sb-posix`), which conflicts with `sbcl-bridge.lisp`'s deliberate
  zero-contrib-dependency design (it uses `sb-unix:unix-getpid` instead of
  `sb-posix:getpid`) — judged not worth trading away for this, since the
  narrowed race is already far cheaper to hit than the original unbounded
  one.
- **A fresh Quicklisp install needs real network access to
  `beta.quicklisp.org`**, only reached as a last resort. If outbound access
  isn't available, pre-fetch `quicklisp.lisp` some other way and either
  point `QUICKLISP_LISP` at it, place it at the Debian/Ubuntu path, set
  `QUICKLISP_INSTALLER_URL` to an internal mirror, or install Quicklisp by
  some other means entirely before ever starting the bridge.
- **`SB-EXT:RUN-PROGRAM`'s PATH search silently falls through to the next
  candidate if the first one it finds exists but can't actually be
  executed** — a read-only or `noexec`-mounted temp directory is enough to
  trigger this. Found via an early version of `sbcl-bridge-test.sh` that
  tried to force a download failure by putting always-failing stand-in
  `curl`/`wget` scripts earlier on `PATH`: worked on some machines and
  silently didn't on others, since the fake binary was found but skipped as
  unexecutable, and the real `curl` further down `PATH` ran instead,
  quietly succeeding at a real install. A real, general gotcha worth
  knowing if you're ever tempted to shadow a binary on `PATH` for similar
  reasons elsewhere.

  The fix that followed — pointing `QUICKLISP_INSTALLER_URL` at an
  unreachable local address instead of hiding the tools — turned out to be
  necessary but not sufficient: that variable only controls the last step
  of the installer search (downloading the bootstrap *script*), has no
  effect if earlier steps already supply one, and even when it does apply,
  it only blocks fetching the script — once any installer is in hand,
  `quicklisp-quickstart:install` does its own separate round of network I/O
  against URLs hardcoded inside that script, which nothing here has a hook
  into. There is no portable, machine-independent way to force Quicklisp
  installation to fail from outside it. The smoke test's Quicklisp checks
  reflect this: rather than asserting one specific outcome, they accept
  either a successful install or a graceful failure as correct, and assert
  the one thing that's actually guaranteed either way — the bridge stays
  usable.

## `sbcl-client.lisp`: two real bugs found building it

Every function in this library was verified against a *real* running
bridge, not just loaded and assumed correct — including proving
interoperability in both directions: a bridge started with
`sbcl-bridge-ctl.sh` was suspended, resumed, evaluated against, and
interrupted from this library, and a bridge started from this library was
equally readable and controllable from `sbcl-bridge-ctl.sh`/
`sbcl-client.sh`, across several alternating hops. That process caught two
real, non-obvious bugs:

- **`setsid CMD` does not always preserve `CMD`'s PID across the exec.**
  `setsid(2)` requires its caller not already be a process group leader;
  when it *is* — which, confirmed directly, depends on how the immediate
  parent set up the child before exec (`SB-EXT:RUN-PROGRAM`'s child setup
  triggers this; a plain shell background job typically does not) — the
  `setsid` *utility* silently forks a new child to work around that
  restriction rather than exec-ing in place, so a PID captured from the
  call that invoked `setsid` (bash's `$!`, or `SB-EXT:PROCESS-PID`) can end
  up naming the now-exited wrapper, not the bridge. The fix is
  architectural, not local to this file: `sbcl-bridge.lisp`'s `run-bridge`
  now writes its own PID file as its first action, before anything else, so
  no launcher — shell or Lisp — needs to correctly guess its PID across an
  `execve` chain at all. This benefits `sbcl-bridge-ctl.sh` too, even though
  bash's own `$!` was confirmed *not* actually affected by this in testing.
- **`CL:RENAME-FILE`'s second argument merges against the first argument's
  pathname components for anything it doesn't explicitly specify** — the
  exact same class of trap `ensure-directory-pathname` documents at length
  for `MERGE-PATHNAMES` generally (see "Suspend & resume," above),
  independently rediscovered here: renaming a `.tmp` file to a bare
  `cancel-request` (no dot, so it parses with a `NIL` type) silently
  renamed it to `cancel-request.tmp` instead, since the `NIL` type was
  treated as unspecified and inherited the source's `.tmp`.
  `sb-posix:rename` on plain namestrings sidesteps CL pathname-merging
  semantics entirely, the same way `sb-posix:link` already does for atomic
  submission.
