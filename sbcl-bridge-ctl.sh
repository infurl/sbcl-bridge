#!/usr/bin/env bash
#
# sbcl-bridge-ctl.sh -- start/stop/restart/status, plus suspend/resume,
# for the sbcl-bridge background process. No systemd required; designed
# to work fine inside a plain Docker container.
#
# Usage:
#   sbcl-bridge-ctl.sh start
#   sbcl-bridge-ctl.sh stop        [--force]   # graceful (cancel, then in-Lisp
#                                              # exit) unless --force skips to signals
#   sbcl-bridge-ctl.sh restart                 # stop + FRESH start (no saved state)
#   sbcl-bridge-ctl.sh refresh                 # stop + resume from cores/current.core
#   sbcl-bridge-ctl.sh status
#   sbcl-bridge-ctl.sh suspend     [core-path] [--name NAME]  # --name pins it
#   sbcl-bridge-ctl.sh resume      [core-path-or-name]
#   sbcl-bridge-ctl.sh delete-core <name-or-path> [--force]   # only way to
#                                                              # remove a pinned core
#   sbcl-bridge-ctl.sh interrupt   [reqid]     # cancel the request in flight
#   sbcl-bridge-ctl.sh logs        [-f] [n]    # tail the output log
#   sbcl-bridge-ctl.sh rotate-logs [--force]   # also checked automatically by status
#                                              # (skipped while a request is
#                                              # queued/in flight unless --force)
#
# Environment:
#   SBCL_BRIDGE_DIR       directory the bridge monitors (default: .)
#   SBCL_BRIDGE_LISP      path to sbcl-bridge.lisp (default: alongside this script)
#   SBCL_BIN              sbcl executable (default: sbcl)
#   SBCL_CORE_RETAIN      number of unpinned, non-current core images to keep
#                         (default: 3) -- see `usage` (below) for why actual
#                         disk usage is this many PLUS the current one
#   SBCL_PROCESSED_RETAIN number of archived request files to keep in
#                         processed/ (default: 200; pruned on status)
#   SBCL_STOP_TIMEOUT     seconds to wait per stop escalation phase (default: 10)
#   SBCL_SUSPEND_TIMEOUT  seconds to wait for suspend to finish (default: 60)

set -euo pipefail
shopt -s nullglob

# ---------------------------------------------------------------------
# Configuration

BRIDGE_DIR="${SBCL_BRIDGE_DIR:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_LISP="${SBCL_BRIDGE_LISP:-$SCRIPT_DIR/sbcl-bridge.lisp}"
SBCL_BIN="${SBCL_BIN:-sbcl}"

# Normalize BRIDGE_DIR to an absolute, symlink-resolved path RIGHT HERE,
# before anything below derives a path from it. Every path in this
# script is built by plain string concatenation ("$BRIDGE_DIR/whatever"),
# so any imprecision in BRIDGE_DIR itself -- a caller-supplied
# SBCL_BRIDGE_DIR with its own trailing slash (SBCL_BRIDGE_DIR=/foo/bar/
# is not an unreasonable thing to write), a relative path, "." -- would
# otherwise propagate into every single derived path. Harmless to the
# filesystem itself (a double slash resolves identically to a single
# one on any POSIX system), but it has shown up verbatim in log output
# ("SUSPENDING to /workspace/sbcl-bridge//cores/...") and is exactly
# the kind of avoidable rough edge worth eliminating at the one source
# every other path derives from, rather than re-normalizing (or,
# worse, forgetting to) at each of the many call sites below. There
# used to be a second variable, BRIDGE_DIR_ABS, holding this same
# normalized value for use at just a couple of call sites -- which is
# exactly how this bug happened: everything else in the script kept
# using the un-normalized BRIDGE_DIR. Normalizing BRIDGE_DIR itself,
# once, here, removes the possibility of that mistake entirely: there
# is only one variable now, and it is always already correct.
mkdir -p "$BRIDGE_DIR"
BRIDGE_DIR="$(cd "$BRIDGE_DIR" && pwd)"

PID_FILE="$BRIDGE_DIR/.sbcl-bridge.pid"
OUTPUT_LOG="$BRIDGE_DIR/sbcl-output.log"
INPUT_LOG="$BRIDGE_DIR/sbcl-input.log"
ASYNC_ERROR_LOG="$BRIDGE_DIR/sbcl-async-errors.log"
# Every log rotation/pruning call site loops this array rather than
# naming OUTPUT_LOG/INPUT_LOG/ASYNC_ERROR_LOG individually, so a future
# fourth log only needs to be added here once.
BRIDGE_LOGS=("$OUTPUT_LOG" "$INPUT_LOG" "$ASYNC_ERROR_LOG")
CORE_DIR="$BRIDGE_DIR/cores"
CORE_RETAIN="${SBCL_CORE_RETAIN:-3}"
PROCESSED_DIR="$BRIDGE_DIR/processed"
PROCESSED_RETAIN="${SBCL_PROCESSED_RETAIN:-200}"

LOG_ARCHIVE_DIR="$BRIDGE_DIR/logs"
LOG_MAX_BYTES="${SBCL_LOG_MAX_BYTES:-10485760}"   # 10 MiB
LOG_RETAIN="${SBCL_LOG_RETAIN:-5}"
MEM_WARN_MB="${SBCL_MEM_WARN_MB:-}"

STOP_TIMEOUT="${SBCL_STOP_TIMEOUT:-10}"
SUSPEND_TIMEOUT="${SBCL_SUSPEND_TIMEOUT:-60}"
POLL_INTERVAL=0.3

mkdir -p "$CORE_DIR"
touch "$OUTPUT_LOG"

# ---------------------------------------------------------------------
# Helpers

current_pid() {
  [ -f "$PID_FILE" ] && cat "$PID_FILE" 2>/dev/null || true
}

