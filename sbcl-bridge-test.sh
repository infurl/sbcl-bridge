#!/usr/bin/env bash
#
# sbcl-bridge-test.sh -- end-to-end smoke test for the bridge.
#
# Spins up a throwaway bridge in a temp directory, exercises every
# major behavior (evaluation, errors/backtraces, timeouts,
# cancellation, request queueing, log-rotation safety, suspend/resume
# including contrib REQUIRE after a resume, fatal conditions), prints
# PASS/FAIL per check, and exits 0 only if everything passed.
#
# Run it after upgrading SBCL, or before publishing changes to the
# bridge itself:
#
#   ./sbcl-bridge-test.sh
#
# Environment:
#   SBCL_BIN          sbcl executable to test against (default: sbcl)
#   SBCL_BRIDGE_LISP  bridge source (default: alongside this script)
#
# Takes roughly 20-30 seconds. Cleans up after itself (stops the
# bridge, removes the temp directory) even on failure or ^C.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$SCRIPT_DIR/sbcl-bridge-ctl.sh"
CLIENT="$SCRIPT_DIR/sbcl-client.sh"

export SBCL_BRIDGE_DIR
SBCL_BRIDGE_DIR="$(mktemp -d)"
export SBCL_BRIDGE_LISP="${SBCL_BRIDGE_LISP:-$SCRIPT_DIR/sbcl-bridge.lisp}"

PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# expect_exit <description> <expected-exit-code> <cmd...>
expect_exit() {
  local desc="$1" want="$2" got
  shift 2
  "$@" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    ok "$desc"
  else
    bad "$desc (exit $got, expected $want)"
  fi
}

cleanup() {
  "$CTL" stop >/dev/null 2>&1 || true
  rm -rf "$SBCL_BRIDGE_DIR"
}
trap cleanup EXIT

echo "== sbcl-bridge smoke test =="
echo "SBCL:       $("${SBCL_BIN:-sbcl}" --version 2>/dev/null || echo 'NOT FOUND')"
echo "Bridge dir: $SBCL_BRIDGE_DIR"
echo

# Plant a canary userinit in a fake HOME: if the bridge (or the version
# probe used by resume) ever loads init files again, the canary defines
# a variable and prints to the log, and the checks below catch it.
export HOME="$SBCL_BRIDGE_DIR/fakehome"
mkdir -p "$HOME"
cat > "$HOME/.sbclrc" <<'RCEOF'
(format t "SMOKE-CANARY: USERINIT LOADED~%")
(defparameter cl-user::*smoke-init-canary* t)
RCEOF

# An inherited SBCL_HOME would mask the resume-time restoration logic
# these tests exercise (a caller-provided value always wins there).
unset SBCL_HOME

"$CTL" start >/dev/null || { echo "FATAL: bridge failed to start; check $SBCL_BRIDGE_DIR/sbcl-output.log"; exit 1; }
sleep 0.7

# --- Client preflight checks (before any bridge is running) ----------
#
# These deliberately run in a SEPARATE, throwaway directory: the real
# $SBCL_BRIDGE_DIR is about to have a live bridge started in it a few
# lines down, which would defeat the "no bridge running" checks below.

PREFLIGHT_DIR="$(mktemp -d)"

expect_exit "client refuses a nonexistent bridge directory (exit 6)" 6 \
  env SBCL_BRIDGE_DIR="$PREFLIGHT_DIR/does-not-exist" "$CLIENT" eval '(+ 1 1)'

expect_exit "client refuses a directory with no .sbcl-bridge.pid (exit 6)" 6 \
  env SBCL_BRIDGE_DIR="$PREFLIGHT_DIR" "$CLIENT" eval '(+ 1 1)'

echo 999999 > "$PREFLIGHT_DIR/.sbcl-bridge.pid"
expect_exit "client refuses a stale (not-running) pid (exit 6)" 6 \
  env SBCL_BRIDGE_DIR="$PREFLIGHT_DIR" "$CLIENT" eval '(+ 1 1)'

sleep 999 &
UNRELATED_PID=$!
echo "$UNRELATED_PID" > "$PREFLIGHT_DIR/.sbcl-bridge.pid"
expect_exit "client refuses a pid that isn't sbcl-like (recycled pid, exit 6)" 6 \
  env SBCL_BRIDGE_DIR="$PREFLIGHT_DIR" "$CLIENT" eval '(+ 1 1)'
