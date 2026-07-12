;;;; sbcl-client.lisp -- pure Common Lisp client/control library for
;;;; sbcl-bridge, runnable from any OTHER SBCL image (not the bridge
;;;; instance itself). Duplicates the functionality of
;;;; sbcl-bridge-ctl.sh and sbcl-client.sh as ordinary Lisp functions
;;;; and conditions, speaking the exact same on-disk protocol those
;;;; scripts do -- a bridge started with sbcl-bridge-ctl.sh can be
;;;; controlled from here, and a bridge started from here can be
;;;; controlled with sbcl-bridge-ctl.sh. Neither side knows or cares
;;;; which started it.
;;;;
;;;; This is maintained IN PARALLEL with the shell scripts, not as a
;;;; replacement for them -- see the README for when to reach for
;;;; which. Loading this file has no side effects beyond defining the
;;;; SBCL-BRIDGE-CLIENT package and its contents; nothing here starts,
;;;; stops, or talks to a bridge until you call something.
;;;;
;;;; Quick start:
;;;;   (load "sbcl-client.lisp")
;;;;   (sbcl-bridge-client:bridge-start :directory "/tmp/my-bridge")
;;;;   (sbcl-bridge-client:bridge-eval "(+ 1 2)")
;;;;   => "3"
;;;;   (sbcl-bridge-client:bridge-stop)
;;;;
;;;; Configuration mirrors the shell scripts' environment variables
;;;; exactly (same names, same defaults), read once at load time into
;;;; special variables of the same shape -- SBCL_BRIDGE_DIR into
;;;; *BRIDGE-DIR*, SBCL_POLL_INTERVAL into *POLL-INTERVAL*, and so on.
;;;; Every operation also accepts a :DIRECTORY keyword (and other
;;;; relevant keywords) to override the ambient default for just that
;;;; call, and the specials are ordinary DEFVAR/DEFPARAMETER forms you
;;;; can SETF or LET-bind like anything else -- there is no separate
;;;; "configure the library" step.

