#!/usr/bin/env bash
#
# sbcl-client.sh -- submit code to a running sbcl-bridge loop and wait
# for the correlated result.
#
# Usage:
#   sbcl-client.sh eval '(+ 1 2)'
#   sbcl-client.sh eval '(defun f (x) (* x x)) (f 5)'
#   sbcl-client.sh file path/to/code.lisp     # shortcut: submit a file
#   sbcl-client.sh -                          # read code from stdin
#
# Environment:
#   SBCL_BRIDGE_DIR      directory monitored by the bridge loop (default: .)
#   SBCL_POLL_INTERVAL   polling interval in seconds (default: 0.2)
#   SBCL_TIMEOUT         total seconds THIS SCRIPT waits -- covering both
#                        queueing the request (if another one is still
#                        pending) and receiving its response (default:
#                        30, or the effective evaluation timeout + 5 if
#                        that's larger; see "Embedded headers" below)
#   SBCL_REQUEST_TIMEOUT seconds the BRIDGE allows the evaluation itself to
#                        run before giving up (default: bridge's own
#                        default, currently 30s). Use "none" to disable.
#
# Before submitting anything, this script checks that SBCL_BRIDGE_DIR
# actually looks like it's being watched by a live bridge (a
# .sbcl-bridge.pid naming a running, sbcl-like process) -- a directory
# existing is not evidence of that, and submitting against a dead
# bridge would otherwise just sit until SBCL_TIMEOUT and report a
# misleading "timed out" rather than "nothing is running here".
#
# Requests are submitted by hard-linking into place: if a previous
# request is still queued and unclaimed, this script waits for the slot
# instead of overwriting it, so sequential callers queue up safely.
#
# Header comments embedded in the submitted code itself are honored:
# a leading ';;; REQID: <id>' is reused as the request id (instead of
# being shadowed by a generated one), and a leading ';;; TIMEOUT: <s>'
# both reaches the bridge and extends this script's own wait budget.
# SBCL_REQUEST_TIMEOUT, when set, takes precedence over an embedded
# TIMEOUT header.
#
# Exit codes. This is a deliberate, disjoint scheme meant to be a
# stable contract for scripted/agent callers -- each code means
# exactly one thing, never two. Codes 0-5 mean the bridge received the
# request and reported an outcome for it; codes 6-7 mean the request
# was never delivered to the bridge at all (nothing was evaluated, and
# there is no BEGIN-OUTPUT/END-OUTPUT pair to look for in the log for
# this attempt).
#
#   0  ok                        -- bridge reported status=ok
#   1  evaluation error          -- bridge reported status=error
#   2  no response in time       -- request WAS submitted, but no
#                                    response arrived within the wait
#                                    budget (SBCL_TIMEOUT or the
#                                    computed default); the bridge may
#                                    still be working on it
#   3  bridge-side timeout       -- bridge reported status=timeout
#                                    (SBCL_REQUEST_TIMEOUT / embedded
#                                    TIMEOUT header expired)
#   4  cancelled                 -- bridge reported status=cancelled
#                                    (via ctl.sh interrupt)
#   5  fatal condition           -- bridge reported status=fatal-condition
#   6  usage / preflight error   -- nothing was ever submitted: bad
#                                    command-line usage, a missing
#                                    SBCL_BRIDGE_DIR, or no live bridge
#                                    found watching it
#   7  could not submit in time  -- the request was fully formed
#                                    locally but the input slot never
#                                    freed up within the wait budget
#                                    (another request stayed queued the
#                                    whole time); still nothing evaluated
#
# The 6/7 split matters operationally: 6 means "fix your setup" (the
# retry will keep failing until you do), 7 means "the bridge is just
# busy" (retrying later, or interrupting whatever's queued, may help).

set -euo pipefail

SBCL_BRIDGE_DIR="${SBCL_BRIDGE_DIR:-.}"
POLL_INTERVAL="${SBCL_POLL_INTERVAL:-0.2}"
REQUEST_TIMEOUT="${SBCL_REQUEST_TIMEOUT:-}"

