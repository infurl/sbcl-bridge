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
#   SBCL_TIMEOUT         seconds THIS SCRIPT waits for a response (default:
#                        30, or REQUEST_TIMEOUT+5 if that's set and larger)
#   SBCL_REQUEST_TIMEOUT seconds the BRIDGE allows the evaluation itself to
#                        run before giving up (default: bridge's own
#                        default, currently 30s). Use "none" to disable.
#
# Exit codes: 0 ok, 1 evaluation error, 2 no response within SBCL_TIMEOUT,
# 3 evaluation timed out (bridge-side), 4 evaluation was cancelled,
# 5 a fatal (non-error) condition occurred bridge-side.

set -euo pipefail

SBCL_BRIDGE_DIR="${SBCL_BRIDGE_DIR:-.}"
POLL_INTERVAL="${SBCL_POLL_INTERVAL:-0.2}"
REQUEST_TIMEOUT="${SBCL_REQUEST_TIMEOUT:-}"

if [ -n "${SBCL_TIMEOUT+x}" ]; then
  TIMEOUT="$SBCL_TIMEOUT"
elif [ -n "$REQUEST_TIMEOUT" ] && [ "$REQUEST_TIMEOUT" != "none" ]; then
  TIMEOUT=$((REQUEST_TIMEOUT + 5))
else
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
  SBCL_TIMEOUT         seconds this script waits for a response (default: 30)
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

# Unique request id: nanosecond timestamp + our PID.
REQID="$(date +%s%N)-$$"

# Write the request to a temp file in the SAME directory, then rename
# into place atomically, so the bridge never sees a partial write.
TMP_FILE="$(mktemp "$SBCL_BRIDGE_DIR/.next-sbcl-input.XXXXXX")"
{
  printf ';;; REQID: %s\n' "$REQID"
  [ -n "$REQUEST_TIMEOUT" ] && printf ';;; TIMEOUT: %s\n' "$REQUEST_TIMEOUT"
  printf '%s\n' "$CODE"
} > "$TMP_FILE"

# Remember how much of the output log already exists, so we only ever
# scan new content (cheap even for a long-lived bridge session).
START_SIZE=$(wc -c < "$OUTPUT_LOG")

mv -f "$TMP_FILE" "$INPUT_FILE"

BEGIN_MARK=";;; BEGIN-OUTPUT id=${REQID}"
END_MARK=";;; END-OUTPUT id=${REQID}"

elapsed=0
while true; do
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
