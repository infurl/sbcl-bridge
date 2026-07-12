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
# bridge, removes the temp directories it works in) even on failure or
# ^C -- EXCEPT for one deliberate exception: every run leaves behind a
# diagnostics bundle, a single .tar.gz written to the directory this
# script was invoked FROM (never /tmp, which is exactly what gets
# cleaned up), containing a full transcript of the run, environment
# and version details, and every bridge log this run produced --
# including from the throwaway directories that would otherwise be
# deleted before anyone gets a chance to look at them. This is what
# makes it practical to debug a failure on a machine nobody else can
# log into: run the script, then send the one tarball it prints the
# path to at the end. This happens on success too, not just failure --
# useful for comparing a working run against a failing one.

set -u

# Isolate this entire suite from Quicklisp/ASDF, unconditionally, before
# anything else runs. ENSURE-QUICKLISP-CONFIGURED,
# ENSURE-ASDF-CACHE-CONFIGURED, and ENSURE-CL-SOURCE-REGISTRY-CONFIGURED
# (sbcl-bridge.lisp) all run on every single bridge start or resume,
# gated only on whether QUICKLISP_HOME / XDG_CACHE_HOME /
# CL_SOURCE_REGISTRY happen to be set in the environment -- not on
# whether a given test has anything to do with any of the three. On a
# machine where these are set ambiently (exactly the intended, expected
# setup for real use), EVERY throwaway bridge this suite starts -- the
# main one, the preflight-check ones, the moved-workspace one, all of
# them -- would otherwise attempt real Quicklisp installs and real ASDF
# compiles using the caller's REAL, persistent QUICKLISP_HOME and
# XDG_CACHE_HOME, not just the tests actually built to exercise these
# features. Found this exact way: a real user's real, shared cache
# directory ended up with leftover fasls compiled under a throwaway
# "never-installed" test path, because this suite was run in a shell
# that had XDG_CACHE_HOME set for real work, and nothing here ever
# isolated it. Unsetting these here means every test EXCEPT the ones
# that explicitly reintroduce one of them via its own `env VAR=...
# ctl.sh ...` invocation (see the Quicklisp, ASDF cache, and
# CL_SOURCE_REGISTRY sections below, each of which points these at
# throwaway `mktemp -d` locations of its own) runs exactly as if none of
# the three features existed at all -- which is the correct, isolated
# default for a suite that has nothing to do with any of them for most
# of its checks.
#
# SBCL_REQUEST_TIMEOUT / SBCL_TIMEOUT / SBCL_POLL_INTERVAL get the same
# treatment for the identical reason, found the same way -- a real run
# on a real machine, not a hypothetical: sbcl-client.sh gives an
# ambient SBCL_REQUEST_TIMEOUT precedence over an embedded ";;;
# TIMEOUT:" header (documented, correct behavior -- see §7 of the
# README), so a user who keeps SBCL_REQUEST_TIMEOUT set for their own
# real work (a generous default for long-running requests, say) would
# have that value silently override any test here that assumes an
# embedded header alone controls the bridge-side timeout. That's
# exactly what happened: an ambient SBCL_REQUEST_TIMEOUT=60 made a test
# expecting a 1-second embedded timeout to fire instead complete
# normally under the ambient 60-second budget, status=ok instead of
# status=timeout, exit 0 instead of exit 3. Every OTHER test that
# cares about either variable already sets its own value explicitly
# (grep for SBCL_REQUEST_TIMEOUT= / SBCL_TIMEOUT= below), which
# naturally overrides whatever's ambient regardless -- this global
# unset is what makes that the reliable default rather than an
# accident of which tests happened to remember.
unset QUICKLISP_HOME QUICKLISP_LISP QUICKLISP_INSTALLER_URL XDG_CACHE_HOME CL_SOURCE_REGISTRY
unset SBCL_REQUEST_TIMEOUT SBCL_TIMEOUT SBCL_POLL_INTERVAL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$SCRIPT_DIR/sbcl-bridge-ctl.sh"
CLIENT="$SCRIPT_DIR/sbcl-client.sh"

export SBCL_BRIDGE_DIR
SBCL_BRIDGE_DIR="$(mktemp -d)"
export SBCL_BRIDGE_LISP="${SBCL_BRIDGE_LISP:-$SCRIPT_DIR/sbcl-bridge.lisp}"

# --- Diagnostics bundle -------------------------------------------
#
# Staged in a temp directory like everything else, but PACKAGED into
# the directory this script was invoked from (captured as $(pwd) here,
# before anything below has a chance to cd elsewhere) -- that's the
# one directory in this whole script that's guaranteed to still exist,
# and still be the one the person running this expects to look in,
# after every throwaway bridge directory has been cleaned up.
DIAG_INVOKED_FROM="$(pwd)"
DIAG_DIR="$(mktemp -d)"
mkdir -p "$DIAG_DIR/logs"
DIAG_TARBALL="$DIAG_INVOKED_FROM/sbcl-bridge-test-diagnostics-$(date +%Y%m%d-%H%M%S).tar.gz"

# Mirror everything this script prints, stdout and stderr both, into
# the bundle -- exactly what was seen on the terminal, still shown
# live there too. This is usually the single most useful artifact when
# something fails on a machine nobody else can log into.
exec > >(tee "$DIAG_DIR/transcript.log") 2>&1

