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
#                        30, or REQUEST_TIMEOUT+5 if that's set and larger)
#   SBCL_REQUEST_TIMEOUT seconds the BRIDGE allows the evaluation itself to
#                        run before giving up (default: bridge's own
#                        default, currently 30s). Use "none" to disable.
#
# Requests are submitted by hard-linking into place: if a previous
# request is still queued and unclaimed, this script waits for the slot
# instead of overwriting it, so sequential callers queue up safely.
#
# Exit codes: 0 ok, 1 evaluation error, 2 gave up within SBCL_TIMEOUT
# (either the input slot never freed up, or no response arrived),
# 3 evaluation timed out (bridge-side), 4 evaluation was cancelled,
# 5 a fatal (non-error) condition occurred bridge-side.

set -euo pipefail

SBCL_BRIDGE_DIR="${SBCL_BRIDGE_DIR:-.}"
POLL_INTERVAL="${SBCL_POLL_INTERVAL:-0.2}"
REQUEST_TIMEOUT="${SBCL_REQUEST_TIMEOUT:-}"

# ${VAR:+x} (not ${VAR+x}): an SBCL_TIMEOUT explicitly set to the
# empty string must fall through to the defaults below -- an empty
# TIMEOUT compares as 0 in awk and would make this script "time out"
# on its very first poll.
if [ -n "${SBCL_TIMEOUT:+x}" ]; then
  TIMEOUT="$SBCL_TIMEOUT"
elif [[ "$REQUEST_TIMEOUT" =~ ^[0-9]+$ ]]; then
  # Wait a little longer than the bridge-side evaluation timeout, so a
  # bridge-side timeout gets reported properly (exit 3) instead of this
  # script giving up first (exit 2) -- but never wait less than the
  # normal 30s default.
  TIMEOUT=$((REQUEST_TIMEOUT + 5))
  [ "$TIMEOUT" -lt 30 ] && TIMEOUT=30
else
  # REQUEST_TIMEOUT unset, "none", or unparseable.
  TIMEOUT=30
fi

INPUT_FILE="$SBCL_BRIDGE_DIR/next-sbcl-input.lisp"
OUTPUT_LOG="$SBCL_BRIDGE_DIR/sbcl-output.log"

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
                       (default: 30, or SBCL_REQUEST_TIMEOUT+5 if larger)
  SBCL_REQUEST_TIMEOUT seconds the bridge allows the evaluation to run
                       (default: bridge's own default; "none" to disable)
EOF
  exit 1
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
    [ -f "$1" ] || { echo "No such file: $1" >&2; exit 1; }
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
  exit 1
fi

[ -f "$OUTPUT_LOG" ] || touch "$OUTPUT_LOG"

# Unique request id. %N (nanoseconds) is a GNU date extension; on
# BSD/macOS date it passes through as a literal 'N', which is harmless
# here -- the PID and $RANDOM components keep ids unique on those
# systems too (a collision would need the same second, a recycled PID,
# and the same 15-bit random draw).
REQID="$(date +%s%N)-$$-$RANDOM"

# Write the request to a temp file in the SAME directory, then link it
# into place atomically, so the bridge never sees a partial write.
TMP_FILE="$(mktemp "$SBCL_BRIDGE_DIR/.next-sbcl-input.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT
{
  printf ';;; REQID: %s\n' "$REQID"
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
# the response wait below.
elapsed=0
until ln "$TMP_FILE" "$INPUT_FILE" 2>/dev/null; do
  sleep "$POLL_INTERVAL"
  elapsed=$(awk -v e="$elapsed" -v p="$POLL_INTERVAL" 'BEGIN { printf "%.2f", e + p }')
  if awk -v e="$elapsed" -v t="$TIMEOUT" 'BEGIN { exit !(e >= t) }'; then
    echo "ERROR: timed out after ${TIMEOUT}s waiting for the input slot to free up (another request is still queued) id=${REQID}" >&2
    exit 2
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