extract_code_header() {
  # extract_code_header KEY -- print the value of a leading
  # ';;; KEY: value' header line in $CODE and return 0, or return 1 if
  # no such header exists. Mirrors the bridge's own parser
  # (match-header-line / extract-header in sbcl-bridge.lisp): only the
  # leading run of well-formed header lines is scanned -- the first
  # line that isn't ';;; ' followed by 'KEY: value' ends the scan --
  # and the KEY comparison is case-insensitive.
  local want line rest k v
  want="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      ';;; '*) rest="${line#';;; '}" ;;
      *) return 1 ;;
    esac
    case "$rest" in
      *:*) ;;
      *) return 1 ;;
    esac
    k="$(printf '%s' "${rest%%:*}" \
         | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
         | tr '[:lower:]' '[:upper:]')"
    v="$(printf '%s' "${rest#*:}" \
         | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ "$k" = "$want" ]; then
      printf '%s\n' "$v"
      return 0
    fi
  done <<<"$CODE"
  return 1
}

usage() {
  cat >&2 <<EOF
Usage:
  $(basename "$0") eval '<lisp forms...>'
  $(basename "$0") file <path-to-lisp-file>
  $(basename "$0") -                 # read code from stdin

Environment:
  SBCL_BRIDGE_DIR      directory monitored by the bridge loop (default: .)
  SBCL_POLL_INTERVAL   polling interval in seconds (default: 0.2)
  SBCL_TIMEOUT         total seconds this script waits, covering both
                       queueing the request and receiving its response
                       (default: 30, or the effective evaluation
                       timeout + 5 if that's larger)
  SBCL_REQUEST_TIMEOUT seconds the bridge allows the evaluation to run
                       (default: bridge's own default; "none" to disable)

Leading ';;; REQID: <id>' and ';;; TIMEOUT: <seconds|none>' header
comments embedded in the submitted code are honored: the id is reused,
and the timeout both reaches the bridge and extends this script's wait
budget. SBCL_REQUEST_TIMEOUT overrides an embedded TIMEOUT header.

Exit codes: see the comment block at the top of this script.
EOF
  exit 6
}

[ $# -ge 1 ] || usage

mode="$1"
shift || true

case "$mode" in
  eval)
    [ $# -ge 1 ] || usage
    CODE="$*"
    ;;
  file)
    [ $# -eq 1 ] || usage
    [ -f "$1" ] || { echo "No such file: $1" >&2; exit 6; }
    CODE="$(cat "$1")"
    ;;
  -)
    CODE="$(cat)"
    ;;
  *)
    usage
    ;;
esac

if [ ! -d "$SBCL_BRIDGE_DIR" ]; then
  echo "Bridge directory does not exist: $SBCL_BRIDGE_DIR" >&2
  exit 6
fi

# Normalize to an absolute, symlink-resolved path now that we know it
# exists (this is the earliest point 'cd' is guaranteed to succeed).
# Every path below is built by plain string concatenation
# ("$SBCL_BRIDGE_DIR/whatever"), so any imprecision here -- a
# caller-supplied SBCL_BRIDGE_DIR with its own trailing slash, a
# relative path, "." -- would otherwise propagate into every derived
# path (INPUT_FILE, OUTPUT_LOG, PID_FILE, the mktemp template below).
# Harmless to the filesystem itself (a double slash resolves
# identically to a single one on any POSIX system), but avoidable, and
# sbcl-bridge-ctl.sh normalizes BRIDGE_DIR the same way at the same
# point in its own startup for the same reason -- see the comment
# there for the log line that made this worth doing consistently
# everywhere rather than only where it happened to be visible.
SBCL_BRIDGE_DIR="$(cd "$SBCL_BRIDGE_DIR" && pwd)"

INPUT_FILE="$SBCL_BRIDGE_DIR/next-sbcl-input.lisp"
OUTPUT_LOG="$SBCL_BRIDGE_DIR/sbcl-output.log"

# A directory existing is not evidence a bridge is actually watching it
# -- it could be an empty/unrelated directory, or one whose bridge
# crashed or was stopped hours ago. Without this check, a submission
# against a dead bridge would sit silently until SBCL_TIMEOUT expired
# and only then report the unhelpful "timed out waiting for response"
# (exit 2), instead of the real problem (exit 6). Mirrors (a
# deliberately lighter version of) sbcl-bridge-ctl.sh's own is_running:
# PID file present, process alive, and -- to catch a PID recycled by an
# unrelated process after a crash -- looking like sbcl at all. This is
# a liveness check, not a guarantee: the bridge can still crash, hang,
# or belong to a different SBCL_BRIDGE_LISP between this check and the
# actual submission. Keep in sync with is_running() in
# sbcl-bridge-ctl.sh if that logic changes.
PID_FILE="$SBCL_BRIDGE_DIR/.sbcl-bridge.pid"
if [ ! -f "$PID_FILE" ]; then
  echo "No bridge appears to be running against $SBCL_BRIDGE_DIR (no .sbcl-bridge.pid)." >&2
  echo "Start one with: sbcl-bridge-ctl.sh start" >&2
  exit 6
fi
BRIDGE_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
if [ -z "$BRIDGE_PID" ] || ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
  echo "Stale .sbcl-bridge.pid in $SBCL_BRIDGE_DIR (pid '${BRIDGE_PID:-<empty>}' not running)." >&2
  echo "Start (or restart) the bridge with: sbcl-bridge-ctl.sh start" >&2
  exit 6
fi
if [ -r "/proc/$BRIDGE_PID/cmdline" ] \
   && ! tr '\0' ' ' < "/proc/$BRIDGE_PID/cmdline" 2>/dev/null | grep -qE 'sbcl|\.core'; then
  echo "pid $BRIDGE_PID in $PID_FILE doesn't look like an sbcl process (stale/recycled pid?)." >&2
  echo "Check with: sbcl-bridge-ctl.sh status" >&2
  exit 6
fi

[ -f "$OUTPUT_LOG" ] || touch "$OUTPUT_LOG"

# Headers embedded in the submitted code itself (any mode: file, eval,
# or stdin) are honored, mirroring what the bridge does with them:
#  - an embedded ';;; REQID:' is REUSED as this request's id instead of
#    being shadowed by a generated one, so the response markers and the
#    processed/ archive carry the id its author chose;
#  - an embedded ';;; TIMEOUT:' informs this script's wait budget, so a
#    file that grants itself 300 seconds isn't abandoned client-side at
#    the default 30.
# Precedence for the evaluation timeout: SBCL_REQUEST_TIMEOUT (env)
# beats an embedded header -- the env header is prepended ahead of the
# code and the bridge honors the first match -- which beats the bridge
# default.
FILE_REQID="$(extract_code_header REQID || true)"
FILE_TIMEOUT="$(extract_code_header TIMEOUT || true)"

EFFECTIVE_TIMEOUT="$REQUEST_TIMEOUT"
[ -z "$EFFECTIVE_TIMEOUT" ] && EFFECTIVE_TIMEOUT="$FILE_TIMEOUT"

# ${VAR:+x} (not ${VAR+x}): an SBCL_TIMEOUT explicitly set to the
# empty string must fall through to the defaults below -- an empty
# TIMEOUT compares as 0 in awk and would make this script "time out"
# on its very first poll.
if [ -n "${SBCL_TIMEOUT:+x}" ]; then
  TIMEOUT="$SBCL_TIMEOUT"
elif [[ "$EFFECTIVE_TIMEOUT" =~ ^[0-9]+$ ]]; then
  # Wait a little longer than the bridge-side evaluation timeout, so a
  # bridge-side timeout gets reported properly (exit 3) instead of this
  # script giving up first (exit 2) -- but never wait less than the
  # normal 30s default.
  TIMEOUT=$((EFFECTIVE_TIMEOUT + 5))
  [ "$TIMEOUT" -lt 30 ] && TIMEOUT=30
else
  # No timeout in effect anywhere, or "none", or unparseable.
  TIMEOUT=30
fi

if [ -n "$FILE_REQID" ]; then
  # Reusing a fixed id is fine for correlation (this script only scans
  # log content appended after its own submission), but note the
  # processed/ archive for a reused id overwrites the previous one.
  REQID="$FILE_REQID"
else
  # Unique request id. %N (nanoseconds) is a GNU date extension; on
  # BSD/macOS date it passes through as a literal 'N', which is
  # harmless here -- the PID and $RANDOM components keep ids unique on
  # those systems too (a collision would need the same second, a
  # recycled PID, and the same 15-bit random draw).
  REQID="$(date +%s%N)-$$-$RANDOM"
fi

# Write the request to a temp file in the SAME directory, then link it
# into place atomically, so the bridge never sees a partial write.
TMP_FILE="$(mktemp "$SBCL_BRIDGE_DIR/.next-sbcl-input.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT
{
  [ -z "$FILE_REQID" ] && printf ';;; REQID: %s\n' "$REQID"
  [ -n "$REQUEST_TIMEOUT" ] && printf ';;; TIMEOUT: %s\n' "$REQUEST_TIMEOUT"
  printf '%s\n' "$CODE"
} > "$TMP_FILE"

# Remember how much of the output log already exists, so we only ever
# scan new content (cheap even for a long-lived bridge session). Must
# be recorded BEFORE the request is submitted, since the response can
# only appear after that.
START_SIZE=$(wc -c < "$OUTPUT_LOG")

# Submit with ln(1), not mv -f: ln fails atomically if INPUT_FILE
# already exists, so a request that is queued but not yet claimed by
# the bridge is never silently overwritten (which would leave its
# client waiting forever). If the slot is busy, poll until the bridge
# claims the queued request, within the same overall TIMEOUT budget as
# the response wait below. This loop exits 7, not 2, on giving up:
# nothing was ever delivered to the bridge, which is a categorically
# different (and to a caller, actionable-differently) outcome than
# "delivered but no response yet".
elapsed=0
until ln "$TMP_FILE" "$INPUT_FILE" 2>/dev/null; do
  sleep "$POLL_INTERVAL"
  elapsed=$(awk -v e="$elapsed" -v p="$POLL_INTERVAL" 'BEGIN { printf "%.2f", e + p }')
  if awk -v e="$elapsed" -v t="$TIMEOUT" 'BEGIN { exit !(e >= t) }'; then
    echo "ERROR: timed out after ${TIMEOUT}s waiting for the input slot to free up (another request is still queued) id=${REQID}" >&2
    exit 7
  fi
done
rm -f "$TMP_FILE"

# Note the trailing space in both markers: the real log lines continue
# with " ts=..." / " status=...", and matching through that delimiter
# prevents a reqid that is a strict prefix of another reqid (e.g.
# "...-4" vs "...-42") from matching the wrong request's block.
BEGIN_MARK=";;; BEGIN-OUTPUT id=${REQID} "
END_MARK=";;; END-OUTPUT id=${REQID} "

while true; do
  # If the log was rotated (copy-truncated) while we were waiting, the
  # remembered offset now points past EOF and tail would return nothing
  # forever; fall back to scanning the truncated file from the top.
  # (The bridge-ctl script also declines to rotate while a request is
  # queued or in flight, so this is belt-and-braces.)
  CUR_SIZE=$(wc -c < "$OUTPUT_LOG" 2>/dev/null || echo 0)
  if [ "$CUR_SIZE" -lt "$START_SIZE" ]; then
    START_SIZE=0
  fi
  NEW_CONTENT="$(tail -c +"$((START_SIZE + 1))" "$OUTPUT_LOG" 2>/dev/null || true)"

  if grep -qF "$END_MARK" <<<"$NEW_CONTENT"; then
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
      index($0, b) == 1 { inblock = 1; next }
      index($0, e) == 1 { print; exit }
      inblock { print }
    ' <<<"$NEW_CONTENT"

    STATUS_LINE="$(grep -F "$END_MARK" <<<"$NEW_CONTENT" | tail -n1)"
    # Courtesy timing/memory line -- stderr only, never stdout, so it
    # can never pollute output a caller might be capturing/parsing.
    # Absent gracefully (no output at all) when talking to an older
    # bridge whose END-OUTPUT marker doesn't carry these fields yet.
    STATS="$(grep -oE 'elapsed-ms=[0-9]+ consed-bytes=[0-9]+' <<<"$STATUS_LINE" || true)"
    [ -n "$STATS" ] && echo "stats: $STATS" >&2
    case "$STATUS_LINE" in
      *status=ok*)              exit 0 ;;
      *status=error*)           exit 1 ;;
      *status=timeout*)         exit 3 ;;
      *status=cancelled*)       exit 4 ;;
      *status=fatal-condition*) exit 5 ;;
      *)                        exit 0 ;;
    esac
  fi

  sleep "$POLL_INTERVAL"
  elapsed=$(awk -v e="$elapsed" -v p="$POLL_INTERVAL" 'BEGIN { printf "%.2f", e + p }')
  if awk -v e="$elapsed" -v t="$TIMEOUT" 'BEGIN { exit !(e >= t) }'; then
    echo "ERROR: timed out after ${TIMEOUT}s waiting for response id=${REQID}" >&2
    exit 2
  fi
done