# save_bridge_logs LABEL DIR -- copy DIR's logs (and a couple of other
# cheap, occasionally-useful files) into the bundle under LABEL,
# before DIR is torn down by this script's own cleanup. A bridge that
# never actually got as far as writing anything (e.g. one of the
# preflight-check directories, where a bridge is never even started)
# just results in an empty or absent subdirectory -- never a failure.
save_bridge_logs() {
  local dir="$2" dest="$DIAG_DIR/logs/$1"
  [ -d "$dir" ] || return 0
  mkdir -p "$dest"
  local f
  for f in sbcl-output.log sbcl-input.log .sbcl-bridge.pid; do
    [ -e "$dir/$f" ] && cp "$dir/$f" "$dest/$f" 2>/dev/null
  done
  [ -d "$dir/processed" ] && cp -r "$dir/processed" "$dest/" 2>/dev/null
  find "$dir" -maxdepth 2 -name '*.version' -exec cp {} "$dest/" \; 2>/dev/null
}

# One-time snapshot of everything about the environment that could
# plausibly explain a machine-specific result: versions, resource
# limits, what's actually on PATH, and every SBCL_*/QUICKLISP_*
# variable this tooling reads. None of this is secret -- paths and
# version strings, nothing that looks like a credential -- so it's
# always captured, not just on failure.
save_environment_snapshot() {
  {
    echo "=== date ==="
    date
    echo
    echo "=== uname -a ==="
    uname -a
    echo
    echo "=== ${SBCL_BIN:-sbcl} --version ==="
    "${SBCL_BIN:-sbcl}" --version 2>&1
    echo
    echo "=== nproc / memory ==="
    echo "nproc: $(nproc 2>/dev/null || echo unknown)"
    free -h 2>/dev/null || echo "(free not available)"
    echo
    echo "=== bash version ==="
    echo "$BASH_VERSION"
    echo
    echo "=== relevant environment variables ==="
    local v
    for v in SBCL_BRIDGE_DIR SBCL_BRIDGE_LISP SBCL_BIN \
             QUICKLISP_HOME QUICKLISP_LISP \
             SBCL_POLL_INTERVAL SBCL_REQUEST_TIMEOUT SBCL_TIMEOUT \
             SBCL_CORE_RETAIN SBCL_PROCESSED_RETAIN SBCL_LOG_MAX_BYTES \
             SBCL_LOG_RETAIN SBCL_MEM_WARN_MB SBCL_STOP_TIMEOUT \
             SBCL_SUSPEND_TIMEOUT HOME SHELL PATH; do
      printf '%s=%s\n' "$v" "${!v-<unset>}"
    done
    echo
    echo "=== curl / wget availability ==="
    if command -v curl >/dev/null 2>&1; then
      echo "curl: $(command -v curl)"
      curl --version 2>&1 | head -1
    else
      echo "curl: not found"
    fi
    if command -v wget >/dev/null 2>&1; then
      echo "wget: $(command -v wget)"
      wget --version 2>&1 | head -1
    else
      echo "wget: not found"
    fi
    echo
    echo "=== script file sizes (rough version fingerprint) ==="
    wc -l "$CTL" "$CLIENT" "$SCRIPT_DIR/sbcl-bridge-test.sh" "$SBCL_BRIDGE_LISP" 2>/dev/null
  } > "$DIAG_DIR/environment.txt" 2>&1
}
save_environment_snapshot

# package_diagnostics -- called once, from cleanup(), as the last
# thing this script does. Extracts a quick PASS/FAIL-only summary from
# the transcript (for a fast look without wading through everything),
# tars up the staging directory, and removes the staging directory so
# only the single tarball is left behind.
package_diagnostics() {
  grep -E '^(PASS|FAIL):' "$DIAG_DIR/transcript.log" > "$DIAG_DIR/summary.txt" 2>/dev/null || true
  echo "$PASS passed, $FAIL failed" >> "$DIAG_DIR/summary.txt"
  ( cd "$DIAG_DIR" && tar czf "$DIAG_TARBALL" . ) 2>/dev/null
  rm -rf "$DIAG_DIR"
  echo
  echo "Diagnostics bundle: $DIAG_TARBALL"
}

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

# wait_for_log_pattern DIR PATTERN [SIZE_BEFORE] [MAX_TRIES]
#
# Polls DIR/sbcl-output.log for PATTERN (a grep -q pattern), looking
# only at content appended after SIZE_BEFORE bytes (so a log that
# already contains a matching line from earlier in this test run
# doesn't produce a false-positive the instant this is called).
# Returns 0 once found, 1 after MAX_TRIES * 0.1s (default 15s).
#
# This exists because a fixed sleep is not a reliable way to know the
# bridge has reached some later point in its startup sequence:
# sbcl-bridge.lisp is loaded fresh via --load (compiled from source,
# not a precompiled fasl) on every start, and how long that takes
# varies with machine speed, system load, and how much code the file
# has grown to contain -- a sleep comfortably long enough on one
# machine can flake on a slower or busier one. Most checks in this
# suite are naturally immune to this because they submit through
# sbcl-client.sh, which already retries for up to SBCL_TIMEOUT on its
# own; this helper is for the few checks that inspect
# sbcl-output.log directly, with no such retry.
wait_for_log_pattern() {
  local pattern="$2" size_before="${3:-0}" max_tries="${4:-150}" i log="$1/sbcl-output.log"
  for ((i = 0; i < max_tries; i++)); do
    if [ -f "$log" ]; then
      local cur_size
      cur_size=$(wc -c < "$log" 2>/dev/null || echo 0)
      if [ "$cur_size" -gt "$size_before" ] && \
         tail -c +"$((size_before + 1))" "$log" 2>/dev/null | grep -Eq "$pattern"; then
        echo "  (wait_for_log_pattern: '$pattern' seen after ~$(awk -v i="$i" 'BEGIN{printf "%.1f", i*0.1}')s)"
        return 0
      fi
    fi
    sleep 0.1
  done
  echo "  (wait_for_log_pattern: TIMED OUT after ${max_tries}0.1s waiting for '$pattern' in $log)"
  echo "  --- new content of $log since byte $size_before (if any) ---"
  if [ -f "$log" ]; then
    tail -c +"$((size_before + 1))" "$log" 2>/dev/null | sed 's/^/  | /'
  else
    echo "  | (file does not exist)"
  fi
  echo "  --- end ---"
  return 1
}