(defpackage #:sbcl-bridge-client
  (:use #:cl)
  (:nicknames #:sbcl-bridge-cl)
  (:export
   ;; configuration specials
   #:*bridge-dir* #:*bridge-lisp* #:*sbcl-bin*
   #:*poll-interval* #:*request-timeout* #:*wait-timeout*
   #:*core-retain* #:*processed-retain*
   #:*log-max-bytes* #:*log-retain* #:*mem-warn-mb*
   #:*stop-timeout* #:*suspend-timeout*
   ;; path accessors (mostly useful for introspection/debugging)
   #:bridge-pid-file #:bridge-output-log #:bridge-input-log
   #:bridge-async-error-log #:bridge-log-paths
   #:bridge-core-dir #:bridge-processed-dir #:bridge-log-archive-dir
   #:bridge-input-path
   ;; process management (sbcl-bridge-ctl.sh equivalents)
   #:bridge-running-p #:bridge-pid
   #:bridge-start #:bridge-stop #:bridge-restart #:bridge-status
   #:bridge-suspend #:bridge-resume #:bridge-refresh #:bridge-interrupt #:request-graceful-stop
   #:bridge-delete-core #:resolve-core-arg #:core-pinned-name
   #:current-core-path
   #:bridge-rotate-logs #:bridge-logs
   ;; client submission (sbcl-client.sh equivalent)
   #:bridge-eval #:bridge-eval-file
   #:make-request-id
   ;; conditions
   #:bridge-error
   #:bridge-not-running-error
   #:bridge-submission-timeout-error
   #:bridge-response-timeout-error
   #:bridge-evaluation-error
   #:bridge-request-timeout-error
   #:bridge-cancelled-error
   #:bridge-fatal-condition-error
   #:bridge-error-reqid
   #:bridge-error-output))

(in-package #:sbcl-bridge-client)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

;;; ---------------------------------------------------------------------
;;; Configuration
;;;
;;; Every default here is read from the SAME environment variable the
;;; shell scripts read, with the SAME fallback default, so a shell
;;; alias like `export SBCL_BRIDGE_DIR=/workspace/sbcl-bridge` already
;;; configures this library identically with zero Lisp-side setup.

(defun env (name &optional default)
  (let ((v (sb-ext:posix-getenv name)))
    (if (and v (plusp (length v))) v default)))

(defun env-number (name default)
  (let ((v (sb-ext:posix-getenv name)))
    (if (and v (plusp (length v)))
        (or (ignore-errors (parse-integer v :junk-allowed t)) default)
        default)))

(defvar *bridge-dir* (env "SBCL_BRIDGE_DIR" ".")
  "Directory the target bridge watches. Mirrors SBCL_BRIDGE_DIR.
Every function below also accepts :DIRECTORY to override this for one
call without rebinding the special.")

(defvar *bridge-lisp*
  (env "SBCL_BRIDGE_LISP"
       (namestring (merge-pathnames "sbcl-bridge.lisp" (or *load-pathname* *default-pathname-defaults*))))
  "Path to sbcl-bridge.lisp, used by BRIDGE-START. Mirrors
SBCL_BRIDGE_LISP; defaults to a file of that name alongside wherever
this file itself was loaded from, matching sbcl-bridge-ctl.sh's own
default of \"alongside this script\".")

(defvar *sbcl-bin* (env "SBCL_BIN" "sbcl")
  "sbcl executable used by BRIDGE-START and BRIDGE-RESUME. Mirrors
SBCL_BIN.")

(defvar *poll-interval* (let ((v (env "SBCL_POLL_INTERVAL")))
                           (if v (or (ignore-errors (read-from-string v)) 0.2) 0.2))
  "Seconds between checks while waiting for a response. Mirrors
SBCL_POLL_INTERVAL.")

(defvar *request-timeout* (env "SBCL_REQUEST_TIMEOUT")
  "Per-request bridge-side timeout override, as a string (\"30\",
\"none\", or NIL to omit and use the bridge's own default). Mirrors
SBCL_REQUEST_TIMEOUT. NIL by default -- unlike the shell client this
is not read as a number, since \"none\" is a legal value.")

(defvar *wait-timeout* (env-number "SBCL_TIMEOUT" nil)
  "Total seconds BRIDGE-EVAL waits before signaling a timeout error,
covering both queueing and response phases. Mirrors SBCL_TIMEOUT. NIL
means \"compute the default the way sbcl-client.sh does\" -- see
EFFECTIVE-WAIT-TIMEOUT.")

(defvar *core-retain* (env-number "SBCL_CORE_RETAIN" 3))
(defvar *processed-retain* (env-number "SBCL_PROCESSED_RETAIN" 200))
(defvar *log-max-bytes* (env-number "SBCL_LOG_MAX_BYTES" (* 10 1024 1024)))
(defvar *log-retain* (env-number "SBCL_LOG_RETAIN" 5))
(defvar *mem-warn-mb* (env-number "SBCL_MEM_WARN_MB" nil))
(defvar *stop-timeout* (env-number "SBCL_STOP_TIMEOUT" 10))
(defvar *suspend-timeout* (env-number "SBCL_SUSPEND_TIMEOUT" 60))

;;; ---------------------------------------------------------------------
;;; Pathname helpers
;;;
;;; ENSURE-DIRECTORY-PATHNAME is ported verbatim from sbcl-bridge.lisp
;;; -- the exact same trailing-slash pathname trap applies here, for
;;; the exact same reason: this library builds every other path by
;;; merging a filename against whatever directory the caller supplied,
;;; and a caller-supplied directory that still carries a spurious NAME
;;; component (because it lacked a trailing slash) would silently lose
;;; its last path segment the moment anything is merged against it.

(defun ensure-directory-pathname (path)
  "Coerce PATH (a string or pathname) into a proper directory
pathname -- one with no NAME or TYPE component of its own."
  (let ((p (pathname path)))
    (if (or (pathname-name p) (pathname-type p))
        (make-pathname
         :directory (append (or (pathname-directory p) '(:relative))
                             (list (file-namestring p)))
         :name nil :type nil
         :defaults p)
        p)))

(defun resolved-bridge-dir (&optional (directory *bridge-dir*))
  "DIRECTORY (defaulting to *BRIDGE-DIR*), normalized to an absolute,
directory pathname the same way sbcl-bridge-ctl.sh normalizes
BRIDGE_DIR at startup -- via TRUENAME, which requires the directory to
already exist. Signals a plain FILE-ERROR if it doesn't; callers that
need to CREATE a fresh bridge directory should ENSURE-DIRECTORIES-EXIST
it themselves first (BRIDGE-START does this automatically)."
  (truename (ensure-directory-pathname directory)))

(defun bridge-pid-file (&optional (directory *bridge-dir*))
  (merge-pathnames ".sbcl-bridge.pid" (ensure-directory-pathname directory)))

(defun bridge-output-log (&optional (directory *bridge-dir*))
  (merge-pathnames "sbcl-output.log" (ensure-directory-pathname directory)))

(defun bridge-input-log (&optional (directory *bridge-dir*))
  (merge-pathnames "sbcl-input.log" (ensure-directory-pathname directory)))

(defun bridge-async-error-log (&optional (directory *bridge-dir*))
  (merge-pathnames "sbcl-async-errors.log" (ensure-directory-pathname directory)))

(defun bridge-input-path (&optional (directory *bridge-dir*))
  (merge-pathnames "next-sbcl-input.lisp" (ensure-directory-pathname directory)))

(defun bridge-core-dir (&optional (directory *bridge-dir*))
  (merge-pathnames "cores/" (ensure-directory-pathname directory)))

(defun bridge-processed-dir (&optional (directory *bridge-dir*))
  (merge-pathnames "processed/" (ensure-directory-pathname directory)))

(defun bridge-log-archive-dir (&optional (directory *bridge-dir*))
  (merge-pathnames "logs/" (ensure-directory-pathname directory)))

(defun bridge-cancel-file (&optional (directory *bridge-dir*))
  (merge-pathnames "cancel-request" (ensure-directory-pathname directory)))

(defun bridge-stop-file (&optional (directory *bridge-dir*))
  (merge-pathnames "stop-request" (ensure-directory-pathname directory)))

;;; ---------------------------------------------------------------------
;;; Process liveness
;;;
;;; Mirrors sbcl-bridge-ctl.sh's IS_RUNNING exactly, including its
;;; PID-recycling guard (checking /proc/PID/cmdline looks sbcl-like,
;;; not just that SOME process with that PID exists).

(defun slurp-proc-file (path)
  "Read PATH (a /proc special file, whose stat-reported size is
unreliable -- often 0 even though read() returns real content, since
the kernel generates it on demand rather than storing it at a fixed
size) fully, in a loop until EOF, rather than trusting FILE-LENGTH.
Returns the raw bytes as a simple-vector of (unsigned-byte 8), or NIL
if the file can't be opened (process gone, no permission, etc.)."
  (ignore-errors
    (with-open-file (s path :element-type '(unsigned-byte 8) :if-does-not-exist nil)
      (unless s (return-from slurp-proc-file nil))
      (let ((buf (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
            (chunk (make-array 4096 :element-type '(unsigned-byte 8))))
        (loop for n = (read-sequence chunk s)
              while (plusp n)
              do (loop for i below n do (vector-push-extend (aref chunk i) buf)))
        (coerce buf 'simple-vector)))))

(defun process-alive-p (pid)
  "T if a process with PID exists and is signalable by us (the
Lisp-level equivalent of `kill -0 PID`), NIL otherwise."
  (and pid
       (ignore-errors (sb-posix:kill pid 0) t)))

(defun looks-like-sbcl-p (pid)
  "T if PID's /proc/PID/cmdline contains \"sbcl\" or \".core\" --
guards against a PID recycled by an unrelated process after a crash,
exactly like sbcl-bridge-ctl.sh's own check. Where /proc isn't
available at all (non-Linux), returns T unconditionally -- degrading
to trusting PROCESS-ALIVE-P alone, same as the shell version."
  (let ((bytes (slurp-proc-file (format nil "/proc/~a/cmdline" pid))))
    (if (null bytes)
        (not (probe-file "/proc/"))
        (let ((str (map 'string (lambda (b) (if (zerop b) #\Space (code-char b))) bytes)))
          (or (search "sbcl" str) (search ".core" str) nil)))))

(defun bridge-pid (&optional (directory *bridge-dir*))
  "The PID recorded in DIRECTORY's .sbcl-bridge.pid file, as an
integer, or NIL if there's no pidfile (or it's unreadable/empty).
Does NOT check whether that PID is actually alive -- see
BRIDGE-RUNNING-P for that."
  (let ((path (bridge-pid-file directory)))
    (and (probe-file path)
         (with-open-file (s path :if-does-not-exist nil)
           (and s (ignore-errors (parse-integer (read-line s nil ""))))))))

(defun bridge-running-p (&optional (directory *bridge-dir*))
  "T if DIRECTORY has a live, sbcl-like bridge process recorded, NIL
otherwise (no pidfile, stale pidfile, or a recycled/unrelated PID)."
  (let ((pid (bridge-pid directory)))
    (and pid (process-alive-p pid) (looks-like-sbcl-p pid) t)))

;;; ---------------------------------------------------------------------
;;; Conditions
;;;
;;; Where sbcl-client.sh distinguishes outcomes by numeric exit code,
;;; this library signals a condition -- more idiomatic for a library
;;; meant to be called from other Lisp code, and it lets every relevant
;;; detail (the reqid, the raw response text) travel with the
;;; condition instead of being lost the moment a shell script's exit
;;; code is checked. The hierarchy mirrors sbcl-client.sh's exit codes
;;; 1-7 one-to-one; see each condition's docstring for which.

(define-condition bridge-error (error)
  ((reqid :initarg :reqid :initform nil :reader bridge-error-reqid)
   (output :initarg :output :initform nil :reader bridge-error-output)
   (elapsed-ms :initarg :elapsed-ms :initform nil :reader bridge-error-elapsed-ms)
   (consed-bytes :initarg :consed-bytes :initform nil :reader bridge-error-consed-bytes))
  (:documentation "Base condition for everything this library signals.
BRIDGE-ERROR-REQID and BRIDGE-ERROR-OUTPUT are populated where
applicable (nil when the request was never delivered at all -- see
BRIDGE-NOT-RUNNING-ERROR and BRIDGE-SUBMISSION-TIMEOUT-ERROR).
BRIDGE-ERROR-ELAPSED-MS and BRIDGE-ERROR-CONSED-BYTES are populated
whenever a response actually arrived (parsed from its END-OUTPUT
marker), nil otherwise -- knowing how much time/memory a request burned
before erroring, timing out, or being cancelled is itself useful
diagnostic information.")
  (:report (lambda (c stream)
             (format stream "sbcl-bridge error~@[ (reqid ~a)~]~@[: ~a~]"
                     (bridge-error-reqid c) (bridge-error-output c)))))

(define-condition bridge-not-running-error (bridge-error) ()
  (:documentation "No live, sbcl-like bridge found watching the target
directory. Mirrors sbcl-client.sh's exit code 6 -- a preflight failure;
nothing was ever submitted.")
  (:report (lambda (c stream)
             (format stream "No bridge running against the target directory~@[: ~a~]"
                     (bridge-error-output c)))))

(define-condition bridge-submission-timeout-error (bridge-error) ()
  (:documentation "The request was fully formed locally, but the input
slot never freed up within the wait budget -- another request stayed
queued the whole time. Mirrors exit code 7: the bridge is busy, not
broken; retrying may help.")
  (:report (lambda (c stream)
             (format stream "Timed out waiting for the bridge's input slot to free up (reqid ~a)"
                     (bridge-error-reqid c)))))

(define-condition bridge-response-timeout-error (bridge-error) ()
  (:documentation "The request WAS submitted, but no response arrived
within the wait budget. Mirrors exit code 2. The bridge may still be
working on it.")
  (:report (lambda (c stream)
             (format stream "Timed out waiting for a response (reqid ~a)"
                     (bridge-error-reqid c)))))

(define-condition bridge-evaluation-error (bridge-error) ()
  (:documentation "The bridge reported status=error: an ERROR
condition was signalled while evaluating the submitted code. Mirrors
exit code 1. BRIDGE-ERROR-OUTPUT carries the bridge's own error report
and backtrace text.")
  (:report (lambda (c stream)
             (format stream "Evaluation error (reqid ~a):~%~a"
                     (bridge-error-reqid c) (bridge-error-output c)))))

(define-condition bridge-request-timeout-error (bridge-error) ()
  (:documentation "The bridge reported status=timeout: its own
per-request timeout (SBCL_REQUEST_TIMEOUT / an embedded TIMEOUT
header) expired. Mirrors exit code 3.")
  (:report (lambda (c stream)
             (format stream "Bridge-side evaluation timeout (reqid ~a)"
                     (bridge-error-reqid c)))))

(define-condition bridge-cancelled-error (bridge-error) ()
  (:documentation "The bridge reported status=cancelled (via
BRIDGE-INTERRUPT or ctl.sh interrupt). Mirrors exit code 4.")
  (:report (lambda (c stream)
             (format stream "Request cancelled (reqid ~a)" (bridge-error-reqid c)))))

(define-condition bridge-fatal-condition-error (bridge-error) ()
  (:documentation "The bridge reported status=fatal-condition: a
non-ERROR SERIOUS-CONDITION occurred. Mirrors exit code 5.")
  (:report (lambda (c stream)
             (format stream "Fatal (non-error) condition (reqid ~a):~%~a"
                     (bridge-error-reqid c) (bridge-error-output c)))))

;;; ---------------------------------------------------------------------
;;; bridge-start / bridge-stop / bridge-restart
;;;
;;; BRIDGE-START shells out to the actual `setsid` utility, the same
;;; way sbcl-bridge-ctl.sh does, rather than reimplementing session
;;; detachment via SB-POSIX:SETSID + fork/exec -- getting a background
;;; process to correctly survive the spawning process's own exit
;;; (surviving a terminal hangup, reparenting to init, etc.) is exactly
;;; what the `setsid` command already does correctly, and re-deriving
;;; that from SBCL's lower-level POSIX bindings would be a lot of
;;; fragile ceremony for no behavioral difference. Both the shell tools
;;; and this library end up spawning the literal same command line.

(defun lisp-string-literal (string)
  "Print STRING as a double-quoted Lisp string literal (escaping
backslash and double-quote), for embedding a filesystem path into a
generated --eval argument -- the same escaping sbcl-bridge-ctl.sh's own
lisp_string does, and for the identical reason: a path containing \" or
\\ must not be able to break out of the string literal it's placed in."
  (with-output-to-string (s)
    (write-char #\" s)
    (loop for c across string
          do (when (or (char= c #\") (char= c #\\)) (write-char #\\ s))
             (write-char c s))
    (write-char #\" s)))

(defun bridge-start (&key (directory *bridge-dir*)
                          (bridge-lisp *bridge-lisp*)
                          (sbcl-bin *sbcl-bin*))
  "Cold-start a fresh bridge process watching DIRECTORY. A no-op,
returning NIL, if a bridge is already running there (matching
sbcl-bridge-ctl.sh's \"Already running\" behavior) -- returns the new
PID on an actual start. Signals BRIDGE-ERROR if BRIDGE-LISP doesn't
exist, or if the process doesn't look alive within a few seconds of
spawning it.

This function's own BRIDGE-RUNNING-P check above is a cheap first line
of defense against two callers racing to start a bridge on the same
DIRECTORY at once -- it does not, on its own, close that race (both
could pass it before either's process is actually up). The authoritative
guard against that is now inside sbcl-bridge.lisp's RUN-BRIDGE itself
(CLAIM-PID-FILE), which refuses to let a second bridge run against a
directory another confirmed-live one is already watching. So a
returned PID here, in the rare case of an actual race, names whichever
process RUN-BRIDGE's own claim allowed to survive -- not necessarily
the one this specific call spawned."
  (when (bridge-running-p directory)
    (return-from bridge-start nil))
  (ignore-errors (delete-file (bridge-pid-file directory)))
  (unless (probe-file bridge-lisp)
    (error 'bridge-error
           :format-control "Cannot find bridge-lisp file: ~a (set *BRIDGE-LISP* or SBCL_BRIDGE_LISP)"
           :format-arguments (list bridge-lisp)))
  (ensure-directories-exist (ensure-directory-pathname directory))
  (let* ((dir (resolved-bridge-dir directory))
         (output-log (bridge-output-log dir))
         ;; DIR is already a directory pathname whose NAMESTRING ends
         ;; in a slash -- do not concatenate another one. A real,
         ;; reproduced bug: this used to append "/" unconditionally,
         ;; producing a literal ".../bridge-dir//" argument. Harmless
         ;; to the bridge itself (ENSURE-DIRECTORY-PATHNAME on its side
         ;; normalizes it away), but the exact kind of avoidable rough
         ;; edge this project has otherwise gone to some lengths to
         ;; eliminate on the shell side (see the README's account of
         ;; the double-slash bug there) -- not worth reintroducing here.
         (eval-form (format nil "(sbcl-bridge:run-bridge :directory ~a)"
                             (lisp-string-literal (namestring dir)))))
    (sb-ext:run-program
     "setsid"
     (list sbcl-bin "--non-interactive" "--no-sysinit" "--no-userinit"
           "--load" (namestring (truename bridge-lisp))
           "--eval" eval-form)
     :search t
     :environment (cons (format nil "SBCL_BRIDGE_DIR=~a" (namestring dir))
                         (sb-ext:posix-environ))
     :input nil
     :output output-log
     :if-output-exists :append
     :error :output
     :wait nil)
    ;; Deliberately NOT trusting SB-EXT:PROCESS-PID of the call above
    ;; as the bridge's PID -- a real, reproduced gap: `setsid CMD` does
    ;; not always preserve CMD's PID across the exec. setsid(2) requires
    ;; its caller not already be a process group leader; when it IS,
    ;; which turns out to depend on how the immediate parent set up the
    ;; child before exec (SB-EXT:RUN-PROGRAM's child setup triggers
    ;; this; a plain shell background job typically does not), the
    ;; `setsid` UTILITY silently forks a new child to work around that
    ;; restriction rather than exec-ing in place -- so the PID captured
    ;; here would name the now-exited setsid wrapper, not the bridge.
    ;; Confirmed directly: spawning `setsid sleep 5` this way reported
    ;; one PID while the real, running sleep process had the very next
    ;; one. sbcl-bridge.lisp's RUN-BRIDGE now writes its own PID file as
    ;; its first action for exactly this reason -- polling for THAT to
    ;; land, rather than trusting any launcher's own guess, is what's
    ;; actually reliable regardless of which mechanism spawned it.
    (loop with waited = 0.0
          until (bridge-running-p dir)
          do (when (>= waited 5.0)
               (error 'bridge-error
                      :format-control "Failed to start (no live bridge detected after 5s); check ~a"
                      :format-arguments (list output-log)))
             (sleep 0.1)
             (incf waited 0.1))
    (bridge-pid dir)))

(defun wait-for-exit (pid timeout)
  "Poll every 0.3s (matching sbcl-bridge-ctl.sh's own POLL_INTERVAL)
until PID is no longer alive, or TIMEOUT seconds have elapsed. Returns
T if the process exited in time, NIL otherwise."
  (loop with waited = 0.0
        while (process-alive-p pid)
        do (when (>= waited timeout) (return nil))
           (sleep 0.3)
           (incf waited 0.3)
        finally (return t)))

(defun request-graceful-stop (&optional (directory *bridge-dir*))
  "Drops a stop-request file for the bridge watching DIRECTORY to find
-- the same file-drop mechanism BRIDGE-INTERRUPT uses for
cancel-request (below), just a different file and a different outcome
(exit cleanly vs. resume waiting for the next request)."
  (let* ((dir (resolved-bridge-dir directory))
         (tmp (merge-pathnames (format nil ".stop-request.~a.tmp" (make-request-id)) dir)))
    (with-open-file (s tmp :direction :output :if-exists :supersede :if-does-not-exist :create))
    ;; SB-POSIX:RENAME, not CL:RENAME-FILE -- same pathname-merge trap
    ;; BRIDGE-INTERRUPT already documents and avoids for cancel-request.
    (sb-posix:rename (namestring tmp) (namestring (bridge-stop-file dir)))))

(defun bridge-stop (&key (directory *bridge-dir*) (stop-timeout *stop-timeout*) force)
  "Stop the bridge watching DIRECTORY, escalating gracefully unless
FORCE: cancel any in-flight request (reusing BRIDGE-INTERRUPT's own
mechanism, below), then ask the image to exit cleanly via a
stop-request file the bridge's watchdog thread checks whether idle or
busy, only falling back to SIGTERM then SIGKILL if that doesn't work
within STOP-TIMEOUT. With FORCE, skips straight to SIGTERM/SIGKILL --
e.g. if the bridge's watchdog thread is itself wedged (interrupt-thread
delivery needs a safepoint; tight native/non-consing code on the main
thread can stall it indefinitely). A no-op if nothing is running.
Always removes the pidfile on return. Mirrors sbcl-bridge-ctl.sh's
staged `stop [--force]` exactly."
  (let ((pid (bridge-pid directory)))
    (unless (and pid (bridge-running-p directory))
      (ignore-errors (delete-file (bridge-pid-file directory)))
      (return-from bridge-stop nil))
    (unless force
      (when (bridge-busy-p directory)
        (ignore-errors (bridge-interrupt :directory directory))
        (let ((cancel-wait (min stop-timeout 5)))
          (loop with waited = 0.0
                while (and (bridge-busy-p directory) (< waited cancel-wait))
                do (sleep *poll-interval*) (incf waited *poll-interval*))))
      (ignore-errors (request-graceful-stop directory))
      (when (wait-for-exit pid stop-timeout)
        (ignore-errors (delete-file (bridge-pid-file directory)))
        (ignore-errors (delete-file (bridge-stop-file directory)))
        (return-from bridge-stop t)))
    (ignore-errors (sb-posix:kill pid sb-posix:sigterm))
    (unless (wait-for-exit pid stop-timeout)
      (ignore-errors (sb-posix:kill pid sb-posix:sigkill))
      (wait-for-exit pid 5))
    (ignore-errors (delete-file (bridge-pid-file directory)))
    (ignore-errors (delete-file (bridge-stop-file directory)))
    t))

(defun bridge-restart (&key (directory *bridge-dir*)
                            (bridge-lisp *bridge-lisp*)
                            (sbcl-bin *sbcl-bin*)
                            (stop-timeout *stop-timeout*))
  (bridge-stop :directory directory :stop-timeout stop-timeout)
  (bridge-start :directory directory :bridge-lisp bridge-lisp :sbcl-bin sbcl-bin))

;;; ---------------------------------------------------------------------
;;; Header parsing
;;;
;;; MATCH-HEADER-LINE and EXTRACT-CODE-HEADER are ported VERBATIM from
;;; sbcl-bridge.lisp's own MATCH-HEADER-LINE/EXTRACT-HEADER -- not
;;; reimplemented to the same spec, the literal same code -- so this
;;; library's understanding of what counts as a leading ";;; KEY:
;;; value" header can never drift out of sync with what the bridge
;;; itself will actually honor.

(defun match-header-line (line)
  "If LINE looks like ';;; KEY: VALUE', return (values KEY VALUE) with
KEY upcased and both trimmed. Otherwise (values nil nil)."
  (let ((prefix ";;; "))
    (if (and (>= (length line) (length prefix))
             (string= line prefix :end1 (length prefix)))
        (let* ((rest (subseq line (length prefix)))
               (colon (position #\: rest)))
          (if colon
              (values (string-upcase (string-trim " " (subseq rest 0 colon)))
                      (string-trim '(#\Space #\Tab #\Return) (subseq rest (1+ colon))))
              (values nil nil)))
        (values nil nil))))

(defun extract-code-header (text key &optional default)
  "Scan leading ';;; KEY: value' comment lines in TEXT (stopping at the
first non-header line) for KEY (case-insensitive) and return its
trimmed value, or DEFAULT if not present."
  (let ((pos 0) (len (length text)))
    (loop
      (when (>= pos len) (return default))
      (let* ((eol (or (position #\Newline text :start pos) len))
             (line (subseq text pos eol)))
        (multiple-value-bind (k v) (match-header-line line)
          (cond
            ((null k) (return default))
            ((string-equal k key) (return v))
            (t (setf pos (if (< eol len) (1+ eol) len)))))))))

(defvar *request-counter* 0)

(defun make-request-id ()
  "A unique request id in the same shape sbcl-client.sh generates:
nanosecond-ish timestamp, our own PID, and a random component -- three
independent sources of uniqueness so a collision would need all three
to coincide."
  (format nil "~a-~a-~a-~a"
          (get-universal-time)
          (sb-unix:unix-getpid)
          (incf *request-counter*)
          (random 1000000)))

(defun parse-end-output-stats (status-line)
  "Extracts (values elapsed-ms consed-bytes), as integers, from an
END-OUTPUT status line -- or nil for either/both if absent, which
happens when talking to a bridge process predating these fields
(the two implementations of this protocol, this file and
sbcl-bridge.lisp, are maintained in parallel and can drift briefly out
of step -- see this file's own header)."
  (flet ((extract (key)
           (let ((pos (search key status-line)))
             (and pos
                  (ignore-errors
                    (parse-integer status-line :start (+ pos (length key)) :junk-allowed t))))))
    (values (extract "elapsed-ms=") (extract "consed-bytes="))))

(defun effective-wait-timeout (embedded-timeout request-timeout wait-timeout)
  "Reproduces sbcl-client.sh's exact TIMEOUT precedence: an explicit
WAIT-TIMEOUT (*WAIT-TIMEOUT* / SBCL_TIMEOUT) always wins; failing that,
whichever of REQUEST-TIMEOUT (an explicit :request-timeout argument /
*REQUEST-TIMEOUT*) or EMBEDDED-TIMEOUT (a ';;; TIMEOUT:' header found
in the submitted code) is in effect gets +5 seconds, floored at 30;
with neither, or with either set to \"none\" or unparseable, the
default is a flat 30."
  (or wait-timeout
      (let ((effective (or request-timeout embedded-timeout)))
        (let ((n (and effective (ignore-errors (parse-integer effective :junk-allowed t)))))
          (if n (max 30 (+ n 5)) 30)))))

(defun bridge-eval (code &key (directory *bridge-dir*)
                              (request-timeout *request-timeout*)
                              (wait-timeout *wait-timeout*)
                              (poll-interval *poll-interval*)
                              (signal-errors t))
  "Submit CODE (a string of Lisp forms, exactly as sbcl-client.sh's
`eval`/`file`/`-` modes would write it) to the bridge watching
DIRECTORY, wait for its response, and return the response text (the
raw content between BEGIN-OUTPUT and END-OUTPUT, exactly as printed --
callers wanting a Lisp VALUE back can READ-FROM-STRING the leading
\";;; => ...\" line themselves) as the primary value, with the reqid
used as a second value.

Leading ';;; REQID:'/';;; TIMEOUT:' headers already present in CODE are
honored exactly as sbcl-client.sh honors them: an embedded REQID is
reused rather than shadowed, and an embedded TIMEOUT both reaches the
bridge and extends this call's own wait budget. REQUEST-TIMEOUT, when
non-NIL, takes precedence over an embedded TIMEOUT header, matching
the shell client.

By default, any outcome other than status=ok signals the corresponding
BRIDGE-ERROR subclass (see the Conditions section) -- pass
:SIGNAL-ERRORS NIL to instead get back (values NIL STATUS-KEYWORD TEXT
REQID) for any outcome, ok included, letting the caller branch on the
status keyword programmatically without condition-handler ceremony."
  (unless (bridge-running-p directory)
    (let ((c (make-condition 'bridge-not-running-error
                              :output (format nil "no live bridge found watching ~a" directory))))
      (if signal-errors (error c) (return-from bridge-eval (values nil :not-running nil nil)))))
  (let* ((dir (resolved-bridge-dir directory))
         (file-reqid (extract-code-header code "REQID"))
         (embedded-timeout (extract-code-header code "TIMEOUT"))
         (reqid (or file-reqid (make-request-id)))
         (budget (effective-wait-timeout embedded-timeout request-timeout wait-timeout))
         (output-log (bridge-output-log dir))
         (input-path (bridge-input-path dir))
         (tmp-path (merge-pathnames
                    (format nil ".next-sbcl-input.~a.tmp" (make-request-id))
                    dir)))
    (unless (probe-file output-log) (open output-log :direction :probe :if-does-not-exist :create))
    (with-open-file (s tmp-path :direction :output :if-exists :supersede :if-does-not-exist :create)
      (unless file-reqid (format s ";;; REQID: ~a~%" reqid))
      (when request-timeout (format s ";;; TIMEOUT: ~a~%" request-timeout))
      (write-string code s)
      (terpri s))
    (unwind-protect
         (progn
           ;; Atomic submission, retried until the slot frees up: a
           ;; hard link fails if INPUT-PATH already exists, so a
           ;; request that's queued but not yet claimed is never
           ;; silently clobbered -- the exact same discipline
           ;; sbcl-client.sh's `until ln ...` loop uses, for the exact
           ;; same reason.
           (let ((waited 0.0))
             (loop until (ignore-errors (sb-posix:link (namestring tmp-path) (namestring input-path)) t)
                   do (when (>= waited budget)
                        (let ((c (make-condition 'bridge-submission-timeout-error :reqid reqid)))
                          (if signal-errors (error c)
                              (return-from bridge-eval (values nil :submission-timeout nil reqid)))))
                      (sleep poll-interval)
                      (incf waited poll-interval)))
           (delete-file tmp-path)
           (let ((begin-mark (format nil ";;; BEGIN-OUTPUT id=~a " reqid))
                 (end-mark (format nil ";;; END-OUTPUT id=~a " reqid))
                 (start-size (with-open-file (s output-log) (file-length s)))
                 (waited 0.0))
             (loop
               (let ((cur-size (with-open-file (s output-log :if-does-not-exist nil)
                                  (if s (file-length s) 0))))
                 (when (< cur-size start-size) (setf start-size 0))
                 (let ((new-content
                         (with-open-file (s output-log)
                           (file-position s start-size)
                           (let ((buf (make-string (- (file-length s) start-size))))
                             (read-sequence buf s)
                             buf))))
                   (let ((end-pos (search end-mark new-content)))
                     (when end-pos
                       (let* ((begin-pos (search begin-mark new-content))
                              (body-start (if begin-pos
                                               (1+ (or (position #\Newline new-content :start begin-pos) begin-pos))
                                               0))
                              (line-end (or (position #\Newline new-content :start end-pos) (length new-content)))
                              (status-line (subseq new-content end-pos line-end))
                              (text (string-right-trim '(#\Newline)
                                                        (subseq new-content body-start end-pos))))
                         (multiple-value-bind (elapsed-ms consed-bytes)
                             (parse-end-output-stats status-line)
                           (return
                             (cond
                               ((search "status=ok" status-line)
                                (values text :ok reqid elapsed-ms consed-bytes))
                               ((search "status=error" status-line)
                                (if signal-errors
                                    (error 'bridge-evaluation-error :reqid reqid :output text
                                           :elapsed-ms elapsed-ms :consed-bytes consed-bytes)
                                    (values nil :error text reqid elapsed-ms consed-bytes)))
                               ((search "status=timeout" status-line)
                                (if signal-errors
                                    (error 'bridge-request-timeout-error :reqid reqid
                                           :elapsed-ms elapsed-ms :consed-bytes consed-bytes)
                                    (values nil :timeout text reqid elapsed-ms consed-bytes)))
                               ((search "status=cancelled" status-line)
                                (if signal-errors
                                    (error 'bridge-cancelled-error :reqid reqid
                                           :elapsed-ms elapsed-ms :consed-bytes consed-bytes)
                                    (values nil :cancelled text reqid elapsed-ms consed-bytes)))
                               ((search "status=fatal-condition" status-line)
                                (if signal-errors
                                    (error 'bridge-fatal-condition-error :reqid reqid :output text
                                           :elapsed-ms elapsed-ms :consed-bytes consed-bytes)
                                    (values nil :fatal-condition text reqid elapsed-ms consed-bytes)))
                               (t (values text :ok reqid elapsed-ms consed-bytes))))))))))
               (when (>= waited budget)
                 (let ((c (make-condition 'bridge-response-timeout-error :reqid reqid)))
                   (return (if signal-errors (error c)
                               (values nil :response-timeout nil reqid)))))
               (sleep poll-interval)
               (incf waited poll-interval))))
      (ignore-errors (delete-file tmp-path)))))

(defun slurp-file (path)
  (with-open-file (s path)
    (let ((buf (make-string (file-length s))))
      (read-sequence buf s)
      buf)))

(defun bridge-eval-file (path &rest args &key &allow-other-keys)
  "Like BRIDGE-EVAL, but CODE is read from PATH -- the equivalent of
sbcl-client.sh's `file` mode."
  (apply #'bridge-eval (slurp-file path) args))

;;; ---------------------------------------------------------------------
;;; bridge-interrupt

(defun bridge-interrupt (&key target-reqid (directory *bridge-dir*))
  "Request cancellation of whatever request is currently running (or,
if TARGET-REQID is given, only if that reqid matches). A no-op if
nothing is running, or if the running request doesn't match -- exactly
like sbcl-bridge-ctl.sh interrupt. Signals BRIDGE-NOT-RUNNING-ERROR if
no bridge is watching DIRECTORY at all."
  (unless (bridge-running-p directory)
    (error 'bridge-not-running-error :output (format nil "no live bridge found watching ~a" directory)))
  (let* ((dir (resolved-bridge-dir directory))
         (tmp (merge-pathnames (format nil ".cancel-request.~a.tmp" (make-request-id)) dir)))
    (with-open-file (s tmp :direction :output :if-exists :supersede :if-does-not-exist :create)
      (when target-reqid (write-string target-reqid s)))
    ;; SB-POSIX:RENAME, not CL:RENAME-FILE -- a real, reproduced bug:
    ;; RENAME-FILE's second argument gets merged against the FIRST
    ;; argument's pathname components for any component it doesn't
    ;; explicitly specify, and a bare "cancel-request" (no dot) parses
    ;; with a NIL type, which SBCL treats as unspecified rather than
    ;; explicitly empty -- so the merge pulled TMP's own ".tmp" type
    ;; back onto the target, silently renaming to "cancel-request.tmp"
    ;; instead of "cancel-request", which the bridge never noticed at
    ;; all. The exact same class of trap ENSURE-DIRECTORY-PATHNAME
    ;; documents at length for MERGE-PATHNAMES itself; this is
    ;; RENAME-FILE hitting it independently. Working with plain
    ;; namestrings via the POSIX syscall directly sidesteps CL pathname
    ;; merging semantics entirely, the same way SB-POSIX:LINK already
    ;; does for the atomic hard-link submission above.
    (sb-posix:rename (namestring tmp) (namestring (bridge-cancel-file dir)))
    t))

;;; ---------------------------------------------------------------------
;;; bridge-suspend

(defun current-core-path (&optional (directory *bridge-dir*))
  (merge-pathnames "current.core" (bridge-core-dir directory)))

(defun list-cores-by-age (&optional (directory *bridge-dir*))
  "Core files under DIRECTORY/cores/, newest first. Excludes
current.core itself: that's a pointer TO one of these files (see
UPDATE-CURRENT-CORE-SYMLINK/BRIDGE-REFRESH), not a core image of its
own -- including it here would corrupt newest-by-mtime ordering (a
symlink's own mtime updates every time it's re-pointed, unrelated to
the age of the core it actually points at) and would let PRUNE-CORES
try to count or delete it as if it were a real image."
  (let ((current (namestring (current-core-path directory))))
    (sort (remove current
                  (copy-list (directory (merge-pathnames "*.core" (bridge-core-dir directory))))
                  :key #'namestring :test #'string=)
          #'>
          :key #'file-write-date)))

(defun version-sidecar-path (core-path)
  "Mirrors sbcl-bridge.lisp's own VERSION-SIDECAR-PATH exactly:
string concatenation, not (make-pathname :type \"version\" ...). The
latter REPLACES a pathname's type component rather than appending to
it -- (make-pathname :type \"version\" :defaults #P\".../foo.core\")
produces \".../foo.version\" (silently dropping \".core\"), not the
\".../foo.core.version\" the bridge actually writes. Confirmed directly
(not assumed): this exact mismatch was a real, latent bug in this
file's own pre-existing sidecar handling, caught while adding the
analogous .pinned marker below."
  (concatenate 'string (namestring core-path) ".version"))

(defun pinned-marker-path (core-path)
  "Mirrors sbcl-bridge.lisp's own PINNED-MARKER-PATH -- see
VERSION-SIDECAR-PATH, just above, for why this must be string
concatenation and not (make-pathname :type \"pinned\" ...)."
  (concatenate 'string (namestring core-path) ".pinned"))

(defun core-pinned-name (core-path)
  "The pinned name for CORE-PATH, or NIL if it isn't pinned."
  (let ((marker (pinned-marker-path core-path)))
    (and (probe-file marker) (slurp-file marker))))

(defun core-exempt-from-pruning-p (core-path &optional (directory *bridge-dir*))
  "T if CORE-PATH should survive SBCL_CORE_RETAIN's automatic pruning:
either it's explicitly pinned (has a .pinned sidecar, see
CORE-PINNED-NAME), or it's what cores/current.core currently resolves
to. The second exemption is required for BRIDGE-REFRESH's own
correctness -- without it, refresh could end up pointing at a core
PRUNE-CORES already deleted, e.g. after resuming a deliberately-old,
unpinned core that then falls out of the retain window on the next
suspend. Mirrors sbcl-bridge-ctl.sh's CORE_EXEMPT_FROM_PRUNING."
  (or (probe-file (pinned-marker-path core-path))
      (let ((current (current-core-path directory)))
        (and (probe-file current)
             (ignore-errors (equal (truename current) (truename core-path)))))))

(defun prune-cores (&key (directory *bridge-dir*) (core-retain *core-retain*))
  "Keep the CORE-RETAIN most recent NON-EXEMPT core images (always at
least one), deleting older ones and their .version/.pinned sidecars,
plus any orphaned .version sidecar whose .core is already gone. Pinned
cores and whatever cores/current.core points at (see
CORE-EXEMPT-FROM-PRUNING-P) are excluded from this budget entirely --
never deleted regardless of age or count, and never consuming a
retention slot that would otherwise starve ordinary rotation. Mirrors
sbcl-bridge-ctl.sh's PRUNE_CORES."
  (let* ((keep (max 1 core-retain))
         (prunable (remove-if (lambda (c) (core-exempt-from-pruning-p c directory))
                               (list-cores-by-age directory))))
    (dolist (core (nthcdr keep prunable))
      (ignore-errors (delete-file core))
      (ignore-errors (delete-file (version-sidecar-path core))))
    (dolist (sidecar (directory (merge-pathnames "*.core.version" (bridge-core-dir directory))))
      (let ((core (make-pathname :type nil :defaults sidecar)))
        (unless (probe-file core) (ignore-errors (delete-file sidecar)))))))

(defun update-current-core-symlink (core-path &optional (directory *bridge-dir*))
  "Points cores/current.core at CORE-PATH (a relative symlink, so it
survives the whole bridge directory being moved -- same philosophy as
the SBCL_BRIDGE_DIR override elsewhere). Called from BRIDGE-SUSPEND
(with the just-saved core) and BRIDGE-RESUME (with whichever core was
actually resumed) -- together, these two call sites are what let
BRIDGE-REFRESH return to \"the core that was actually live\" rather
than just \"the newest file on disk,\" which can differ if someone
deliberately resumed an older core. SB-POSIX:SYMLINK/RENAME, not
CL:RENAME-FILE, for the same pathname-merge trap BRIDGE-INTERRUPT
already documents and avoids."
  (let* ((target (current-core-path directory))
         (tmp (merge-pathnames (format nil ".current.core.~a.tmp" (make-request-id))
                                (bridge-core-dir directory))))
    (ignore-errors (delete-file tmp))
    (sb-posix:symlink (file-namestring (pathname core-path)) (namestring tmp))
    (sb-posix:rename (namestring tmp) (namestring target))))

(defun bridge-suspend (&key core-path name (directory *bridge-dir*) (suspend-timeout *suspend-timeout*))
  "Ask the bridge watching DIRECTORY to save itself to CORE-PATH
(defaulting to DIRECTORY/cores/bridge-<timestamp>.core, or
DIRECTORY/cores/NAME.core if NAME is given) and exit, waiting up to
SUSPEND-TIMEOUT seconds. Returns the core pathname on success. On a
timeout, withdraws the suspend request if it's still queued and
unclaimed (so the bridge doesn't save-and-exit by surprise later),
matching sbcl-bridge-ctl.sh's own behavior exactly, and signals
BRIDGE-ERROR either way.

NAME, if given, marks the core pinned -- exempt from CORE-RETAIN's
automatic pruning (see CORE-EXEMPT-FROM-PRUNING-P), deletable only via
BRIDGE-DELETE-CORE."
  (unless (bridge-running-p directory)
    (error 'bridge-not-running-error :output "not running; nothing to suspend"))
  (let* ((dir (resolved-bridge-dir directory))
         (pid (bridge-pid dir))
         (ts (multiple-value-bind (sec min hr day mon yr) (get-decoded-time)
               (format nil "~4,'0d~2,'0d~2,'0d-~2,'0d~2,'0d~2,'0d" yr mon day hr min sec)))
         (core-path (or core-path
                        (merge-pathnames (format nil "~a.core" (or name (format nil "bridge-~a" ts)))
                                         (bridge-core-dir dir))))
         (reqid (format nil "suspend-~a-~a" ts (sb-unix:unix-getpid)))
         (input-path (bridge-input-path dir))
         (tmp (merge-pathnames (format nil ".next-sbcl-input.~a.tmp" (make-request-id)) dir)))
    (ensure-directories-exist (bridge-core-dir dir))
    (with-open-file (s tmp :direction :output :if-exists :supersede :if-does-not-exist :create)
      (format s ";;; REQID: ~a~%" reqid)
      (format s ";;; TIMEOUT: none~%")
      (if name
          (format s "(sbcl-bridge:suspend-bridge :core-path ~a :name ~a)~%"
                  (lisp-string-literal (namestring core-path)) (lisp-string-literal name))
          (format s "(sbcl-bridge:suspend-bridge :core-path ~a)~%"
                  (lisp-string-literal (namestring core-path)))))
    (unless (ignore-errors (sb-posix:link (namestring tmp) (namestring input-path)) t)
      (ignore-errors (delete-file tmp))
      (error 'bridge-error :output "A request is already queued; try again shortly."))
    (if (wait-for-exit pid suspend-timeout)
        (if (and (probe-file core-path) (plusp (with-open-file (s core-path) (file-length s))))
            (progn
              (ignore-errors
                (sb-ext:run-program "chmod" (list "+x" (namestring core-path)) :search t :wait t))
              (ignore-errors (delete-file (bridge-pid-file dir)))
              (ignore-errors (update-current-core-symlink core-path dir))
              (prune-cores :directory dir)
              core-path)
            (error 'bridge-error
                   :output (format nil "Process exited but core image is missing/empty: ~a" core-path)))
        (let ((still-queued (and (probe-file input-path)
                                  (search reqid (slurp-file input-path)))))
          (when still-queued (ignore-errors (delete-file input-path)))
          (error 'bridge-error
                 :output (if still-queued
                             "Suspend did not complete within the timeout; the request was still queued and has been withdrawn."
                             "Suspend did not complete within the timeout; the request was already claimed and may still finish -- check BRIDGE-STATUS."))))))

;;; ---------------------------------------------------------------------
;;; bridge-resume
;;;
;;; SBCL_HOME restoration is considerably simpler here than in
;;; sbcl-bridge-ctl.sh's shell equivalent: the shell script has to spawn
;;; a whole separate `sbcl --eval '(sb-int:sbcl-homedir-pathname)'`
;;; subprocess just to ask what the CURRENT sbcl's home is, because
;;; bash has no other way to find out. This library IS a running Lisp
;;; image already -- it can just call SB-INT:SBCL-HOMEDIR-PATHNAME
;;; directly.

(defun valid-sbcl-home-p (path)
  (and path (probe-file path)
       (probe-file (merge-pathnames "contrib/" (ensure-directory-pathname path)))))

(defun read-version-sidecar (core-path)
  "(values saved-version saved-machine saved-home), any or all NIL if
the sidecar doesn't exist or is short."
  (let ((sidecar (version-sidecar-path core-path)))
    (if (probe-file sidecar)
        (with-open-file (s sidecar)
          (values (read-line s nil nil) (read-line s nil nil) (read-line s nil nil)))
        (values nil nil nil))))

(defun restore-sbcl-home (saved-version saved-machine saved-home)
  "Returns an SBCL_HOME value to export for the resumed process, or
NIL if none of the caller's existing SBCL_HOME, the local installation,
or the sidecar's recorded home validate. Mirrors sbcl-bridge-ctl.sh's
RESTORE_SBCL_HOME precisely, including its preference order."
  (let ((caller-home (env "SBCL_HOME")))
    (when caller-home (return-from restore-sbcl-home caller-home)))
  (let* ((here-home (ignore-errors (namestring (sb-int:sbcl-homedir-pathname))))
         (current-version (lisp-implementation-version))
         (current-machine (machine-type))
         (same-build (and saved-version (string= saved-version current-version)
                           (string= saved-machine current-machine))))
    (cond
      (same-build
       (cond ((valid-sbcl-home-p here-home) here-home)
             ((valid-sbcl-home-p saved-home) saved-home)))
      (t
       (cond ((valid-sbcl-home-p saved-home) saved-home)
             ((valid-sbcl-home-p here-home) here-home))))))

(defun bridge-resume (&key core-path (directory *bridge-dir*) (sbcl-bin *sbcl-bin*))
  "Resume the bridge watching DIRECTORY from CORE-PATH (defaulting to
the most recently suspended core there). Restores SBCL_HOME for the
child using the same validated-candidate logic as
sbcl-bridge-ctl.sh's RESUME. A no-op returning NIL if a bridge is
already running; returns the new PID otherwise."
  (when (bridge-running-p directory)
    (return-from bridge-resume nil))
  (let* ((dir (resolved-bridge-dir directory))
         (core-path (or core-path (first (list-cores-by-age dir)))))
    (unless (and core-path (probe-file core-path))
      (error 'bridge-error
             :format-control "No core image to resume from (looked in ~a)"
             :format-arguments (list (bridge-core-dir dir))))
    (ignore-errors (delete-file (bridge-pid-file dir)))
    (multiple-value-bind (saved-version saved-machine saved-home) (read-version-sidecar core-path)
      (let* ((sbcl-home (restore-sbcl-home saved-version saved-machine saved-home))
             (output-log (bridge-output-log dir))
             (env (list* (format nil "SBCL_BRIDGE_DIR=~a" (namestring dir))
                         (append (when sbcl-home (list (format nil "SBCL_HOME=~a" sbcl-home)))
                                 (sb-ext:posix-environ)))))
        (sb-ext:run-program
         "setsid"
         (if (sb-unix:unix-access (namestring core-path) sb-unix:x_ok)
             (list (namestring core-path))
             (list sbcl-bin "--core" (namestring core-path)))
         :search t
         :environment env
         :input nil
         :output output-log
         :if-output-exists :append
         :error :output
         :wait nil)
        (loop with waited = 0.0
              until (bridge-running-p dir)
              do (when (>= waited 5.0)
                   (error 'bridge-error
                          :format-control "Failed to resume (no live bridge detected after 5s); check ~a"
                          :format-arguments (list output-log)))
                 (sleep 0.1)
                 (incf waited 0.1))
        (ignore-errors (update-current-core-symlink core-path dir))
        (bridge-pid dir)))))

(defun bridge-refresh (&key (directory *bridge-dir*) (stop-timeout *stop-timeout*) (sbcl-bin *sbcl-bin*))
  "Stop + resume from cores/current.core -- the core that was actually
live before the stop, not necessarily the newest file on disk (those
differ if BRIDGE-RESUME was explicitly given an older core). Compare
BRIDGE-RESTART, which is stop + a FRESH start with no saved state.
Signals BRIDGE-ERROR if there's no current-core symlink yet (a bridge
directory that's only ever done a plain BRIDGE-START, never suspended
or resumed) -- no silent fallback to restart-like behavior. Mirrors
sbcl-bridge-ctl.sh's `refresh` exactly."
  (let* ((dir (resolved-bridge-dir directory))
         (link (current-core-path dir))
         (target (and (probe-file link) (truename link))))
    (unless target
      (error 'bridge-error
             :output "Nothing to refresh: no current-core symlink (this bridge directory has only ever been freshly started, never suspended or resumed)."))
    (bridge-stop :directory dir :stop-timeout stop-timeout)
    (bridge-resume :core-path target :directory dir :sbcl-bin sbcl-bin)))

(defun resolve-core-arg (name-or-path &optional (directory *bridge-dir*))
  "Tries, in order: NAME-OR-PATH as a literal path, \"<name>.core\"
under DIRECTORY/cores/ (the default naming BRIDGE-SUSPEND's :NAME
produces), then the bare NAME-OR-PATH itself under DIRECTORY/cores/.
Returns NIL if none resolve to an existing file. Mirrors
sbcl-bridge-ctl.sh's RESOLVE_CORE_ARG."
  (let ((literal (pathname name-or-path))
        (by-name (merge-pathnames (format nil "~a.core" name-or-path) (bridge-core-dir directory)))
        (bare (merge-pathnames name-or-path (bridge-core-dir directory))))
    (cond ((probe-file literal) literal)
          ((probe-file by-name) by-name)
          ((probe-file bare) bare)
          (t nil))))

(defun proc-cmdline-string (pid)
  "Best-effort, space-joined /proc/<pid>/cmdline, or NIL if unreadable
(process gone, permission denied, non-Linux)."
  (ignore-errors
    (with-open-file (s (format nil "/proc/~a/cmdline" pid) :element-type '(unsigned-byte 8))
      (let ((buf (make-array (file-length s) :element-type '(unsigned-byte 8))))
        (read-sequence buf s)
        (substitute #\Space (code-char 0) (sb-ext:octets-to-string buf :external-format :utf-8))))))

(defun bridge-delete-core (name-or-path &key (directory *bridge-dir*) force)
  "The only way a pinned core is ever removed (PRUNE-CORES deliberately
never touches one). Also works on unpinned/anonymous cores, by path or
by their timestamp \"name\" (see RESOLVE-CORE-ARG). Refuses, without
FORCE, to delete whatever the running bridge (if any) was actually
started from -- best-effort: compares against /proc/<pid>/cmdline, which
names the core path directly for a resume via the executable core
itself, or via `sbcl --core PATH`. Returns (values core-path name),
NAME nil if it wasn't pinned. Mirrors sbcl-bridge-ctl.sh's
`delete-core`."
  (let* ((dir (resolved-bridge-dir directory))
         (core-path (resolve-core-arg name-or-path dir)))
    (unless core-path
      (error 'bridge-error
             :output (format nil "No core found matching '~a' (looked in ~a)"
                              name-or-path (bridge-core-dir dir))))
    (unless force
      (let ((pid (and (bridge-running-p dir) (bridge-pid dir))))
        (when pid
          (let ((cmdline (proc-cmdline-string pid)))
            (when (and cmdline (search (namestring core-path) cmdline))
              (error 'bridge-error
                     :output (format nil "Refusing to delete ~a: the running bridge (pid ~a) appears to have been started from it. Stop the bridge first, or pass :FORCE T."
                                      core-path pid)))))))
    (let ((name (core-pinned-name core-path)))
      (ignore-errors (delete-file core-path))
      (ignore-errors (delete-file (version-sidecar-path core-path)))
      (ignore-errors (delete-file (pinned-marker-path core-path)))
      (values core-path name))))

;;; ---------------------------------------------------------------------
;;; Log rotation & processed/ pruning

(defun bridge-busy-p (&optional (directory *bridge-dir*))
  "T if a request is queued or currently being evaluated -- mirrors
sbcl-bridge-ctl.sh's BRIDGE_BUSY."
  (or (probe-file (bridge-input-path directory))
      (probe-file (merge-pathnames "next-sbcl-input.working" (ensure-directory-pathname directory)))))

(defun file-size (path)
  (if (probe-file path) (with-open-file (s path) (file-length s)) 0))

(defun rotate-one-log (path &key (directory *bridge-dir*) force (log-max-bytes *log-max-bytes*))
  "Copytruncate PATH if it's grown past LOG-MAX-BYTES (or
unconditionally if FORCE), archiving a gzipped copy under
DIRECTORY/logs/. Mirrors sbcl-bridge-ctl.sh's ROTATE_ONE_LOG,
including its caveat: a write landing in the instant between the copy
and the truncate can be lost."
  (unless (probe-file path) (return-from rotate-one-log))
  (let ((size (file-size path)))
    (when (and (or force (>= size log-max-bytes)) (plusp size))
      (let* ((archive-dir (bridge-log-archive-dir directory))
             (ts (multiple-value-bind (sec min hr day mon yr) (get-decoded-time)
                   (format nil "~4,'0d~2,'0d~2,'0d-~2,'0d~2,'0d~2,'0d" yr mon day hr min sec)))
             (dest (merge-pathnames (format nil "~a.~a" (file-namestring path) ts) archive-dir)))
        (ensure-directories-exist archive-dir)
        (with-open-file (in path :element-type '(unsigned-byte 8))
          (with-open-file (out dest :element-type '(unsigned-byte 8) :direction :output :if-exists :supersede)
            (let ((buf (make-array 65536 :element-type '(unsigned-byte 8))))
              (loop for n = (read-sequence buf in) while (plusp n)
                    do (write-sequence buf out :end n)))))
        (with-open-file (s path :direction :output :if-exists :supersede))
        (ignore-errors (sb-ext:run-program "gzip" (list "-f" (namestring dest)) :search t :wait t))
        (namestring (merge-pathnames (format nil "~a.gz" (file-namestring dest)) archive-dir))))))

(defun prune-log-archive (prefix &key (directory *bridge-dir*) (log-retain *log-retain*))
  (let* ((keep (max 1 log-retain))
         (files (sort (copy-list (directory (merge-pathnames (format nil "~a*.gz" prefix)
                                                              (bridge-log-archive-dir directory))))
                      #'> :key #'file-write-date)))
    (dolist (f (nthcdr keep files)) (ignore-errors (delete-file f)))))

(defun bridge-log-paths (&optional (directory *bridge-dir*))
  "All three of the bridge's own log files. A single shared list, like
sbcl-bridge-ctl.sh's own BRIDGE_LOGS array, so a future fourth log only
needs to be added here once. Named distinctly from BRIDGE-LOGS (below,
the tail-based log-viewing function mirroring sbcl-bridge-ctl.sh's
`logs` command) to avoid clobbering it -- confirmed directly that an
earlier draft of this function used that name and would have silently
redefined it out from under any caller."
  (list (bridge-output-log directory)
        (bridge-input-log directory)
        (bridge-async-error-log directory)))

(defun rotate-logs (&key (directory *bridge-dir*) force)
  "Rotate all of the bridge's logs if oversized (or unconditionally if
FORCE), then prune old archived generations. Skips entirely (regardless
of FORCE) while the bridge is busy, unless FORCE -- matching
sbcl-bridge-ctl.sh's rotate-logs command exactly, including the
warning it prints when forcing past a busy bridge."
  (when (and (bridge-busy-p directory) (not force))
    (return-from rotate-logs :skipped-busy))
  (when (and force (bridge-busy-p directory))
    (format *error-output* "WARNING: a request is queued or in flight; forcing rotation anyway.~%"))
  (dolist (log (bridge-log-paths directory))
    (rotate-one-log log :directory directory :force force)
    (prune-log-archive (format nil "~a." (file-namestring log)) :directory directory))
  t)

(defun bridge-rotate-logs (&key (directory *bridge-dir*) force)
  "sbcl-bridge-ctl.sh's `rotate-logs [--force]`, as a function."
  (rotate-logs :directory directory :force force))

(defun prune-processed (&key (directory *bridge-dir*) (processed-retain *processed-retain*))
  (let* ((keep (max 1 processed-retain))
         (files (sort (copy-list (directory (merge-pathnames "*.lisp" (bridge-processed-dir directory))))
                      #'> :key #'file-write-date)))
    (dolist (f (nthcdr keep files)) (ignore-errors (delete-file f)))))

;;; ---------------------------------------------------------------------
;;; bridge-status

(defun process-ps-fields (pid fields)
  "Run `ps -o FIELDS= -p PID`, returning the raw trimmed output, or NIL
if ps fails or the process is gone. FIELDS is a string like
\"rss=,vsz=\"."
  (ignore-errors
    (let* ((out (make-string-output-stream))
           (p (sb-ext:run-program "ps" (list "-o" fields "-p" (princ-to-string pid))
                                   :search t :wait t :output out :error nil)))
      (when (and p (eql (sb-ext:process-exit-code p) 0))
        (string-trim '(#\Space #\Tab #\Newline) (get-output-stream-string out))))))

(defun count-async-errors (path)
  "Number of ASYNC-ERROR entries recorded in the async-error log at
PATH, or 0 if it doesn't exist yet. Mirrors sbcl-bridge-ctl.sh's own
`grep -c '^;;; ASYNC-ERROR '` in cmd_status."
  (if (probe-file path)
      (with-open-file (s path :external-format :utf-8)
        (loop for line = (read-line s nil nil)
              while line
              count (and (>= (length line) 15) (string= line ";;; ASYNC-ERROR " :end1 16))))
      0))

(defun bridge-status (&key (directory *bridge-dir*) (quiet nil) (mem-warn-mb *mem-warn-mb*))
  "Report on the bridge watching DIRECTORY: a plist of
(:RUNNING-P :PID :UPTIME :RSS-MB :VSZ-MB :CORE-COUNT :OUTPUT-LOG-KB
:INPUT-LOG-KB :ASYNC-ERROR-LOG-KB :ASYNC-ERROR-COUNT :PROCESSED-COUNT),
and, unless :QUIET, a human-readable summary printed to
*STANDARD-OUTPUT* matching sbcl-bridge-ctl.sh status's own format.
Also performs the same piggybacked housekeeping sbcl-bridge-ctl.sh's
status does -- size-triggered log rotation (never while the bridge is
busy) and processed/ pruning -- so polling this periodically keeps
both bounded for free, exactly as it does there."
  (let* ((dir (ignore-errors (resolved-bridge-dir directory)))
         (running (and dir (bridge-running-p dir)))
         (pid (and running (bridge-pid dir)))
         (etime (and pid (process-ps-fields pid "etime=")))
         (rss/vsz (and pid (process-ps-fields pid "rss=,vsz=")))
         (rss-kb (or (and rss/vsz (ignore-errors (parse-integer rss/vsz :junk-allowed t))) 0))
         (vsz-kb (or (and rss/vsz (let ((sp (position #\Space (string-left-trim " " rss/vsz))))
                                     (and sp (ignore-errors (parse-integer rss/vsz :start sp :junk-allowed t)))))
                     0))
         (rss-mb (floor rss-kb 1024))
         (vsz-mb (floor vsz-kb 1024))
         (cores (and dir (list-cores-by-age dir)))
         (out-kb (and dir (floor (file-size (bridge-output-log dir)) 1024)))
         (in-kb (and dir (floor (file-size (bridge-input-log dir)) 1024)))
         (async-kb (and dir (floor (file-size (bridge-async-error-log dir)) 1024)))
         ;; Counted BEFORE the rotate-logs call below, so this reflects
         ;; what's actually accumulated since the last rotation, not a
         ;; near-zero count right after this same call rotates it away.
         (async-count (and dir (count-async-errors (bridge-async-error-log dir))))
         (processed (and dir (directory (merge-pathnames "*.lisp" (bridge-processed-dir dir)))))
         (processed-count (length processed)))
    (unless quiet
      (if running
          (progn
            (format t "RUNNING (pid=~a, uptime=~a)~%" pid (or etime "unknown"))
            (format t "Memory: RSS=~aMB VSZ=~aMB~%" rss-mb vsz-mb)
            (when (and mem-warn-mb (> rss-mb mem-warn-mb))
              (format *error-output* "WARNING: RSS (~aMB) exceeds *MEM-WARN-MB* (~aMB).~%" rss-mb mem-warn-mb)))
          (progn
            (format t "STOPPED~%")
            (when dir (ignore-errors (delete-file (bridge-pid-file dir))))))
      (if cores
          (progn
            (format t "Saved core images (newest first):~%")
            (let ((pinned-count 0))
              (dolist (c cores)
                (let ((pname (core-pinned-name c)))
                  (when pname (incf pinned-count))
                  (format t "  ~a~@[  [named: ~a]~]~%" (namestring c) pname)))
              (when (plusp pinned-count)
                (format t "Named/pinned cores: ~a (exempt from CORE-RETAIN pruning; delete-core to remove)~%"
                        pinned-count))))
          (format t "No saved core images.~%"))
      (when (and dir (probe-file (current-core-path dir)))
        (format t "Current (last resumed/suspended): ~a~%"
                (ignore-errors (namestring (truename (current-core-path dir))))))
      (format t "Logs: sbcl-output.log=~aKB sbcl-input.log=~aKB sbcl-async-errors.log=~aKB~%" out-kb in-kb async-kb)
      (when (and async-count (plusp async-count))
        (format *error-output*
                "WARNING: ~a async error(s) recorded in sbcl-async-errors.log (background-thread faults, main bridge unaffected).~%"
                async-count))
      (format t "Processed archive: ~a request file(s) (retention: ~a)~%" processed-count *processed-retain*))
    (when (and dir (not (bridge-busy-p dir)))
      (ignore-errors (rotate-logs :directory dir))
      (ignore-errors (prune-processed :directory dir)))
    (list :running-p (and running t) :pid pid :uptime etime :rss-mb rss-mb :vsz-mb vsz-mb
          :core-count (length cores)
          :named-cores (loop for c in cores
                              for pname = (core-pinned-name c)
                              when pname collect (cons pname c))
          :output-log-kb out-kb :input-log-kb in-kb
          :async-error-log-kb async-kb :async-error-count async-count
          :processed-count processed-count)))

;;; ---------------------------------------------------------------------
;;; bridge-logs

(defun bridge-logs (&key (directory *bridge-dir*) (lines 50) follow)
  "Print the last LINES lines of DIRECTORY's sbcl-output.log. With
:FOLLOW, behaves like `tail -f` -- blocks, printing new content as it
arrives, until interrupted (^C). Mirrors sbcl-bridge-ctl.sh's `logs`
command; unlike that one, this shells out to the real `tail` rather
than reimplementing its line-counting, since correctly handling
\"last N lines\" of a possibly-huge file is exactly the kind of thing
worth reusing a battle-tested tool for rather than re-deriving."
  (let ((log (bridge-output-log directory)))
    (unless (probe-file log)
      (error 'bridge-error :format-control "No output log yet at ~a" :format-arguments (list log)))
    (sb-ext:run-program "tail" (append (list "-n" (princ-to-string lines))
                                        (when follow (list "-f"))
                                        (list (namestring log)))
                         :search t :wait t :output t :error t)
    (values)))