lisp_string() {
  # Print ARG as a double-quoted Lisp string literal, escaping the two
  # characters (backslash and double-quote) that are special inside
  # one. Used everywhere a shell path is interpolated into --eval code
  # or a generated request, so paths containing " or \ can't break out
  # of the string literal.
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

bridge_busy() {
  # True if a request is queued or currently being evaluated.
  [ -e "$BRIDGE_DIR/next-sbcl-input.lisp" ] || \
  [ -e "$BRIDGE_DIR/next-sbcl-input.working" ]
}

is_running() {
  local pid
  pid="$(current_pid)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # Guard against PID recycling: after a crash or reboot, the recorded
  # pid may have been reused by a completely unrelated process, which a
  # bare kill -0 can't distinguish -- status would claim RUNNING, and
  # stop would SIGTERM an innocent bystander. Verify the process at
  # least looks like our bridge: either the sbcl binary itself (fresh
  # start, or resume via `sbcl --core`) or a saved executable image
  # run directly (whose argv[0] is the *.core path). Custom core paths
  # should therefore keep a .core suffix, as all the defaults and
  # examples do. Where /proc isn't available, fall back to trusting
  # kill -0 as before.
  if [ -r "/proc/$pid/cmdline" ]; then
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE 'sbcl|\.core' || return 1
  fi
  return 0
}

scan_stray_bridges() {
  # Best-effort scan for OTHER live processes that both (a) claim, via
  # their own environment, to be watching this same BRIDGE_DIR, AND (b)
  # look like an sbcl-bridge process by cmdline (mirroring IS_RUNNING's
  # own heuristic) -- an on-demand diagnostic alongside sbcl-bridge.lisp's
  # own startup-time refusal (see CLAIM-PID-FILE), which only guards the
  # moment a bridge starts. This additionally catches strays left over
  # from before that hardening existed, or started by some means other
  # than this script. Purely diagnostic: never kills or touches anything.
  #
  # Both conditions matter: environment variables are inherited across
  # exec/fork, so SBCL_BRIDGE_DIR alone is NOT a reliable signal on its
  # own -- e.g. this very script re-exports it into its own process
  # before backgrounding the bridge, so a bash helper process (this
  # script, one of its own command substitutions, etc.) that happens to
  # be alive at scan time would otherwise be flagged as a "stray bridge"
  # despite not being sbcl at all. Confirmed directly: an earlier version
  # of this check, without the cmdline filter, did exactly that -- and
  # even the cmdline filter alone isn't quite enough: when this script is
  # invoked directly by its own path (rather than as `bash script.sh`),
  # argv[0] IS that path, and "sbcl-bridge-ctl.sh" itself contains the
  # substring "sbcl", so this script's OWN process can satisfy the
  # cmdline check too -- confirmed directly, the same way. Excluding our
  # own PID ($$, not just the bridge's recorded PID) is what actually
  # closes that.
  [ -d /proc ] || return 0
  local self_pid pid envfile
  self_pid="$(current_pid)"
  for envfile in /proc/[0-9]*/environ; do
    [ -r "$envfile" ] || continue
    pid="$(basename "$(dirname "$envfile")")"
    [ "$pid" = "$$" ] && continue
    [ -n "$self_pid" ] && [ "$pid" = "$self_pid" ] && continue
    [ -r "/proc/$pid/cmdline" ] || continue
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE 'sbcl|\.core' || continue
    if tr '\0' '\n' < "$envfile" 2>/dev/null | grep -qxF "SBCL_BRIDGE_DIR=$BRIDGE_DIR"; then
      echo "WARNING: pid $pid also has SBCL_BRIDGE_DIR=$BRIDGE_DIR -- possible duplicate bridge watching this directory." >&2
    fi
  done
  return 0
}

wait_for_exit() {
  # wait_for_exit PID TIMEOUT -- returns 0 if the process exits in time
  local pid="$1" timeout="$2" waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$POLL_INTERVAL"
    waited=$(awk -v w="$waited" -v p="$POLL_INTERVAL" 'BEGIN{printf "%.2f", w+p}')
    if awk -v w="$waited" -v t="$timeout" 'BEGIN{exit !(w>=t)}'; then
      return 1
    fi
  done
  return 0
}

wait_for_start() {
  # wait_for_start TIMEOUT -- polls until IS_RUNNING becomes true, i.e.
  # the just-spawned process has itself written an authoritative PID
  # file (via sbcl-bridge.lisp's CLAIM-PID-FILE) and passed the
  # liveness/identity check -- or TIMEOUT seconds have passed. Returns
  # 0/1 accordingly. Deliberately does NOT trust $! as a placeholder PID
  # in the meantime; see the comment at its call site in cmd_start for
  # why.
  local timeout="$1" waited=0
  while ! is_running; do
    if awk -v w="$waited" -v t="$timeout" 'BEGIN{exit !(w>=t)}'; then
      return 1
    fi
    sleep "$POLL_INTERVAL"
    waited=$(awk -v w="$waited" -v p="$POLL_INTERVAL" 'BEGIN{printf "%.2f", w+p}')
  done
  return 0
}

list_cores_by_age() {
  # newest first, one per line; empty output if none (nullglob is set).
  # Excludes current.core itself: that's a pointer TO one of these
  # files (see UPDATE_CURRENT_CORE_SYMLINK/cmd_refresh), not a core
  # image of its own. Letting it into this glob would corrupt
  # newest-by-mtime ordering -- a symlink's own mtime updates every
  # time it's re-pointed, unrelated to the age of the core it actually
  # points at -- and would let prune_cores try to count or delete it
  # as if it were a real image.
  local files=() f
  for f in "$CORE_DIR"/*.core; do
    [ "$(basename "$f")" = "current.core" ] && continue
    files+=("$f")
  done
  [ ${#files[@]} -eq 0 ] && return 0
  ls -t "${files[@]}"
}

latest_core() {
  list_cores_by_age | head -n1
}

resolve_core_arg() {
  # resolve_core_arg <name-or-path> -- tries, in order: the literal
  # argument as a path, "<name>.core" under cores/ (the default naming
  # a `suspend --name` produces), then the bare argument itself under
  # cores/ (in case a caller already wrote the .core suffix). Lets
  # resume/delete-core accept either a full path (as before) or a bare
  # pinned-core name. Prints nothing (not an error) if none resolve --
  # callers already have their own "no core found" messaging.
  local arg="$1"
  if [ -f "$arg" ]; then
    printf '%s' "$arg"
  elif [ -f "$CORE_DIR/$arg.core" ]; then
    printf '%s' "$CORE_DIR/$arg.core"
  elif [ -f "$CORE_DIR/$arg" ]; then
    printf '%s' "$CORE_DIR/$arg"
  fi
  # Always return 0: under `set -e`, letting the function's exit status
  # track a failed final `elif` test would abort the whole script (via
  # `core_path="$(resolve_core_arg ...)"`) for every ordinary "nothing
  # matched" case -- the same class of bug fixed in core_pinned_name,
  # above.
  return 0
}

core_pinned_name() {
  # core_pinned_name <core-path> -- prints the pinned name if <core-path>
  # has a co-located .pinned sidecar, nothing otherwise. Always returns
  # 0 -- under `set -e`, a bare `[ -f "$marker" ] && cat ...` as the
  # last statement would make the function's own exit status track the
  # test's, aborting the whole script (via `name="$(core_pinned_name
  # ...)"`) for every ordinary, correctly-unpinned core. Confirmed
  # directly: this exact bug truncated `status`'s core listing.
  local marker="$1.pinned"
  if [ -f "$marker" ]; then
    cat "$marker"
  fi
  return 0
}

core_exempt_from_pruning() {
  # core_exempt_from_pruning <core-path> -- T (via exit status) if
  # <core-path> should survive SBCL_CORE_RETAIN's automatic pruning:
  # either it's explicitly pinned (has a .pinned sidecar), or it's what
  # cores/current.core currently resolves to. The second exemption is
  # required for cmd_refresh's own correctness -- without it, `refresh`
  # could end up pointing at a core prune_cores already deleted, e.g.
  # after resuming a deliberately-old, unpinned core that then falls
  # out of the retain window on the next suspend.
  local core_path="$1"
  [ -f "${core_path}.pinned" ] && return 0
  if [ -L "$CORE_DIR/current.core" ]; then
    local current
    current="$(readlink -f "$CORE_DIR/current.core" 2>/dev/null || true)"
    [ -n "$current" ] && [ "$current" = "$(readlink -f "$core_path" 2>/dev/null || echo "$core_path")" ] && return 0
  fi
  return 1
}

update_current_core_symlink() {
  # update_current_core_symlink <core-path> -- points cores/current.core
  # at CORE-PATH (relative symlink, so it survives the whole bridge
  # directory being moved -- same philosophy as the SBCL_BRIDGE_DIR
  # override elsewhere in this script). Called from cmd_suspend (with
  # the just-saved core) and cmd_resume (with whichever core was
  # actually resumed) -- together, these two call sites are what let
  # cmd_refresh return to "the core that was actually live" rather
  # than just "the newest file on disk," which can differ if someone
  # deliberately resumed an older core.
  ln -sfn "$(basename "$1")" "$CORE_DIR/current.core"
}

prune_cores() {
  # Keep the CORE_RETAIN most recent NON-EXEMPT core images; always
  # keep at least one even if CORE_RETAIN was set to 0 by mistake.
  # Pinned cores and whatever cores/current.core points at (see
  # CORE_EXEMPT_FROM_PRUNING) are excluded from this budget entirely --
  # they're never deleted regardless of age or count, and they don't
  # consume a retention slot that would otherwise starve ordinary
  # rotation (e.g. several pinned cores plus CORE_RETAIN=3 still keeps
  # 3 ordinary ones, not zero).
  local keep=$CORE_RETAIN
  [ "$keep" -lt 1 ] && keep=1
  local all=() prunable=() f
  while IFS= read -r f; do
    [ -n "$f" ] && all+=("$f")
  done < <(list_cores_by_age)
  for f in "${all[@]}"; do
    core_exempt_from_pruning "$f" || prunable+=("$f")
  done
  local n=${#prunable[@]}
  if [ "$n" -gt "$keep" ]; then
    local i
    for ((i = keep; i < n; i++)); do
      rm -f "${prunable[$i]}" "${prunable[$i]}.version"
    done
  fi
  # Remove orphaned version sidecars: write-version-sidecar runs BEFORE
  # save-lisp-and-die, so a save that fails partway (e.g. a stray
  # user-spawned thread) leaves foo.core.version behind with no
  # foo.core, and nothing else would ever clean those up.
  local v
  for v in "$CORE_DIR"/*.core.version; do
    [ -e "${v%.version}" ] || rm -f "$v"
  done
}

current_sbcl_info() {
  # Prints two lines: (lisp-implementation-version) and (machine-type),
  # using the same format that write-version-sidecar used at save time.
  # Init files are disabled here for the same determinism reason as in
  # cmd_start -- and more urgently, because a ~/.sbclrc that prints
  # anything would corrupt this exact two-line output and break the
  # version comparison in check_core_compatibility.
  "$SBCL_BIN" --noinform --non-interactive --no-sysinit --no-userinit \
    --eval '(progn (princ (lisp-implementation-version)) (terpri) (princ (machine-type)) (terpri))' \
    2>/dev/null
}

current_sbcl_home() {
  # Ask the CURRENT $SBCL_BIN where its own home directory is (init
  # files disabled so nothing can pollute the single-line output).
  # Prints nothing if sbcl is missing or reports no home.
  "$SBCL_BIN" --noinform --non-interactive --no-sysinit --no-userinit \
    --eval '(let ((h (sb-int:sbcl-homedir-pathname))) (when h (princ (namestring h))))' \
    2>/dev/null
}

valid_sbcl_home() {
  # An SBCL_HOME candidate is usable iff it is a directory containing a
  # contrib/ subdirectory -- that is what REQUIRE of sb-posix, uiop,
  # asdf, etc. actually needs from it.
  [ -n "$1" ] && [ -d "$1" ] && [ -d "${1%/}/contrib" ]
}

normalize_home() {
  # Resolve '..' segments and symlinks for readability (the raw value
  # is typically '<prefix>/bin/../lib/sbcl/'); fall back to the input
  # untouched where readlink -f is unavailable.
  readlink -f "$1" 2>/dev/null || printf '%s' "$1"
}

restore_sbcl_home() {
  # restore_sbcl_home SAVED_VERSION SAVED_MACHINE SAVED_HOME
  #
  # A resumed executable image has no idea where SBCL's contrib modules
  # (sb-posix, uiop, asdf, sb-bsd-sockets, ...) live on disk --
  # (sb-int:sbcl-homedir-pathname) comes back NIL after a resume, since
  # that's normally derived from the location of the running sbcl
  # binary, and the saved image is just a data blob that can be sitting
  # anywhere (typically this bridge's own cores/ directory). Anything
  # that REQUIREs a contrib not already loaded before the suspend would
  # otherwise fail with "Don't know how to REQUIRE ..." even though the
  # exact same code works fine on a fresh start.
  #
  # The sidecar's recorded home is only trustworthy if the resuming
  # environment is the suspending one. In the shared-workspace workflow
  # (suspend on the host, resume the same core inside a container, or
  # vice versa) the recorded '<prefix>/bin/../lib/sbcl/' may not exist
  # here at all -- e.g. a locally built sbcl under /usr/local on one
  # side and the distro package under /usr on the other -- or may exist
  # but hold contrib fasls built by a different SBCL version, which the
  # resumed image cannot load. So every candidate is VALIDATED (exists,
  # has contrib/), and preference depends on whether this environment's
  # sbcl matches the image:
  #
  #   same version+machine  -> prefer the LOCAL installation's home
  #                            (its fasls are guaranteed to match the
  #                            image, wherever it lives), sidecar as
  #                            fallback;
  #   different/unknown     -> prefer the SIDECAR home (the only place
  #                            with matching-version fasls, if it still
  #                            exists here), local home as a last
  #                            resort with a warning.
  #
  # A caller-provided SBCL_HOME always wins, but gets sanity-checked.
  local saved_version="$1" saved_machine="$2" saved_home="$3"
  local current_version="$4" current_machine="$5"

  if [ -n "${SBCL_HOME:-}" ]; then
    if ! valid_sbcl_home "$SBCL_HOME"; then
      echo "WARNING: respecting caller-provided SBCL_HOME=$SBCL_HOME, but it doesn't look like" >&2
      echo "         an SBCL home (missing directory or contrib/ inside it); REQUIRE of" >&2
      echo "         contrib modules will likely fail." >&2
    fi
    return 0
  fi

  local here_home chosen="" origin=""
  here_home="$(current_sbcl_home)"

  if [ -n "$saved_version" ] \
     && [ "$saved_version" = "$current_version" ] \
     && [ "$saved_machine" = "$current_machine" ]; then
    if valid_sbcl_home "$here_home"; then
      chosen="$here_home"; origin="this machine's $SBCL_BIN installation"
    elif valid_sbcl_home "$saved_home"; then
      chosen="$saved_home"; origin="the suspend-time sidecar"
    fi
  else
    if valid_sbcl_home "$saved_home"; then
      chosen="$saved_home"; origin="the suspend-time sidecar"
    elif valid_sbcl_home "$here_home"; then
      chosen="$here_home"
      origin="this machine's $SBCL_BIN installation"
      echo "WARNING: falling back to the local SBCL_HOME even though the local SBCL build" >&2
      echo "         (${current_version:-unknown}) differs from the image's (${saved_version:-unknown});" >&2
      echo "         its contrib fasls may be rejected by the resumed image." >&2
    fi
  fi

  if [ -n "$chosen" ]; then
    local resolved
    resolved="$(normalize_home "$chosen")"
    export SBCL_HOME="$resolved"
    echo "Restoring SBCL_HOME=$SBCL_HOME (from $origin) so contrib modules still REQUIRE correctly."
  else
    echo "WARNING: no usable SBCL_HOME found -- the sidecar recorded '${saved_home:-nothing}'," >&2
    echo "         and the local $SBCL_BIN reports '${here_home:-nothing}'; neither is a" >&2
    echo "         directory with a contrib/ inside it. Contrib modules (sb-posix, uiop," >&2
    echo "         asdf, ...) not already loaded before the suspend will fail to REQUIRE." >&2
  fi
}

check_core_compatibility() {
  local core_path="$1"
  local version_file="${core_path}.version"
  local saved_version="" saved_machine="" saved_home=""
  local current_version="" current_machine=""
  { read -r current_version; read -r current_machine; } < <(current_sbcl_info)

  if [ -f "$version_file" ]; then
    saved_version="$(sed -n '1p' "$version_file")"
    saved_machine="$(sed -n '2p' "$version_file")"
    saved_home="$(sed -n '3p' "$version_file")"
    if [ "$saved_version" != "$current_version" ] || [ "$saved_machine" != "$current_machine" ]; then
      echo "WARNING: $core_path was saved with SBCL $saved_version ($saved_machine)," >&2
      echo "         but $SBCL_BIN here reports $current_version ($current_machine)." >&2
      echo "         Resuming anyway, since it's a self-contained executable image," >&2
      echo "         but this may fail or misbehave if the mismatch is significant." >&2
    fi
  else
    echo "WARNING: no version metadata found for $core_path; cannot verify compatibility" >&2
    echo "         with $SBCL_BIN. Attempting to restore SBCL_HOME from the local" >&2
    echo "         installation instead." >&2
  fi

  restore_sbcl_home "$saved_version" "$saved_machine" "$saved_home" \
                    "$current_version" "$current_machine"
}

# --- Log rotation -------------------------------------------------
#
# The bridge process holds OUTPUT_LOG open for its entire life via
# shell redirection (`>> file`), so a plain rename would leave it
# writing forever into the renamed (now-hidden) file. We use the
# standard "copytruncate" workaround instead: copy the current content
# aside, then truncate the live file in place -- the running process's
# file descriptor still points at the same inode, so new output just
# continues landing in a now-empty sbcl-output.log. This has the usual
# copytruncate caveat: a write landing in the tiny window between the
# copy and the truncate can be lost. INPUT_LOG doesn't strictly need
# this (the bridge reopens it fresh on every write), but treating both
# the same way keeps this simple.

rotate_one_log() {
  # rotate_one_log <path> [--force]
  local path="$1" force="${2:-}"
  [ -f "$path" ] || return 0
  local size
  size=$(wc -c < "$path" 2>/dev/null || echo 0)
  if [ "$force" != "--force" ] && [ "$size" -lt "$LOG_MAX_BYTES" ]; then
    return 0
  fi
  [ "$size" -eq 0 ] && return 0
  mkdir -p "$LOG_ARCHIVE_DIR"
  local base ts dest
  base="$(basename "$path")"
  ts="$(date +%Y%m%d-%H%M%S)"
  dest="$LOG_ARCHIVE_DIR/${base}.${ts}"
  cp "$path" "$dest"
  : > "$path"
  gzip -f "$dest" 2>/dev/null || true
  echo "Rotated $path -> ${dest}.gz (${size} bytes)"
}

prune_logs() {
  # prune_logs <basename-prefix>, e.g. "sbcl-output.log."
  local prefix="$1" keep="$LOG_RETAIN"
  [ "$keep" -lt 1 ] && keep=1
  local files=("$LOG_ARCHIVE_DIR/${prefix}"*.gz)
  local n=${#files[@]}
  if [ "$n" -gt "$keep" ]; then
    local sorted=()
    while IFS= read -r line; do sorted+=("$line"); done < <(ls -t "${files[@]}")
    local i
    for ((i = keep; i < n; i++)); do
      rm -f "${sorted[$i]}"
    done
  fi
}

prune_processed() {
  # The bridge archives every request it has ever handled into
  # processed/ (as <reqid>.lisp, plus the occasional error-*.lisp /
  # leftover-*.lisp) and nothing bridge-side ever deletes them, so an
  # agent hammering the bridge would accumulate files without bound.
  # Keep the PROCESSED_RETAIN most recent; enforce keeping at least 1,
  # mirroring prune_cores. Piggybacked on status the same way log
  # rotation is, so anything polling status keeps this bounded too.
  local keep=$PROCESSED_RETAIN
  [ "$keep" -lt 1 ] && keep=1
  local files=("$PROCESSED_DIR"/*.lisp)
  local n=${#files[@]}
  if [ "$n" -gt "$keep" ]; then
    local sorted=() line i
    while IFS= read -r line; do sorted+=("$line"); done < <(ls -t "${files[@]}")
    for ((i = keep; i < n; i++)); do
      rm -f "${sorted[$i]}"
    done
  fi
}

check_and_rotate_logs() {
  # Size-triggered rotation; safe to call often (e.g. from status).
  #
  # Never rotate while a request is queued or in flight: a waiting
  # sbcl-client.sh remembers the log offset it started scanning from,
  # and truncating the live log underneath it would (a) move an
  # already-written-but-not-yet-read response into the archive where
  # the client will never look, and (b) leave the client's offset past
  # EOF. (The client now also detects truncation and rescans from the
  # top, but that only helps for responses written AFTER the truncate;
  # skipping rotation while busy is what actually protects in-flight
  # responses.) The next status call on an idle bridge rotates as usual.
  if bridge_busy; then
    return 0
  fi
  local log
  for log in "${BRIDGE_LOGS[@]}"; do
    rotate_one_log "$log"
    prune_logs "$(basename "$log")."
  done
}

# ---------------------------------------------------------------------
# Commands

cmd_start() {
  if is_running; then
    echo "Already running (pid $(current_pid))."
    return 0
  fi
  rm -f "$PID_FILE"
  [ -f "$BRIDGE_LISP" ] || { echo "Cannot find $BRIDGE_LISP (set SBCL_BRIDGE_LISP)" >&2; exit 1; }

  echo "Starting fresh sbcl-bridge, watching $BRIDGE_DIR ..."
  # Export SBCL_BRIDGE_DIR into the bridge's own environment too, even
  # though run-bridge is given :directory explicitly below and doesn't
  # need it: this makes "a running bridge's environment has an accurate
  # SBCL_BRIDGE_DIR" a reliable invariant regardless of whether it was
  # freshly started or resumed (see cmd_resume), which matters if
  # user-submitted code -- e.g. a setup script wanting to resolve
  # workspace-relative paths itself -- reads it directly via
  # (sb-ext:posix-getenv "SBCL_BRIDGE_DIR"). BRIDGE_DIR is already
  # normalized (absolute, symlink-resolved) as of the top of this
  # script, so this is correct as-is with no further resolution needed.
  export SBCL_BRIDGE_DIR="$BRIDGE_DIR"
  # --no-sysinit --no-userinit: never load /etc/sbclrc or ~/.sbclrc.
  # The bridge must behave identically in a bare container and on a
  # developer desktop; a stray userinit that loads Quicklisp, changes
  # *print-* settings, or just prints something would make evaluation
  # results (and the marker-parsing client) environment-dependent.
  # Anything an init file would have provided can be loaded explicitly
  # as an ordinary first request instead (e.g. a quicklisp-loader.lisp
  # submitted via sbcl-client.sh), which also means it's captured in
  # the input log and survives suspend/resume as image state.
  setsid "$SBCL_BIN" --non-interactive --no-sysinit --no-userinit \
      --load "$BRIDGE_LISP" \
      --eval "(sbcl-bridge:run-bridge :directory $(lisp_string "$BRIDGE_DIR/"))" \
      < /dev/null >> "$OUTPUT_LOG" 2>&1 &
  disown "$!" 2>/dev/null || true
  # Deliberately NOT writing $! into PID_FILE as a placeholder here, the
  # way earlier versions of this script did: `setsid CMD` can silently
  # refork rather than exec CMD in place (see the extensive comment on
  # this in sbcl-bridge.lisp's run-bridge, above its own
  # SB-UNIX:UNIX-GETPID call), meaning $! sometimes names a short-lived
  # wrapper process rather than the actual bridge -- and now that
  # RUN-BRIDGE's own CLAIM-PID-FILE is the sole, authoritative writer of
  # this file (see sbcl-bridge.lisp), a placeholder written here first
  # would race against it: CLAIM-PID-FILE would find that placeholder
  # already present, and -- since the exporting shell put the same
  # SBCL_BRIDGE_DIR in the wrapper's environment too -- could even
  # mistake it for a second, conflicting bridge and refuse to start at
  # all. Instead, just wait for the bridge to claim the file for itself,
  # the same way sbcl-client.lisp's BRIDGE-START already does.
  if wait_for_start 5; then
    echo "Started (pid $(current_pid))."
  else
    echo "Failed to start; check $OUTPUT_LOG" >&2
    exit 1
  fi
}

drop_stop_request() {
  # Same file-drop idiom cmd_interrupt uses for cancel-request: a
  # mktemp-then-atomic-rename so a concurrent reader never sees a
  # partially-written file.
  local tmp
  tmp="$(mktemp "$BRIDGE_DIR/.stop-request.XXXXXX")"
  : > "$tmp"
  mv -f "$tmp" "$BRIDGE_DIR/stop-request"
}

cmd_stop() {
  local force="${1:-}"
  if ! is_running; then
    echo "Not running."
    rm -f "$PID_FILE"
    return 0
  fi
  local pid
  pid="$(current_pid)"

  if [ "$force" = "--force" ]; then
    # Escape hatch: skip straight past the graceful file-drop mechanism
    # entirely. Needed because sb-thread:interrupt-thread delivery
    # requires the target thread to reach a safepoint -- tight,
    # non-consing native code (or code running without-interrupts) on
    # the main thread can stall delivery indefinitely, in which case the
    # graceful phases below would just eat into the timeout budget
    # before falling back to this same signal-based path anyway.
    echo "Stopping pid $pid (--force: skipping graceful shutdown) ..."
  else
    echo "Stopping pid $pid ..."
    # Phase 1: if a request is in flight, ask it to cancel first and
    # give its own client a moment to observe status=cancelled before
    # the process disappears out from under it. Reuses the exact same
    # cancel-request mechanism `interrupt` already uses -- no separate,
    # independent way to reach into a running eval.
    if bridge_busy; then
      cmd_interrupt "" || true
      local cancel_wait
      cancel_wait=$(awk -v t="$STOP_TIMEOUT" 'BEGIN{print (t<5)?t:5}')
      local waited=0
      while bridge_busy; do
        sleep "$POLL_INTERVAL"
        waited=$(awk -v w="$waited" -v p="$POLL_INTERVAL" 'BEGIN{printf "%.2f", w+p}')
        awk -v w="$waited" -v t="$cancel_wait" 'BEGIN{exit !(w>=t)}' && break
      done
    fi
    # Phase 2: graceful in-Lisp exit, whether the bridge just went idle
    # above or was already idle to begin with -- the watchdog checks
    # stop-request unconditionally, unlike cancel-request.
    drop_stop_request
    if wait_for_exit "$pid" "$STOP_TIMEOUT"; then
      echo "Stopped."
      rm -f "$PID_FILE" "$BRIDGE_DIR/stop-request"
      return 0
    fi
    echo "Did not exit gracefully within ${STOP_TIMEOUT}s; sending SIGTERM."
  fi

  # Phase 3 (or, with --force, the only phase): signal-based, as before
  # this escalation existed.
  kill -TERM "$pid" 2>/dev/null || true
  if wait_for_exit "$pid" "$STOP_TIMEOUT"; then
    echo "Stopped."
  else
    echo "Did not exit within ${STOP_TIMEOUT}s; sending SIGKILL."
    kill -KILL "$pid" 2>/dev/null || true
    wait_for_exit "$pid" 5 || true
  fi
  rm -f "$PID_FILE" "$BRIDGE_DIR/stop-request"
}

cmd_restart() {
  cmd_stop
  cmd_start
}

cmd_status() {
  if is_running; then
    local pid etime rss_kb vsz_kb
    pid="$(current_pid)"
    etime="$(ps -o etime= -p "$pid" 2>/dev/null | xargs || true)"
    read -r rss_kb vsz_kb < <(ps -o rss=,vsz= -p "$pid" 2>/dev/null | xargs || echo "0 0")
    rss_kb="${rss_kb:-0}"; vsz_kb="${vsz_kb:-0}"
    local rss_mb=$((rss_kb / 1024)) vsz_mb=$((vsz_kb / 1024))
    echo "RUNNING (pid=$pid, uptime=${etime:-unknown})"
    echo "Memory: RSS=${rss_mb}MB VSZ=${vsz_mb}MB"
    if [ -n "$MEM_WARN_MB" ] && [ "$rss_mb" -gt "$MEM_WARN_MB" ]; then
      echo "WARNING: RSS (${rss_mb}MB) exceeds SBCL_MEM_WARN_MB (${MEM_WARN_MB}MB)." >&2
    fi
  else
    echo "STOPPED"
    [ -f "$PID_FILE" ] && rm -f "$PID_FILE"
  fi

  scan_stray_bridges

  local files=()
  while IFS= read -r line; do
    [ -n "$line" ] && files+=("$line")
  done < <(list_cores_by_age)
  if [ ${#files[@]} -gt 0 ]; then
    echo "Saved core images (newest first):"
    local f pname annotation pinned_count=0
    for f in "${files[@]}"; do
      annotation=""
      pname="$(core_pinned_name "$f")"
      if [ -n "$pname" ]; then
        annotation="  [named: $pname]"
        pinned_count=$((pinned_count + 1))
      fi
      ls -l "$f" | awk -v ann="$annotation" '{printf "  %8d bytes  %s %s %s  %s%s\n", $5, $6, $7, $8, $9, ann}'
    done
    if [ "$pinned_count" -gt 0 ]; then
      echo "Named/pinned cores: $pinned_count (exempt from SBCL_CORE_RETAIN pruning; delete-core to remove)"
    fi
  else
    echo "No saved core images."
  fi
  if [ -L "$CORE_DIR/current.core" ]; then
    echo "Current (last resumed/suspended): $(readlink "$CORE_DIR/current.core")"
  fi

  local log_size_out log_size_in log_size_async
  log_size_out=$([ -f "$OUTPUT_LOG" ] && wc -c < "$OUTPUT_LOG" || echo 0)
  log_size_in=$([ -f "$INPUT_LOG" ] && wc -c < "$INPUT_LOG" || echo 0)
  log_size_async=$([ -f "$ASYNC_ERROR_LOG" ] && wc -c < "$ASYNC_ERROR_LOG" || echo 0)
  echo "Logs: sbcl-output.log=$((log_size_out / 1024))KB sbcl-input.log=$((log_size_in / 1024))KB sbcl-async-errors.log=$((log_size_async / 1024))KB"

  # Computed BEFORE check_and_rotate_logs below, so this reflects what's
  # actually accumulated since the last rotation, not a near-zero count
  # right after this same call rotates it away.
  if [ -f "$ASYNC_ERROR_LOG" ]; then
    local n_async
    n_async=$(grep -c '^;;; ASYNC-ERROR ' "$ASYNC_ERROR_LOG" 2>/dev/null || echo 0)
    if [ "$n_async" -gt 0 ]; then
      echo "WARNING: $n_async async error(s) recorded in sbcl-async-errors.log (background-thread faults, main bridge unaffected)." >&2
    fi
  fi

  local n_processed=0
  local pfiles=("$PROCESSED_DIR"/*.lisp)
  n_processed=${#pfiles[@]}
  echo "Processed archive: $n_processed request file(s) (retention: $PROCESSED_RETAIN)"

  # Piggyback cheap housekeeping here so logs and the processed/
  # archive stay bounded even without an external cron/timer --
  # anything that polls status periodically (health checks, an agent
  # loop) keeps rotation and pruning happening for free.
  check_and_rotate_logs
  prune_processed
}

cmd_suspend() {
  if ! is_running; then
    echo "Not running; nothing to suspend." >&2
    exit 1
  fi
  local name="" core_path_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)
        name="${2:-}"
        shift 2
        ;;
      *)
        core_path_arg="$1"
        shift
        ;;
    esac
  done
  if [ -n "$name" ]; then
    case "$name" in
      *[!a-zA-Z0-9_-]*)
        echo "Invalid --name '$name': use only letters, digits, '-', '_'." >&2
        exit 1
        ;;
    esac
  fi

  local pid ts core_path reqid
  pid="$(current_pid)"
  ts="$(date +%Y%m%d-%H%M%S)"
  if [ -n "$core_path_arg" ]; then
    core_path="$core_path_arg"
  elif [ -n "$name" ]; then
    core_path="$CORE_DIR/$name.core"
  else
    core_path="$CORE_DIR/bridge-$ts.core"
  fi
  reqid="suspend-$ts-$$"

  echo "Requesting suspend to $core_path ...${name:+ (named: $name)}"
  local tmp
  tmp="$(mktemp "$BRIDGE_DIR/.next-sbcl-input.XXXXXX")"
  {
    printf ';;; REQID: %s\n' "$reqid"
    # Saving a large heap (full GC + image write) can legitimately take
    # longer than the bridge's default per-request timeout; disable it
    # for this request and let SBCL_SUSPEND_TIMEOUT below be the only
    # limit.
    printf ';;; TIMEOUT: none\n'
    if [ -n "$name" ]; then
      printf '(sbcl-bridge:suspend-bridge :core-path %s :name %s)\n' \
             "$(lisp_string "$core_path")" "$(lisp_string "$name")"
    else
      printf '(sbcl-bridge:suspend-bridge :core-path %s)\n' \
             "$(lisp_string "$core_path")"
    fi
  } > "$tmp"
  # Atomic claim of the input slot: ln fails if a request is already
  # queued, with no window between check and submission (the previous
  # probe-then-mv could clobber a request queued in between).
  if ! ln "$tmp" "$BRIDGE_DIR/next-sbcl-input.lisp" 2>/dev/null; then
    rm -f "$tmp"
    echo "A request is already queued in next-sbcl-input.lisp; try again shortly." >&2
    exit 1
  fi
  rm -f "$tmp"

  if wait_for_exit "$pid" "$SUSPEND_TIMEOUT"; then
    if [ -s "$core_path" ]; then
      chmod +x "$core_path" 2>/dev/null || true
      echo "Suspended. Core image saved: $core_path"
      rm -f "$PID_FILE"
      update_current_core_symlink "$core_path"
      prune_cores
    else
      echo "Process exited but core image is missing/empty: $core_path" >&2
      exit 1
    fi
  else
    echo "Process did not exit within ${SUSPEND_TIMEOUT}s; suspend did not complete." >&2
    # Don't leave the suspend request armed: if it is still queued
    # (i.e. a long-running request is in flight and the bridge hasn't
    # claimed it yet), withdraw it -- otherwise the bridge would
    # save-and-exit by surprise whenever the current request finishes,
    # long after this command reported failure.
    if [ -f "$BRIDGE_DIR/next-sbcl-input.lisp" ] && \
       grep -qF "REQID: $reqid" "$BRIDGE_DIR/next-sbcl-input.lisp" 2>/dev/null; then
      rm -f "$BRIDGE_DIR/next-sbcl-input.lisp"
      echo "The suspend request was still queued behind an in-flight request;" >&2
      echo "it has been withdrawn -- the bridge will NOT suspend later." >&2
    else
      echo "The suspend request was already claimed and may still complete;" >&2
      echo "check status and $OUTPUT_LOG before assuming the bridge stayed up." >&2
    fi
    exit 1
  fi
}

cmd_resume() {
  if is_running; then
    echo "Already running (pid $(current_pid))."
    return 0
  fi
  local core_path
  if [ -n "${1:-}" ]; then
    core_path="$(resolve_core_arg "$1")"
  else
    core_path="$(latest_core)"
  fi
  if [ -z "$core_path" ] || [ ! -f "$core_path" ]; then
    echo "No core image to resume from (looked in $CORE_DIR)." >&2
    exit 1
  fi
  rm -f "$PID_FILE"

  check_core_compatibility "$core_path"

  echo "Resuming from $core_path ..."
  # Export SBCL_BRIDGE_DIR explicitly for the child, rather than
  # relying on it already being set (and exported) in this shell's
  # environment: the resumed image reads it (see resume-bridge in
  # sbcl-bridge.lisp) to correct a directory baked in at suspend time
  # that may no longer be valid here -- e.g. a shared workspace mounted
  # at a different path in a container than on the host it was
  # suspended from. BRIDGE_DIR is already normalized (absolute,
  # symlink-resolved) as of the top of this script -- rather than, say,
  # the relative default "." -- so the override is correct regardless
  # of the resumed process's own working directory, and doing this
  # unconditionally (rather than only when SBCL_BRIDGE_DIR was
  # explicitly set by the caller) means a user who never touches
  # SBCL_BRIDGE_DIR at all still gets a consistent, correct, absolute
  # value on the Lisp side.
  export SBCL_BRIDGE_DIR="$BRIDGE_DIR"
  if [ -x "$core_path" ]; then
    setsid "$core_path" < /dev/null >> "$OUTPUT_LOG" 2>&1 &
  else
    setsid "$SBCL_BIN" --core "$core_path" < /dev/null >> "$OUTPUT_LOG" 2>&1 &
  fi
  disown "$!" 2>/dev/null || true
  # See the matching comment in cmd_start: deliberately not writing a
  # placeholder PID file here either, for the identical setsid-refork /
  # CLAIM-PID-FILE-race reason.
  if wait_for_start 5; then
    echo "Resumed (pid $(current_pid))."
    update_current_core_symlink "$core_path"
  else
    echo "Failed to resume; check $OUTPUT_LOG" >&2
    exit 1
  fi
}

cmd_refresh() {
  # stop + resume, but -- unlike restart, which is stop + FRESH start --
  # remembering which core was actually live rather than just grabbing
  # the newest file on disk by mtime (those can differ if someone
  # deliberately resumed an older core; see UPDATE_CURRENT_CORE_SYMLINK).
  local target=""
  if [ -L "$CORE_DIR/current.core" ]; then
    target="$(readlink -f "$CORE_DIR/current.core" 2>/dev/null || true)"
  fi
  if [ -z "$target" ] || [ ! -f "$target" ]; then
    echo "Nothing to refresh: no current-core symlink (this bridge directory" >&2
    echo "has only ever been freshly started, never suspended or resumed)." >&2
    echo "Use 'start' for a fresh image, or 'resume [core-path]' explicitly." >&2
    exit 1
  fi
  cmd_stop
  cmd_resume "$target"
}

cmd_delete_core() {
  # delete-core <name-or-path> [--force] -- the only way a pinned core
  # is ever removed (prune_cores deliberately never touches one). Also
  # works on unpinned/anonymous cores, by path or by their timestamp
  # "name". Refuses, without --force, to delete whatever the running
  # bridge (if any) was actually started from -- best-effort: compares
  # against /proc/<pid>/cmdline, which names the core path directly for
  # a resume via the executable core itself, or via `sbcl --core PATH`.
  local arg="" force=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force="--force" ;;
      *) arg="$1" ;;
    esac
    shift
  done
  if [ -z "$arg" ]; then
    echo "Usage: $(basename "$0") delete-core <name-or-path> [--force]" >&2
    exit 1
  fi
  local core_path
  core_path="$(resolve_core_arg "$arg")"
  if [ -z "$core_path" ] || [ ! -f "$core_path" ]; then
    echo "No core found matching '$arg' (looked in $CORE_DIR)." >&2
    exit 1
  fi
  if [ "$force" != "--force" ] && is_running; then
    local pid; pid="$(current_pid)"
    if [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$core_path"; then
      echo "Refusing to delete $core_path: the running bridge (pid $pid) appears to" >&2
      echo "have been started from it. Stop the bridge first, or pass --force." >&2
      exit 1
    fi
  fi
  local name; name="$(core_pinned_name "$core_path")"
  rm -f "$core_path" "${core_path}.version" "${core_path}.pinned"
  echo "Deleted $core_path${name:+ (was named: $name)}."
}

cmd_interrupt() {
  if ! is_running; then
    echo "Not running." >&2
    exit 1
  fi
  local target="${1:-}"
  local tmp
  tmp="$(mktemp "$BRIDGE_DIR/.cancel-request.XXXXXX")"
  printf '%s' "$target" > "$tmp"
  mv -f "$tmp" "$BRIDGE_DIR/cancel-request"
  if [ -n "$target" ]; then
    echo "Cancellation requested for id=$target."
  else
    echo "Cancellation requested for whatever request is currently running."
  fi
  echo "(No-op if nothing is running, or if the running request doesn't match.)"
}

cmd_logs() {
  # logs [-f] [N] -- print the last N lines (default 50) of the output
  # log, or follow it live with -f. Purely a convenience over tail(1):
  # it resolves the right file for this SBCL_BRIDGE_DIR so you don't
  # have to remember/compose the path.
  local follow="" n=50 arg
  for arg in "$@"; do
    case "$arg" in
      -f) follow=1 ;;
      *[!0-9]*|'') echo "Usage: $(basename "$0") logs [-f] [lines]" >&2; exit 1 ;;
      *) n="$arg" ;;
    esac
  done
  [ -f "$OUTPUT_LOG" ] || { echo "No output log yet at $OUTPUT_LOG" >&2; exit 1; }
  if [ -n "$follow" ]; then
    exec tail -n "$n" -f "$OUTPUT_LOG"
  else
    tail -n "$n" "$OUTPUT_LOG"
  fi
}

cmd_rotate_logs() {
  local force="${1:-}"
  if [ "$force" = "--force" ]; then
    # --force rotates even while a request is in flight -- it's meant
    # for maintenance windows and must also work if a stale .working
    # file is lying around. Warn, though: a client waiting on the
    # rotated log will have to rely on its truncation detection, and a
    # response already written but not yet read moves to the archive.
    if bridge_busy; then
      echo "WARNING: a request is queued or in flight; forcing rotation anyway." >&2
      echo "         A client currently waiting on the log may lose its response." >&2
    fi
    local log
    for log in "${BRIDGE_LOGS[@]}"; do
      rotate_one_log "$log" --force
      prune_logs "$(basename "$log")."
    done
  else
    if bridge_busy; then
      echo "A request is queued or in flight; skipping rotation (use --force to override)."
      return 0
    fi
    check_and_rotate_logs
  fi
}

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") {start|stop [--force]|restart|status|suspend [core-path] [--name NAME]|resume [core-path-or-name]|refresh|delete-core <name-or-path> [--force]|interrupt [reqid]|rotate-logs [--force]|logs [-f] [lines]}

Environment:
  SBCL_BRIDGE_DIR       directory the bridge monitors (default: .)
  SBCL_BRIDGE_LISP      path to sbcl-bridge.lisp (default: alongside this script)
  SBCL_BIN              sbcl executable (default: sbcl)
  SBCL_CORE_RETAIN      number of UNPINNED, non-current core images to
                        keep (default: 3) -- named/pinned cores (see
                        suspend --name) and whatever cores/current.core
                        points at are exempt and don't count against
                        this budget, so steady-state disk usage is
                        this many PLUS the current one, not exactly this
  SBCL_PROCESSED_RETAIN number of archived request files to keep in
                        processed/ (default: 200; pruned on status)
  SBCL_STOP_TIMEOUT     seconds to wait per escalation phase before
                        moving to the next one (default: 10)
  SBCL_SUSPEND_TIMEOUT  seconds to wait for suspend to finish (default: 60)
  SBCL_LOG_MAX_BYTES    rotate a log once it exceeds this size (default: 10MiB)
  SBCL_LOG_RETAIN       number of rotated (gzipped) log generations to keep (default: 5)
  SBCL_MEM_WARN_MB      if set, status warns when RSS exceeds this many MB

stop escalates gracefully: cancel any in-flight request, then ask the
image to exit cleanly (via a stop-request file the bridge's watchdog
thread checks whether idle or busy), only falling back to SIGTERM then
SIGKILL if that doesn't work within SBCL_STOP_TIMEOUT. Worst-case
latency is therefore up to roughly 2*SBCL_STOP_TIMEOUT+10s in the fully
wedged case, versus SBCL_STOP_TIMEOUT+5s before this escalation
existed. Use --force to skip straight to SIGTERM/SIGKILL, e.g. if the
bridge's watchdog thread is itself wedged (interrupt-thread delivery
needs a safepoint; tight native/non-consing code on the main thread can
stall it indefinitely).

suspend --name NAME saves to cores/NAME.core (instead of the default
timestamp name) and marks it pinned: exempt from SBCL_CORE_RETAIN's
automatic pruning, deletable only via delete-core. resume and
delete-core both accept a bare NAME in place of a full core path.

refresh is stop + resume from cores/current.core -- the core that was
actually live before the stop, not necessarily the newest file on disk
(those differ if you explicitly resumed an older core). Compare
restart, which is stop + a FRESH start with no saved state. Errors out
if there's no current-core symlink yet (a bridge directory that's only
ever done a plain start, never suspended or resumed).

interrupt cancels whatever request is currently being evaluated (or a
specific one, by reqid). It has no effect once a request has already
finished, and does not itself stop/restart the bridge process.

logs prints the last N lines (default 50) of sbcl-output.log for this
SBCL_BRIDGE_DIR, or follows it live with -f.

rotate-logs is checked automatically (cheaply) every time status runs,
so an agent or health check polling status keeps logs bounded for
free. Rotation is skipped while a request is queued or in flight, so a
waiting client never has the log truncated out from under it. Use
--force to rotate immediately regardless of current size or busyness,
e.g. right before a maintenance window (a client waiting at that
moment may lose its response).
EOF
  exit 1
}

[ $# -ge 1 ] || usage
case "$1" in
  start)       cmd_start ;;
  stop)        shift; cmd_stop "${1:-}" ;;
  restart)     cmd_restart ;;
  status)      cmd_status ;;
  suspend)     shift; cmd_suspend "$@" ;;
  resume)      shift; cmd_resume "${1:-}" ;;
  refresh)     cmd_refresh ;;
  delete-core) shift; cmd_delete_core "$@" ;;
  interrupt)   shift; cmd_interrupt "${1:-}" ;;
  rotate-logs) shift; cmd_rotate_logs "${1:-}" ;;
  logs)        shift; cmd_logs "$@" ;;
  *) usage ;;
esac