kill "$UNRELATED_PID" 2>/dev/null || true
rm -rf "$PREFLIGHT_DIR"

# --- Basic evaluation ------------------------------------------------

if "$CLIENT" eval '(+ 40 2)' 2>/dev/null | grep -q '^;;; => 42$'; then
  ok "basic eval prints the value"
else
  bad "basic eval prints the value"
fi

if "$CLIENT" eval '(values 1 2 3)' 2>/dev/null | grep -q '^;;; => 1 ; 2 ; 3$'; then
  ok "multiple values separated by ;"
else
  bad "multiple values separated by ;"
fi

"$CLIENT" eval '(defparameter *smoke* 1)' >/dev/null 2>&1
if "$CLIENT" eval '(incf *smoke*)' 2>/dev/null | grep -q '^;;; => 2$'; then
  ok "state persists across requests"
else
  bad "state persists across requests"
fi

# --- Errors and printing edge cases ----------------------------------

expect_exit "signalled error -> exit 1" 1 "$CLIENT" eval '(error "boom")'

if "$CLIENT" eval '(/ 1 0)' 2>/dev/null | grep -q 'BACKTRACE-BEGIN'; then
  ok "error response includes a backtrace"
else
  bad "error response includes a backtrace"
fi

UNPRINTABLE='(defclass smoke-bad () ())
(defmethod print-object ((o smoke-bad) s) (error "unprintable"))
(make-instance (quote smoke-bad))'
if "$CLIENT" eval "$UNPRINTABLE" 2>/dev/null | grep -q '#<unprintable'; then
  ok "unprintable value degrades to placeholder, not status=error"
else
  bad "unprintable value degrades to placeholder, not status=error"
fi

# --- Embedded request headers -----------------------------------------

if "$CLIENT" eval $';;; REQID: smoke-fixed-id\n(+ 1 1)' 2>/dev/null \
     | grep -q 'END-OUTPUT id=smoke-fixed-id status=ok'; then
  ok "embedded REQID header is reused, not shadowed"
else
  bad "embedded REQID header is reused, not shadowed"
fi

expect_exit "embedded TIMEOUT header reaches the bridge -> exit 3" 3 \
  "$CLIENT" eval $';;; TIMEOUT: 1\n(sleep 5)'

expect_exit "SBCL_REQUEST_TIMEOUT env overrides embedded TIMEOUT" 0 \
  env SBCL_REQUEST_TIMEOUT=none "$CLIENT" eval $';;; TIMEOUT: 1\n(progn (sleep 2) :ok)'

# --- Clean environment (no init files) ---------------------------------

if grep -q "SMOKE-CANARY" "$SBCL_BRIDGE_DIR/sbcl-output.log"; then
  bad "bridge started without loading init files (canary .sbclrc was executed)"
elif "$CLIENT" eval '(boundp (quote *smoke-init-canary*))' 2>/dev/null \
       | grep -q '^;;; => NIL$'; then
  ok "bridge started without loading init files"
else
  bad "bridge started without loading init files (canary variable is bound)"
fi

# --- Timeouts and cancellation ---------------------------------------

expect_exit "bridge-side timeout -> exit 3" 3 \
  env SBCL_REQUEST_TIMEOUT=1 "$CLIENT" eval '(sleep 5)'

( SBCL_REQUEST_TIMEOUT=none "$CLIENT" eval '(sleep 30)' >/dev/null 2>&1
  echo $? > "$SBCL_BRIDGE_DIR/.cancel-exit" ) &
CANCEL_PID=$!
sleep 1
"$CTL" interrupt >/dev/null 2>&1
wait "$CANCEL_PID"
if [ "$(cat "$SBCL_BRIDGE_DIR/.cancel-exit" 2>/dev/null)" = "4" ]; then
  ok "cancellation via interrupt -> exit 4"
else
  bad "cancellation via interrupt -> exit 4"
fi

# --- Concurrency and rotation safety ----------------------------------

"$CLIENT" eval '(progn (sleep 2) :first)' >/dev/null 2>&1 &
Q1=$!
sleep 0.3
"$CLIENT" eval ':second' >/dev/null 2>&1 &
Q2=$!
if wait "$Q1" && wait "$Q2"; then
  ok "second caller queues behind an in-flight request"
