#!/usr/bin/env bash
#
# sbcl-bridge-ctl.sh -- start/stop/restart/status, plus suspend/resume,
# for the sbcl-bridge background process. No systemd required; designed
# to work fine inside a plain Docker container.
#
# Usage:
#   sbcl-bridge-ctl.sh start
#   sbcl-bridge-ctl.sh stop
#   sbcl-bridge-ctl.sh restart
#   sbcl-bridge-ctl.sh status
#   sbcl-bridge-ctl.sh suspend   [core-path]
#   sbcl-bridge-ctl.sh resume    [core-path]
#   sbcl-bridge-ctl.sh interrupt [reqid]     # cancel the request in flight
#
# Environment:
#   SBCL_BRIDGE_DIR       directory the bridge monitors (default: .)
#   SBCL_BRIDGE_LISP      path to sbcl-bridge.lisp (default: alongside this script)
#   SBCL_BIN              sbcl executable (default: sbcl)
#   SBCL_CORE_RETAIN      number of core images to keep (default: 3)
#   SBCL_STOP_TIMEOUT     seconds to wait before SIGKILL on stop (default: 10)
#   SBCL_SUSPEND_TIMEOUT  seconds to wait for suspend to finish (default: 60)

set -euo pipefail
shopt -s nullglob

# ---------------------------------------------------------------------
# Configuration

BRIDGE_DIR="${SBCL_BRIDGE_DIR:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_LISP="${SBCL_BRIDGE_LISP:-$SCRIPT_DIR/sbcl-bridge.lisp}"
SBCL_BIN="${SBCL_BIN:-sbcl}"

PID_FILE="$BRIDGE_DIR/.sbcl-bridge.pid"
OUTPUT_LOG="$BRIDGE_DIR/sbcl-output.log"
CORE_DIR="$BRIDGE_DIR/cores"
CORE_RETAIN="${SBCL_CORE_RETAIN:-3}"

STOP_TIMEOUT="${SBCL_STOP_TIMEOUT:-10}"
SUSPEND_TIMEOUT="${SBCL_SUSPEND_TIMEOUT:-60}"
POLL_INTERVAL=0.3

mkdir -p "$BRIDGE_DIR" "$CORE_DIR"
touch "$OUTPUT_LOG"

# ---------------------------------------------------------------------
# Helpers

current_pid() {
  [ -f "$PID_FILE" ] && cat "$PID_FILE" 2>/dev/null || true
}