# wait_for_bridge_ready DIR [SIZE_BEFORE] [MAX_TRIES]
# The common case of wait_for_log_pattern: wait for the bridge to have
# fully started (the "SBCL-BRIDGE STARTED" banner).
wait_for_bridge_ready() {
  wait_for_log_pattern "$1" "SBCL-BRIDGE STARTED" "${2:-0}" "${3:-150}"
}

cleanup() {
  "$CTL" stop >/dev/null 2>&1 || true
  save_bridge_logs "main" "$SBCL_BRIDGE_DIR"
  rm -rf "$SBCL_BRIDGE_DIR"
  package_diagnostics
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
wait_for_bridge_ready "$SBCL_BRIDGE_DIR" || { echo "FATAL: bridge did not report ready in time; check $SBCL_BRIDGE_DIR/sbcl-output.log"; exit 1; }

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
save_bridge_logs "preflight" "$PREFLIGHT_DIR"
rm -rf "$PREFLIGHT_DIR"

# --- Quicklisp integration: opt-in, reader-safety, graceful failure ----
#
# Full coverage of the sync logic itself (redirecting an
# already-loaded Quicklisp's *quicklisp-home* and
# *local-project-directories* when QUICKLISP_HOME changes between a
# suspend and a resume) needs a real Quicklisp installation and isn't
# included here, deliberately: it would make this otherwise
# offline/fast suite depend on network reachability to
# beta.quicklisp.org, which is exactly the kind of external dependency
# this suite is designed to avoid. What's tested here is everything
# that IS deterministic and network-independent: the feature is purely
# opt-in (silent no-op with QUICKLISP_HOME unset), loading
# sbcl-bridge.lisp can never break for users who don't use this
# feature at all (see the comment at the top of the "Quicklisp
# integration" section in sbcl-bridge.lisp for why that's a real risk
# in Common Lisp and not just caution), and a QUICKLISP_HOME that
# can't be satisfied degrades gracefully rather than affecting the
# rest of the bridge.
#
# The "can't be satisfied" case is forced via QUICKLISP_INSTALLER_URL
# (pointed at a guaranteed-unreachable local address), not by trying to
# shadow curl/wget on PATH. An earlier version of this suite did the
# latter, and it was a genuine, machine-dependent bug, not just
# over-caution: SB-EXT:RUN-PROGRAM's :search silently falls through to
# the NEXT candidate on PATH if the first one it finds exists but can't
# actually be executed (a read-only or noexec-mounted temp directory is
# enough to trigger this) -- so on at least one real machine, the
# "fake" curl was skipped right past and the REAL one ran, reached the
# real beta.quicklisp.org, and genuinely installed Quicklisp
# successfully.
#
# QUICKLISP_INSTALLER_URL turned out not to be a complete fix either,
# and this is worth understanding rather than just patching around: it
# only controls step 4 of LOCATE-QUICKLISP-INSTALLER (downloading a
# fresh copy of the quicklisp.lisp bootstrap SCRIPT). It has no effect
# at all if steps 1-3 already find one -- in particular, a real machine
# with Quicklisp's Debian/Ubuntu package installed at the usual system
# path (§8.7) supplies a perfectly good installer via step 2, and this
# override is never even consulted. And even in the case this override
# DOES apply, it only blocks fetching the bootstrap SCRIPT -- once
# INSTALL-QUICKLISP-IF-NEEDED has ANY usable installer in hand, from
# ANY of the four sources, calling quicklisp-quickstart:install does
# its OWN, completely separate round of network I/O against
# hardcoded beta.quicklisp.org URLs baked into that script, which
# nothing in sbcl-bridge.lisp has any hook into at all.
#
# Put simply: there is no environment variable, PATH trick, or other
# portable mechanism available to this test that can reliably force
# Quicklisp installation to fail on a machine that has a real,
# legitimate path to a working Quicklisp -- and trying to characterize
# every such path well enough to block all of them turned out to be a
# losing battle. A genuine, successful install on such a machine isn't
# a bug to work around; it's this feature working correctly. So rather
# than forcing one specific outcome, this test accepts EITHER a
# successful install or a graceful failure as correct, and asserts the
# one thing that actually matters regardless of which happens: the
# bridge stays healthy and usable either way. QUICKLISP_INSTALLER_URL
# is still set below -- it's real, useful, documented behavior (an
# internal-mirror override) worth exercising even though it can't be
# relied on alone to force this test's outcome.
QL_TEST_DIR="$(mktemp -d)"

if env -u QUICKLISP_HOME -u QUICKLISP_LISP \
     SBCL_BRIDGE_DIR="$QL_TEST_DIR/unset" SBCL_BRIDGE_LISP="$SBCL_BRIDGE_LISP" \
     "$CTL" start >/dev/null 2>&1; then
  if wait_for_bridge_ready "$QL_TEST_DIR/unset" && \
     ! grep -q QUICKLISP "$QL_TEST_DIR/unset/sbcl-output.log"; then
    ok "Quicklisp support is a silent no-op with QUICKLISP_HOME unset"
  else
    bad "Quicklisp support is a silent no-op with QUICKLISP_HOME unset"
  fi
  SBCL_BRIDGE_DIR="$QL_TEST_DIR/unset" "$CTL" stop >/dev/null 2>&1
else
  bad "Quicklisp support is a silent no-op with QUICKLISP_HOME unset (bridge failed to start)"
fi

if sbcl --noinform --non-interactive --no-sysinit --no-userinit \
     --eval "(load \"$SBCL_BRIDGE_LISP\")" \
     --eval '(princ (list :ql (find-package "QL") :ql-setup (find-package "QL-SETUP")))' \
     2>/dev/null | grep -qF '(QL NIL QL-SETUP NIL)'; then
  ok "loading sbcl-bridge.lisp never creates Quicklisp packages by itself"
else
  bad "loading sbcl-bridge.lisp never creates Quicklisp packages by itself"
fi

if env -u QUICKLISP_LISP \
     QUICKLISP_HOME="$QL_TEST_DIR/never-installed" \
     QUICKLISP_INSTALLER_URL="http://127.0.0.1:1/quicklisp.lisp" \
     XDG_CACHE_HOME="$QL_TEST_DIR/cache" \
     SBCL_BRIDGE_DIR="$QL_TEST_DIR/degrade" SBCL_BRIDGE_LISP="$SBCL_BRIDGE_LISP" \
     "$CTL" start >/dev/null 2>&1; then
  # Wait for the install ATTEMPT to actually finish, one way or the
  # other, not just for the bridge to have started -- a real install
  # (network reachable, or a system-installed quicklisp.lisp found)
  # takes noticeably longer than a fast local failure, and both are
  # valid outcomes here.
  if wait_for_log_pattern "$QL_TEST_DIR/degrade" \
       "installed at|continuing without .*this session|install failed" \
       0 300; then
    DEGRADE_LOG="$QL_TEST_DIR/degrade/sbcl-output.log"
    BRIDGE_OK=0
    env SBCL_BRIDGE_DIR="$QL_TEST_DIR/degrade" "$CLIENT" eval '(+ 40 2)' 2>/dev/null \
      | grep -q '^;;; => 42$' && BRIDGE_OK=1

    QL_OK=1
    if grep -q "QUICKLISP: installed at" "$DEGRADE_LOG"; then
      echo "  (this machine has a real path to Quicklisp -- a genuine install succeeded, which is correct)"
      env SBCL_BRIDGE_DIR="$QL_TEST_DIR/degrade" "$CLIENT" \
        eval "(and (find-package \"QL-SETUP\")
                    (equal (truename ql:*quicklisp-home*)
                           (truename #P\"$QL_TEST_DIR/never-installed/\")))" \
        2>/dev/null | grep -q '^;;; => T$' || QL_OK=0
    else
      echo "  (this machine could not complete a real install -- confirming graceful degradation instead)"
    fi

    if [ "$BRIDGE_OK" -eq 1 ] && [ "$QL_OK" -eq 1 ]; then
      ok "Quicklisp install attempt (success or failure) leaves the bridge usable"
    else
      bad "Quicklisp install attempt (success or failure) leaves the bridge usable"
    fi
  else
    bad "Quicklisp install attempt (success or failure) leaves the bridge usable (no terminal QUICKLISP message seen)"
  fi
  SBCL_BRIDGE_DIR="$QL_TEST_DIR/degrade" "$CTL" stop >/dev/null 2>&1
else
  bad "Quicklisp install attempt (success or failure) leaves the bridge usable (bridge failed to start)"
fi

save_bridge_logs "quicklisp-unset" "$QL_TEST_DIR/unset"
save_bridge_logs "quicklisp-degrade" "$QL_TEST_DIR/degrade"
rm -rf "$QL_TEST_DIR"

# --- ASDF output-translations (fasl cache) relocation -------------------
#
# Same class of bug as the Quicklisp-home sync above, and tested the
# same way: force a real resume with XDG_CACHE_HOME changed, and check
# that ASDF's actual in-use output-translations (not just the
# intermediate uiop:*user-cache* variable) follow it. Unlike the
# Quicklisp case, this doesn't need an "install" or "not yet loaded"
# branch -- ASDF/UIOP either isn't loaded in the image yet (nothing to
# fix; it'll compute correctly whenever it does get loaded) or it is,
# in which case the only question is whether XDG_CACHE_HOME has moved
# since. ASDF's own caching means (require :asdf) and the first real
# use (asdf:ensure-output-translations, which asdf:find-system calls
# internally) must be SEPARATE requests here, not one -- combined into
# a single (progn ...), the reader would need to resolve the asdf:
# symbols before (require :asdf) in the same form ever got a chance to
# run, which is exactly the reader-error class of bug this file's own
# indirection helpers exist to avoid.
ASDF_TEST_DIR="$(mktemp -d)"

if sbcl --noinform --non-interactive --no-sysinit --no-userinit \
     --eval "(load \"$SBCL_BRIDGE_LISP\")" \
     --eval '(princ (list :uiop (find-package "UIOP") :asdf (find-package "ASDF")))' \
     2>/dev/null | grep -qF '(UIOP NIL ASDF NIL)'; then
  ok "loading sbcl-bridge.lisp never creates ASDF/UIOP packages by itself"
else
  bad "loading sbcl-bridge.lisp never creates ASDF/UIOP packages by itself"
fi

if env -u XDG_CACHE_HOME SBCL_BRIDGE_DIR="$ASDF_TEST_DIR/unset" SBCL_BRIDGE_LISP="$SBCL_BRIDGE_LISP" \
     "$CTL" start >/dev/null 2>&1; then
  if wait_for_bridge_ready "$ASDF_TEST_DIR/unset" && \
     ! grep -q "ASDF:" "$ASDF_TEST_DIR/unset/sbcl-output.log"; then
    ok "ASDF cache relocation is a silent no-op with XDG_CACHE_HOME unset"
  else
    bad "ASDF cache relocation is a silent no-op with XDG_CACHE_HOME unset"
  fi
  env SBCL_BRIDGE_DIR="$ASDF_TEST_DIR/unset" "$CTL" stop >/dev/null 2>&1
else
  bad "ASDF cache relocation is a silent no-op with XDG_CACHE_HOME unset (bridge failed to start)"
fi

ASDF_CACHE_A="$ASDF_TEST_DIR/cache-a"
ASDF_CACHE_B="$ASDF_TEST_DIR/cache-b"
mkdir -p "$ASDF_CACHE_A" "$ASDF_CACHE_B"
if env XDG_CACHE_HOME="$ASDF_CACHE_A" SBCL_BRIDGE_DIR="$ASDF_TEST_DIR/relocate" SBCL_BRIDGE_LISP="$SBCL_BRIDGE_LISP" \
     "$CTL" start >/dev/null 2>&1; then
  wait_for_bridge_ready "$ASDF_TEST_DIR/relocate"
  env SBCL_BRIDGE_DIR="$ASDF_TEST_DIR/relocate" "$CLIENT" eval '(require :asdf)' >/dev/null 2>&1
  BEFORE="$(env SBCL_BRIDGE_DIR="$ASDF_TEST_DIR/relocate" "$CLIENT" eval \
    '(progn (asdf:ensure-output-translations) (namestring (asdf:apply-output-translations #P"/some/source/file.lisp")))' 2>/dev/null)"

  # Unchanged resume must NOT log a spurious relocation -- this is the
  # exact bug PATHS-EQUAL-P (truename-based) would have reintroduced
  # here: the cache directory this points at has deliberately not been
  # written to yet, so TRUENAME would fail to resolve it on both sides
  # and spuriously report "different" even though nothing changed.
  SIZE_BEFORE_UNCHANGED=$(wc -c < "$ASDF_TEST_DIR/relocate/sbcl-output.log" 2>/dev/null || echo 0)
  env SBCL_BRIDGE_DIR="$ASDF_TEST_DIR/relocate" "$CTL" suspend >/dev/null 2>&1
  env XDG_CACHE_HOME="$ASDF_CACHE_A" SBCL_BRIDGE_DIR="$ASDF_TEST_DIR/relocate" "$CTL" resume >/dev/null 2>&1
  wait_for_bridge_ready "$ASDF_TEST_DIR/relocate" "$SIZE_BEFORE_UNCHANGED"
  if tail -c +"$((SIZE_BEFORE_UNCHANGED + 1))" "$ASDF_TEST_DIR/relocate/sbcl-output.log" 2>/dev/null | grep -q "ASDF:"; then
    bad "unchanged XDG_CACHE_HOME across a resume reports no spurious relocation"
  else
    ok "unchanged XDG_CACHE_HOME across a resume reports no spurious relocation"
  fi

  # Now the real test: resume with XDG_CACHE_HOME genuinely changed.
  SIZE_BEFORE_CHANGED=$(wc -c < "$ASDF_TEST_DIR/relocate/sbcl-output.log" 2>/dev/null || echo 0)
  env SBCL_BRIDGE_DIR="$ASDF_TEST_DIR/relocate" "$CTL" suspend >/dev/null 2>&1
  env XDG_CACHE_HOME="$ASDF_CACHE_B" SBCL_BRIDGE_DIR="$ASDF_TEST_DIR/relocate" "$CTL" resume >/dev/null 2>&1
  wait_for_bridge_ready "$ASDF_TEST_DIR/relocate" "$SIZE_BEFORE_CHANGED"
  AFTER="$(env SBCL_BRIDGE_DIR="$ASDF_TEST_DIR/relocate" "$CLIENT" eval \
    '(namestring (asdf:apply-output-translations #P"/some/source/file.lisp"))' 2>/dev/null)"

  if printf '%s' "$BEFORE" | grep -qF "$ASDF_CACHE_A" \
     && printf '%s' "$AFTER" | grep -qF "$ASDF_CACHE_B" \
     && ! printf '%s' "$AFTER" | grep -qF "$ASDF_CACHE_A"; then
    ok "resume with a changed XDG_CACHE_HOME relocates ASDF's fasl cache"
  else
    bad "resume with a changed XDG_CACHE_HOME relocates ASDF's fasl cache"
  fi
  env SBCL_BRIDGE_DIR="$ASDF_TEST_DIR/relocate" "$CTL" stop >/dev/null 2>&1
else
  bad "resume with a changed XDG_CACHE_HOME relocates ASDF's fasl cache (bridge failed to start)"
fi

save_bridge_logs "asdf-unset" "$ASDF_TEST_DIR/unset"
save_bridge_logs "asdf-relocate" "$ASDF_TEST_DIR/relocate"
rm -rf "$ASDF_TEST_DIR"

# --- CL_SOURCE_REGISTRY relocation ---------------------------------------
#
# Same class of bug as the other two, and found the same way: two real
# directories, each with its own trivial .asd system, so "is the right
# system findable" can be checked directly rather than inferred from
# compile output. Unlike the ASDF-cache tests, this doesn't need an
# unreachable-network trick anywhere -- CL_SOURCE_REGISTRY just points
# at local directories.
#
# The "unchanged resume must not report a false change" check here is
# not paranoia for its own sake -- it's the exact bug this feature
# shipped with initially. ENSURE-CL-SOURCE-REGISTRY-CONFIGURED runs
# once per bridge start/resume, almost always BEFORE a user's own
# request has gotten around to loading ASDF at all, so the first
# version of this function only recorded its "last known
# CL_SOURCE_REGISTRY" baseline when ASDF happened to already be loaded
# -- which, on the ordinary first pre-suspend session, it never was at
# the one moment this function got to check. The result: baseline
# stayed NIL for the whole session even though a request loaded ASDF
# and correctly computed its source-registry from that same,
# unchanged CL_SOURCE_REGISTRY moments later -- and the NEXT resume,
# even with CL_SOURCE_REGISTRY completely unchanged, would compare a
# real string against that stale NIL and report a spurious "changed"
# every single time.
CSR_TEST_DIR="$(mktemp -d)"
CSR_DIR_A="$CSR_TEST_DIR/systems-a"
CSR_DIR_B="$CSR_TEST_DIR/systems-b"
mkdir -p "$CSR_DIR_A" "$CSR_DIR_B"
cat > "$CSR_DIR_A/smoke-test-system-a.asd" <<'EOF'
(defsystem "smoke-test-system-a" :components ())
EOF
cat > "$CSR_DIR_B/smoke-test-system-b.asd" <<'EOF'
(defsystem "smoke-test-system-b" :components ())
EOF

if env -u CL_SOURCE_REGISTRY SBCL_BRIDGE_DIR="$CSR_TEST_DIR/unset" SBCL_BRIDGE_LISP="$SBCL_BRIDGE_LISP" \
     "$CTL" start >/dev/null 2>&1; then
  if wait_for_bridge_ready "$CSR_TEST_DIR/unset" && \
     ! grep -q "CL_SOURCE_REGISTRY" "$CSR_TEST_DIR/unset/sbcl-output.log"; then
    ok "CL_SOURCE_REGISTRY relocation is a silent no-op with it unset"
  else
    bad "CL_SOURCE_REGISTRY relocation is a silent no-op with it unset"
  fi
  env SBCL_BRIDGE_DIR="$CSR_TEST_DIR/unset" "$CTL" stop >/dev/null 2>&1
else
  bad "CL_SOURCE_REGISTRY relocation is a silent no-op with it unset (bridge failed to start)"
fi

if env CL_SOURCE_REGISTRY="$CSR_DIR_A//" SBCL_BRIDGE_DIR="$CSR_TEST_DIR/relocate" SBCL_BRIDGE_LISP="$SBCL_BRIDGE_LISP" \
     "$CTL" start >/dev/null 2>&1; then
  wait_for_bridge_ready "$CSR_TEST_DIR/relocate"
  env SBCL_BRIDGE_DIR="$CSR_TEST_DIR/relocate" "$CLIENT" eval '(require :asdf)' >/dev/null 2>&1
  FOUND_A_BEFORE="$(env SBCL_BRIDGE_DIR="$CSR_TEST_DIR/relocate" "$CLIENT" eval \
    '(not (null (asdf:find-system "smoke-test-system-a" nil)))' 2>/dev/null)"

  # Unchanged resume must NOT log a spurious relocation -- this is the
  # exact false positive described above.
  SIZE_BEFORE_UNCHANGED=$(wc -c < "$CSR_TEST_DIR/relocate/sbcl-output.log" 2>/dev/null || echo 0)
  env SBCL_BRIDGE_DIR="$CSR_TEST_DIR/relocate" "$CTL" suspend >/dev/null 2>&1
  env CL_SOURCE_REGISTRY="$CSR_DIR_A//" SBCL_BRIDGE_DIR="$CSR_TEST_DIR/relocate" "$CTL" resume >/dev/null 2>&1
  wait_for_bridge_ready "$CSR_TEST_DIR/relocate" "$SIZE_BEFORE_UNCHANGED"
  if tail -c +"$((SIZE_BEFORE_UNCHANGED + 1))" "$CSR_TEST_DIR/relocate/sbcl-output.log" 2>/dev/null | grep -q "CL_SOURCE_REGISTRY"; then
    bad "unchanged CL_SOURCE_REGISTRY across a resume reports no spurious relocation"
  else
    ok "unchanged CL_SOURCE_REGISTRY across a resume reports no spurious relocation"
  fi

  # Now the real test: resume with CL_SOURCE_REGISTRY genuinely changed.
  SIZE_BEFORE_CHANGED=$(wc -c < "$CSR_TEST_DIR/relocate/sbcl-output.log" 2>/dev/null || echo 0)
  env SBCL_BRIDGE_DIR="$CSR_TEST_DIR/relocate" "$CTL" suspend >/dev/null 2>&1
  env CL_SOURCE_REGISTRY="$CSR_DIR_B//" SBCL_BRIDGE_DIR="$CSR_TEST_DIR/relocate" "$CTL" resume >/dev/null 2>&1
  wait_for_bridge_ready "$CSR_TEST_DIR/relocate" "$SIZE_BEFORE_CHANGED"
  RESULT_AFTER="$(env SBCL_BRIDGE_DIR="$CSR_TEST_DIR/relocate" "$CLIENT" eval \
    '(list (not (null (asdf:find-system "smoke-test-system-a" nil)))
           (not (null (asdf:find-system "smoke-test-system-b" nil))))' 2>/dev/null)"

  if printf '%s' "$FOUND_A_BEFORE" | grep -q '^;;; => T$' \
     && printf '%s' "$RESULT_AFTER" | grep -q '(T T)'; then
    ok "resume with a changed CL_SOURCE_REGISTRY relocates ASDF's source registry"
  else
    bad "resume with a changed CL_SOURCE_REGISTRY relocates ASDF's source registry"
  fi
  env SBCL_BRIDGE_DIR="$CSR_TEST_DIR/relocate" "$CTL" stop >/dev/null 2>&1
else
  bad "resume with a changed CL_SOURCE_REGISTRY relocates ASDF's source registry (bridge failed to start)"
fi

save_bridge_logs "cl-source-registry-unset" "$CSR_TEST_DIR/unset"
save_bridge_logs "cl-source-registry-relocate" "$CSR_TEST_DIR/relocate"
rm -rf "$CSR_TEST_DIR"

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

SIZE_BEFORE_RESUME=$(wc -c < "$SBCL_BRIDGE_DIR/sbcl-output.log" 2>/dev/null || echo 0)
if "$CTL" resume >/dev/null 2>&1; then
  ok "resume restarts from the saved core"
else
  bad "resume restarts from the saved core"
fi
wait_for_bridge_ready "$SBCL_BRIDGE_DIR" "$SIZE_BEFORE_RESUME"

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
# Exclude cores/current.core itself: that's a pointer TO the just-saved
# core (see UPDATE_CURRENT_CORE_SYMLINK in sbcl-bridge-ctl.sh), not a
# core image of its own -- `ls -t` sorting by mtime would otherwise
# often put it first (a symlink's own mtime updates whenever it's
# re-pointed), and `cp` preserves the SYMLINK'S name, not its target's,
# so the copy below would land as "current.core" in $MOVED_DIR/cores/ --
# a name cmd_resume's own core selection deliberately treats as "not a
# real core" and refuses to pick, exactly the same way ctl.sh's own
# list_cores_by_age does.
MOVED_CORE="$(ls -t "$SBCL_BRIDGE_DIR"/cores/*.core 2>/dev/null | grep -v '/current\.core$' | head -1)"
MOVED_DIR="$(mktemp -d)"
if [ -n "$MOVED_CORE" ]; then
  mkdir -p "$MOVED_DIR/cores"
  cp "$MOVED_CORE" "$MOVED_DIR/cores/"
  [ -f "$MOVED_CORE.version" ] && cp "$MOVED_CORE.version" "$MOVED_DIR/cores/"
  chmod +x "$MOVED_DIR"/cores/*.core

  ORIG_BRIDGE_DIR="$SBCL_BRIDGE_DIR"
  export SBCL_BRIDGE_DIR="$MOVED_DIR"
  "$CTL" resume >/dev/null 2>&1
  wait_for_bridge_ready "$MOVED_DIR"
  if "$CLIENT" eval '*moved-marker*' 2>/dev/null | grep -q ':STILL-HERE'; then
    ok "resume honors SBCL_BRIDGE_DIR pointing at a moved workspace"
  else
    bad "resume honors SBCL_BRIDGE_DIR pointing at a moved workspace"
  fi
  "$CTL" stop >/dev/null 2>&1

  # Restore the original bridge dir and state for the remaining tests.
  export SBCL_BRIDGE_DIR="$ORIG_BRIDGE_DIR"
  SIZE_BEFORE_RESUME=$(wc -c < "$SBCL_BRIDGE_DIR/sbcl-output.log" 2>/dev/null || echo 0)
  "$CTL" resume >/dev/null 2>&1
  wait_for_bridge_ready "$SBCL_BRIDGE_DIR" "$SIZE_BEFORE_RESUME"
else
  bad "resume honors SBCL_BRIDGE_DIR pointing at a moved workspace (no core found)"
fi
save_bridge_logs "moved-workspace" "$MOVED_DIR"
rm -rf "$MOVED_DIR"

# --- Resume into the SAME directory must not report a false "moved" --
#
# A real bug, not a hypothetical: a fresh `start` bakes in a trailing
# slash (ctl.sh's cmd_start appends one explicitly to the directory
# argument), but SBCL_BRIDGE_DIR as exported for a `resume` comes from
# a plain `pwd`, which never has one. Comparing those two spellings
# with a raw string/namestring compare instead of a normalized
# (truename-based) one reports a spurious "SBCL_BRIDGE_DIR overrides
# the directory saved in this image" on the FIRST resume after a fresh
# start -- even though nothing actually moved -- and then, confusingly,
# never again after that: the first (spurious) override overwrites the
# saved directory with the no-trailing-slash spelling, which then
# happens to match on every later resume regardless of whether the
# environment has genuinely changed. This needs its own fresh
# start/suspend/resume in an isolated directory to reproduce reliably:
# by the time other tests in this suite reach a resume, an earlier one
# may already have normalized the spelling away from the exact
# trailing-slash mismatch this depends on.
SLASH_DIR="$(mktemp -d)"
if env SBCL_BRIDGE_DIR="$SLASH_DIR" SBCL_BRIDGE_LISP="$SBCL_BRIDGE_LISP" "$CTL" start >/dev/null 2>&1; then
  wait_for_bridge_ready "$SLASH_DIR"
  env SBCL_BRIDGE_DIR="$SLASH_DIR" "$CTL" suspend >/dev/null 2>&1
  SIZE_BEFORE_SLASH_RESUME=$(wc -c < "$SLASH_DIR/sbcl-output.log" 2>/dev/null || echo 0)
  env SBCL_BRIDGE_DIR="$SLASH_DIR" "$CTL" resume >/dev/null 2>&1
  wait_for_bridge_ready "$SLASH_DIR" "$SIZE_BEFORE_SLASH_RESUME"
  if tail -c +"$((SIZE_BEFORE_SLASH_RESUME + 1))" "$SLASH_DIR/sbcl-output.log" 2>/dev/null | grep -q "RESUME:"; then
    bad "resume into the same directory reports no spurious 'overrides' message"
  else
    ok "resume into the same directory reports no spurious 'overrides' message"
  fi
  env SBCL_BRIDGE_DIR="$SLASH_DIR" "$CTL" stop >/dev/null 2>&1
else
  bad "resume into the same directory reports no spurious 'overrides' message (bridge failed to start)"
fi
save_bridge_logs "same-dir-resume" "$SLASH_DIR"
rm -rf "$SLASH_DIR"

# --- SBCL_BRIDGE_DIR with a trailing slash must never produce double
# --- slashes anywhere: ctl.sh's own messages, log output, or saved
# --- core paths.
#
# A real bug, found via a log line in production:
#   ;;; SUSPENDING to /workspace/sbcl-bridge//cores/bridge-....core
# SBCL_BRIDGE_DIR=/foo/bar/ is not an unreasonable thing for a caller
# to write, and every path in both ctl.sh and client.sh was built by
# plain string concatenation ("$BRIDGE_DIR/whatever") directly from
# whatever the caller supplied -- so a trailing slash in the input
# propagated into every single derived path. Harmless to the
# filesystem (POSIX collapses repeated slashes identically to one) but
# an avoidable, ugly rough edge that both scripts now close by
# normalizing the directory once, immediately, before anything else
# derives a path from it -- see the comment at the top of
# sbcl-bridge-ctl.sh.
#
# This checks ctl.sh's OWN suspend output directly (captured, not
# discarded), not just sbcl-output.log -- deliberately, because the
# Lisp side's independent pathname normalization (ensure-directory-
# pathname on the way in, and suspend-bridge's own core-path coercion)
# would clean up a double slash before it ever reached the log or an
# actual saved filename, masking a regression in ctl.sh's OWN
# construction specifically. ctl.sh's "Requesting suspend to
# $core_path ..." line is built and printed before any of that -- it's
# the one place a ctl.sh-only regression would be visible on its own.
SLASHDIR_BASE="$(mktemp -d)"
SLASHDIR_TRAILING="${SLASHDIR_BASE}/"
if env SBCL_BRIDGE_DIR="$SLASHDIR_TRAILING" SBCL_BRIDGE_LISP="$SBCL_BRIDGE_LISP" "$CTL" start >/dev/null 2>&1; then
  wait_for_bridge_ready "$SLASHDIR_BASE"
  env SBCL_BRIDGE_DIR="$SLASHDIR_TRAILING" "$CLIENT" eval '(+ 1 1)' >/dev/null 2>&1
  SUSPEND_OUTPUT="$(env SBCL_BRIDGE_DIR="$SLASHDIR_TRAILING" "$CTL" suspend 2>&1)"
  echo "$SUSPEND_OUTPUT"

  DOUBLE_SLASH_FOUND=0
  if printf '%s' "$SUSPEND_OUTPUT" | grep -qF '//'; then
    DOUBLE_SLASH_FOUND=1
  fi
  # Also check sbcl-output.log and the actual saved core filename, for
  # broader coverage of the Lisp side (scoped to path-bearing lines,
  # not a blanket check across the whole log -- the SBCL startup
  # banner itself contains "http://www.sbcl.org/", which a blanket "//"
  # check would misreport as a path bug).
  if grep -E "SBCL-BRIDGE STARTED|SUSPENDING to" "$SLASHDIR_BASE/sbcl-output.log" 2>/dev/null \
       | grep -qF '//'; then
    DOUBLE_SLASH_FOUND=1
  fi
  for f in "$SLASHDIR_BASE"/cores/*.core; do
    case "$f" in *//*) DOUBLE_SLASH_FOUND=1 ;; esac
  done

  if [ "$DOUBLE_SLASH_FOUND" -eq 0 ]; then
    ok "a trailing slash in SBCL_BRIDGE_DIR never produces a double slash anywhere"
  else
    bad "a trailing slash in SBCL_BRIDGE_DIR never produces a double slash anywhere"
  fi
  env SBCL_BRIDGE_DIR="$SLASHDIR_TRAILING" "$CTL" stop >/dev/null 2>&1
else
  bad "a trailing slash in SBCL_BRIDGE_DIR never produces a double slash anywhere (bridge failed to start)"
fi
save_bridge_logs "trailing-slash-dir" "$SLASHDIR_BASE"
rm -rf "$SLASHDIR_BASE"

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
  SIZE_BEFORE_RESUME=$(wc -c < "$SBCL_BRIDGE_DIR/sbcl-output.log" 2>/dev/null || echo 0)
  "$CTL" resume >/dev/null 2>&1
  wait_for_bridge_ready "$SBCL_BRIDGE_DIR" "$SIZE_BEFORE_RESUME"
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