else
  bad "second caller queues behind an in-flight request"
fi

# A caller with a short SBCL_TIMEOUT that gives up before the slot ever
# frees must get exit 7 (couldn't submit) -- distinct from exit 2
# (submitted, no response). This needs the input SLOT itself occupied
# by an unclaimed request, not just the bridge being busy: the bridge
# claims (moves next-sbcl-input.lisp -> .working) almost instantly, so
# a lone submission during a long-running request typically still
# lands cleanly and then times out waiting for a RESPONSE (exit 2) --
# that path is already covered above. To occupy the slot itself we
# need a QUEUED-BEHIND request: an occupant to tie up evaluation, a
# second request that lands in next-sbcl-input.lisp and can't be
# claimed while the occupant runs, and only then a third, impatient
# caller whose ln(1) genuinely fails for the occupant's whole duration.
"$CLIENT" eval '(progn (sleep 3) :occupant)' >/dev/null 2>&1 &
Q_OCC=$!
sleep 0.3
"$CLIENT" eval ':queued-behind' >/dev/null 2>&1 &
Q_QUEUED=$!
sleep 0.3
expect_exit "caller gives up queueing when the slot stays busy (exit 7)" 7 \
  env SBCL_TIMEOUT=1 "$CLIENT" eval ':impatient'
wait "$Q_OCC" 2>/dev/null || true
wait "$Q_QUEUED" 2>/dev/null || true

"$CLIENT" eval '(progn (sleep 2) :busy)' >/dev/null 2>&1 &
Q3=$!
sleep 0.5
if SBCL_LOG_MAX_BYTES=1 "$CTL" rotate-logs 2>/dev/null | grep -q "skipping rotation"; then
  ok "rotation skipped while a request is in flight"
else
  bad "rotation skipped while a request is in flight"
fi
if wait "$Q3"; then
  ok "in-flight client unharmed by the rotation attempt"
else
  bad "in-flight client unharmed by the rotation attempt"
fi

# --- Suspend / resume -------------------------------------------------

"$CLIENT" eval '(defparameter *pre-suspend* 41)' >/dev/null 2>&1
if "$CTL" suspend >/dev/null 2>&1; then
  ok "suspend saves a core and exits"
else
  bad "suspend saves a core and exits"
fi

if [ ! -e "$SBCL_BRIDGE_DIR/next-sbcl-input.working" ]; then
  ok "suspend leaves no working file behind"
else
  bad "suspend leaves no working file behind"
fi

if "$CTL" resume >/dev/null 2>&1; then
  ok "resume restarts from the saved core"
else
  bad "resume restarts from the saved core"
fi
sleep 0.7

LEFTOVERS=("$SBCL_BRIDGE_DIR"/processed/leftover-*.lisp)
if [ -e "${LEFTOVERS[0]}" ]; then
  bad "no leftover-*.lisp after a normal suspend/resume"
else
  ok "no leftover-*.lisp after a normal suspend/resume"
fi

if "$CLIENT" eval '(incf *pre-suspend*)' 2>/dev/null | grep -q '^;;; => 42$'; then
  ok "state survives suspend/resume"
else
  bad "state survives suspend/resume"
fi