is_running() {
  local pid
  pid="$(current_pid)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
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

list_cores_by_age() {
  # newest first, one per line; empty output if none (nullglob is set)
  local files=("$CORE_DIR"/*.core)
  [ ${#files[@]} -eq 0 ] && return 0
  ls -t "${files[@]}"
}

latest_core() {
  list_cores_by_age | head -n1
}

prune_cores() {
  # Keep the CORE_RETAIN most recent core images; always keep at least
  # one image even if CORE_RETAIN was set to 0 by mistake.
  local keep=$CORE_RETAIN
  [ "$keep" -lt 1 ] && keep=1
  local files=()
  while IFS= read -r line; do
    [ -n "$line" ] && files+=("$line")
  done < <(list_cores_by_age)
  local n=${#files[@]}
  if [ "$n" -gt "$keep" ]; then
    local i
    for ((i = keep; i < n; i++)); do
      rm -f "${files[$i]}" "${files[$i]}.version"
    done
  fi
}

current_sbcl_info() {
  # Prints two lines: (lisp-implementation-version) and (machine-type),
  # using the same format that write-version-sidecar used at save time.
  "$SBCL_BIN" --noinform --non-interactive \
    --eval '(progn (princ (lisp-implementation-version)) (terpri) (princ (machine-type)) (terpri))' \
    2>/dev/null
}

check_core_compatibility() {
  local core_path="$1"
  local version_file="${core_path}.version"
  if [ ! -f "$version_file" ]; then
    echo "WARNING: no version metadata found for $core_path; cannot verify compatibility with $SBCL_BIN." >&2
    return 0
  fi
  local saved_version saved_machine current_version current_machine
  saved_version="$(sed -n '1p' "$version_file")"
  saved_machine="$(sed -n '2p' "$version_file")"
  { read -r current_version; read -r current_machine; } < <(current_sbcl_info)
  if [ "$saved_version" != "$current_version" ] || [ "$saved_machine" != "$current_machine" ]; then
    echo "WARNING: $core_path was saved with SBCL $saved_version ($saved_machine)," >&2
    echo "         but $SBCL_BIN here reports $current_version ($current_machine)." >&2
    echo "         Resuming anyway, since it's a self-contained executable image," >&2
    echo "         but this may fail or misbehave if the mismatch is significant." >&2
  fi
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
  setsid "$SBCL_BIN" --non-interactive \
      --load "$BRIDGE_LISP" \
      --eval "(sbcl-bridge:run-bridge :directory \"$BRIDGE_DIR/\")" \
      < /dev/null >> "$OUTPUT_LOG" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  echo "$pid" > "$PID_FILE"
  sleep 0.5
  if is_running; then
    echo "Started (pid $pid)."
  else
    echo "Failed to start; check $OUTPUT_LOG" >&2
    rm -f "$PID_FILE"
    exit 1
  fi
}

cmd_stop() {
  if ! is_running; then
    echo "Not running."
    rm -f "$PID_FILE"
    return 0
  fi
  local pid
  pid="$(current_pid)"
  echo "Stopping pid $pid ..."
  kill -TERM "$pid" 2>/dev/null || true
  if wait_for_exit "$pid" "$STOP_TIMEOUT"; then
    echo "Stopped."
  else
    echo "Did not exit within ${STOP_TIMEOUT}s; sending SIGKILL."
    kill -KILL "$pid" 2>/dev/null || true
    wait_for_exit "$pid" 5 || true
  fi
  rm -f "$PID_FILE"
}

cmd_restart() {
  cmd_stop
  cmd_start
}

cmd_status() {
  if is_running; then
    local pid etime
    pid="$(current_pid)"
    etime="$(ps -o etime= -p "$pid" 2>/dev/null | xargs || true)"
    echo "RUNNING (pid=$pid, uptime=${etime:-unknown})"
  else
    echo "STOPPED"
    [ -f "$PID_FILE" ] && rm -f "$PID_FILE"
  fi

  local files=("$CORE_DIR"/*.core)
  if [ ${#files[@]} -gt 0 ]; then
    echo "Saved core images (newest first):"
    ls -lt "${files[@]}" | awk '{printf "  %8d bytes  %s %s %s  %s\n", $5, $6, $7, $8, $9}'
  else
    echo "No saved core images."
  fi
}

cmd_suspend() {
  if ! is_running; then
    echo "Not running; nothing to suspend." >&2
    exit 1
  fi
  local pid ts core_path
  pid="$(current_pid)"
  ts="$(date +%Y%m%d-%H%M%S)"
  core_path="${1:-$CORE_DIR/bridge-$ts.core}"

  if [ -e "$BRIDGE_DIR/next-sbcl-input.lisp" ]; then
    echo "A request is already pending in next-sbcl-input.lisp; try again shortly." >&2
    exit 1
  fi

  echo "Requesting suspend to $core_path ..."
  local lisp_path="\"${core_path//\"/\\\"}\""
  local tmp
  tmp="$(mktemp "$BRIDGE_DIR/.next-sbcl-input.XXXXXX")"
  {
    printf ';;; REQID: suspend-%s\n' "$ts"
    printf '(sbcl-bridge:suspend-bridge :core-path %s)\n' "$lisp_path"
  } > "$tmp"
  mv -f "$tmp" "$BRIDGE_DIR/next-sbcl-input.lisp"

  if wait_for_exit "$pid" "$SUSPEND_TIMEOUT"; then
    if [ -s "$core_path" ]; then
      chmod +x "$core_path" 2>/dev/null || true
      echo "Suspended. Core image saved: $core_path"
      rm -f "$PID_FILE"
      prune_cores
    else
      echo "Process exited but core image is missing/empty: $core_path" >&2
      exit 1
    fi
  else
    echo "Process did not exit within ${SUSPEND_TIMEOUT}s; suspend may have failed." >&2
    exit 1
  fi
}

cmd_resume() {
  if is_running; then
    echo "Already running (pid $(current_pid))."
    return 0
  fi
  local core_path="${1:-$(latest_core)}"
  if [ -z "$core_path" ] || [ ! -f "$core_path" ]; then
    echo "No core image to resume from (looked in $CORE_DIR)." >&2
    exit 1
  fi
  rm -f "$PID_FILE"

  check_core_compatibility "$core_path"

  echo "Resuming from $core_path ..."
  if [ -x "$core_path" ]; then
    setsid "$core_path" < /dev/null >> "$OUTPUT_LOG" 2>&1 &
  else
    setsid "$SBCL_BIN" --core "$core_path" < /dev/null >> "$OUTPUT_LOG" 2>&1 &
  fi
  local pid=$!
  disown "$pid" 2>/dev/null || true
  echo "$pid" > "$PID_FILE"
  sleep 0.5
  if is_running; then
    echo "Resumed (pid $pid)."
  else
    echo "Failed to resume; check $OUTPUT_LOG" >&2
    rm -f "$PID_FILE"
    exit 1
  fi
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

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") {start|stop|restart|status|suspend [core-path]|resume [core-path]|interrupt [reqid]}

Environment:
  SBCL_BRIDGE_DIR       directory the bridge monitors (default: .)
  SBCL_BRIDGE_LISP      path to sbcl-bridge.lisp (default: alongside this script)
  SBCL_BIN              sbcl executable (default: sbcl)
  SBCL_CORE_RETAIN      number of core images to keep (default: 3)
  SBCL_STOP_TIMEOUT     seconds to wait before SIGKILL on stop (default: 10)
  SBCL_SUSPEND_TIMEOUT  seconds to wait for suspend to finish (default: 60)

interrupt cancels whatever request is currently being evaluated (or a
specific one, by reqid). It has no effect once a request has already
finished, and does not itself stop/restart the bridge process.
EOF
  exit 1
}

[ $# -ge 1 ] || usage
case "$1" in
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  restart)   cmd_restart ;;
  status)    cmd_status ;;
  suspend)   shift; cmd_suspend "${1:-}" ;;
  resume)    shift; cmd_resume "${1:-}" ;;
  interrupt) shift; cmd_interrupt "${1:-}" ;;
  *) usage ;;
esac