# --- Moved workspace: SBCL_BRIDGE_DIR override on resume ---------------
#
# The scenario this feature exists for: a core suspended while watching
# one directory must be resumable from a DIFFERENT directory (a shared
# workspace mounted at different paths on a host and inside a
# container, say), with requests submitted at the NEW location actually
# answered rather than the resumed bridge silently watching the stale
# baked-in path. This also pins down a pathname-normalization edge
# case: environment variables conventionally carry no trailing slash
# (unlike ctl.sh's own internal directory-argument convention), which a
# naive directory-pathname coercion can silently mishandle by dropping
# the last path segment entirely -- turning "/some/dir" into "/",
# watching (and writing logs into) the wrong place with no error.
"$CLIENT" eval '(defparameter *moved-marker* :still-here)' >/dev/null 2>&1
"$CTL" suspend >/dev/null 2>&1
MOVED_CORE="$(ls -t "$SBCL_BRIDGE_DIR"/cores/*.core 2>/dev/null | head -1)"
MOVED_DIR="$(mktemp -d)"
if [ -n "$MOVED_CORE" ]; then
  mkdir -p "$MOVED_DIR/cores"
  cp "$MOVED_CORE" "$MOVED_DIR/cores/"
  [ -f "$MOVED_CORE.version" ] && cp "$MOVED_CORE.version" "$MOVED_DIR/cores/"
  chmod +x "$MOVED_DIR"/cores/*.core

  ORIG_BRIDGE_DIR="$SBCL_BRIDGE_DIR"
  export SBCL_BRIDGE_DIR="$MOVED_DIR"
  "$CTL" resume >/dev/null 2>&1
  sleep 0.7
  if "$CLIENT" eval '*moved-marker*' 2>/dev/null | grep -q ':STILL-HERE'; then
    ok "resume honors SBCL_BRIDGE_DIR pointing at a moved workspace"
  else
    bad "resume honors SBCL_BRIDGE_DIR pointing at a moved workspace"
  fi
  "$CTL" stop >/dev/null 2>&1

  # Restore the original bridge dir and state for the remaining tests.
  export SBCL_BRIDGE_DIR="$ORIG_BRIDGE_DIR"
  "$CTL" resume >/dev/null 2>&1
  sleep 0.7
else
  bad "resume honors SBCL_BRIDGE_DIR pointing at a moved workspace (no core found)"
fi
rm -rf "$MOVED_DIR"

# Contrib REQUIRE after a resume: exercises the SBCL_HOME sidecar
# restore. sb-posix must NOT have been loaded before the suspend for
# this to be meaningful (the bridge itself only uses built-in modules).
if "$CLIENT" eval '(require :sb-posix) (sb-posix:getpid)' >/dev/null 2>&1; then
  ok "contrib REQUIRE works after resume (SBCL_HOME restored)"
else
  bad "contrib REQUIRE works after resume (SBCL_HOME restored)"
fi

# Cross-environment resume: the sidecar's recorded SBCL_HOME points at
# a prefix that doesn't exist HERE (the shared-workspace scenario:
# suspend on the host, resume the same core inside a container whose
# sbcl lives elsewhere). Resume must detect the dead path and restore
# a validated home from the local installation instead, so contrib
# REQUIRE still works.
"$CTL" suspend >/dev/null 2>&1
XENV_SIDECAR="$(ls -t "$SBCL_BRIDGE_DIR"/cores/*.version 2>/dev/null | head -1)"
if [ -n "$XENV_SIDECAR" ]; then
  sed -i '3s|.*|/nonexistent-host-prefix/lib/sbcl/|' "$XENV_SIDECAR"
  "$CTL" resume >/dev/null 2>&1
  sleep 0.7
  if "$CLIENT" eval '(require :sb-cover) :cross-env-ok' 2>/dev/null | grep -q ':CROSS-ENV-OK'; then
    ok "cross-environment resume restores a usable SBCL_HOME"
  else
    bad "cross-environment resume restores a usable SBCL_HOME"
  fi
else
  bad "cross-environment resume restores a usable SBCL_HOME (no sidecar found)"
fi

# Suspend queued behind a long request must be withdrawn on timeout.
SBCL_REQUEST_TIMEOUT=none "$CLIENT" eval '(progn (sleep 4) :long)' >/dev/null 2>&1 &
QL=$!
sleep 0.5
if SBCL_SUSPEND_TIMEOUT=1 "$CTL" suspend 2>&1 | grep -q "withdrawn"; then
  ok "timed-out suspend is withdrawn, not left queued"
else
  bad "timed-out suspend is withdrawn, not left queued"
fi
wait "$QL" >/dev/null 2>&1
sleep 1
if "$CTL" status 2>/dev/null | head -1 | grep -q RUNNING; then
  ok "bridge still running after withdrawn suspend"
else
  bad "bridge still running after withdrawn suspend"
fi

# --- Fatal (non-ERROR) conditions -------------------------------------

expect_exit "control-stack exhaustion -> exit 5, bridge survives" 5 \
  "$CLIENT" eval '(labels ((f (n) (+ 1 (f (1+ n))))) (f 0))'

if "$CLIENT" eval ':still-alive' 2>/dev/null | grep -q ':STILL-ALIVE'; then
  ok "bridge healthy after fatal condition"
else
  bad "bridge healthy after fatal condition"
fi

# --- Summary -----------------------------------------------------------

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
