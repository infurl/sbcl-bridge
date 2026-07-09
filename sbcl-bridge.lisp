;;;; sbcl-bridge.lisp
;;;;
;;;; A file-based request/response bridge for driving a headless SBCL
;;;; process from an external tool (e.g. a coding agent), without the
;;;; extra protocol chatter of Swank.
;;;;
;;;; Protocol:
;;;;   - Caller writes a request to  <dir>/next-sbcl-input.lisp
;;;;     (atomically, via write-temp-then-rename).
;;;;   - The first few lines of that file may be header comments:
;;;;         ;;; REQID: <some-unique-id>
;;;;         ;;; TIMEOUT: <seconds-or-none>
;;;;     If present, REQID is used to correlate the request with its
;;;;     response (if absent, one is synthesized) and TIMEOUT overrides
;;;;     the bridge's default per-request timeout. Being Lisp comments,
;;;;     these do not interfere with reading/evaluating the rest of the
;;;;     file.
;;;;   - The bridge loop notices the file, immediately renames it out
;;;;     of the way (clearing next-sbcl-input.lisp for the next
;;;;     request), logs the raw request text to <dir>/sbcl-input.log
;;;;     bracketed by BEGIN-INPUT/END-INPUT markers, then reads and
;;;;     evaluates each top-level form in the request, printing each
;;;;     form's values to *standard-output* (which the shell has
;;;;     redirected to sbcl-output.log), bracketed by
;;;;     BEGIN-OUTPUT/END-OUTPUT markers carrying the same id.
;;;;   - The claimed request file is archived under <dir>/processed/.
;;;;
;;;; Start it with something like:
;;;;
;;;;   setsid sbcl --non-interactive \
;;;;     --load /path/to/sbcl-bridge.lisp \
;;;;     --eval '(sbcl-bridge:run-bridge :directory "/path/to/bridge/")' \
;;;;     < /dev/null >> /path/to/bridge/sbcl-output.log 2>&1 &
;;;;   disown
;;;;
;;;; run-bridge never returns in normal operation, so --non-interactive
;;;; is fine: SBCL never gets back to a REPL that could exit on EOF.
;;;;
;;;; Timeouts and cancellation:
;;;;   Each request runs under sb-ext:with-timeout using the bridge's
;;;;   default timeout (30s) unless overridden by a TIMEOUT header or
;;;;   with-timeout is skipped entirely via ";;; TIMEOUT: none". A
;;;;   background watchdog thread also watches for a small control file
;;;;   (cancel-request) that an external tool (e.g. sbcl-bridge-ctl.sh
;;;;   interrupt) can drop to asynchronously cancel whatever request is
;;;;   currently running, whether or not it has timed out yet. The
;;;;   injected interrupt re-checks, on the main thread itself, that
;;;;   the same request is still being evaluated (*evaluating-request*
;;;;   plus an id match) before signalling, so a cancellation racing
;;;;   with request completion becomes a harmless no-op instead of an
;;;;   unhandled condition landing in the main loop.
;;;;
;;;; Condition handling:
;;;;   Beyond ordinary ERROR conditions, STORAGE-CONDITION (e.g. heap
;;;;   exhaustion) and other SERIOUS-CONDITIONs are caught per-request
;;;;   so a single bad request can't silently take the whole process
;;;;   down. Each ERROR/STORAGE-CONDITION/SERIOUS-CONDITION report
;;;;   includes a captured backtrace (BACKTRACE-BEGIN/BACKTRACE-END
;;;;   markers, truncated to *bridge-backtrace-frames* frames, default
;;;;   20), captured via handler-bind before the stack unwinds. A
;;;;   *debugger-hook* is also installed as a last-resort backstop: if
;;;;   something still escapes all of that, it is logged with the
;;;;   active request id before the process exits, rather than
;;;;   dropping into (or hanging in) a debugger with no terminal
;;;;   attached.
;;;;
;;;; Suspend/resume:
;;;;   Calling (sbcl-bridge:suspend-bridge :core-path "...") from within
;;;;   the bridge (e.g. via a normal request) saves an executable image
;;;;   capturing all current definitions and global state, then exits.
;;;;   Running that saved image later (just executing the file) resumes
;;;;   the same polling loop, on the same directory, via a :toplevel
;;;;   hook -- no --load/--eval flags needed on resume (and, since the
;;;;   image is saved with :save-runtime-options t, --eval flags are
;;;;   flatly refused when run directly, so this isn't just a
;;;;   convenience). A sidecar "<core-path>.version" file records the
;;;;   SBCL version, machine type, and SBCL_HOME in effect at save
;;;;   time, so a mismatched resume attempt can be flagged and contrib
;;;;   modules can still be REQUIRE'd afterwards. The watched directory
;;;;   itself, meanwhile, is deliberately NOT taken as gospel from the
;;;;   saved image: an SBCL_BRIDGE_DIR in the resuming process's own
;;;;   environment overrides it (see RESUME-BRIDGE), because a shared
;;;;   workspace mounted at different paths in different environments
;;;;   (a host and a container, say) is exactly the situation a saved
;;;;   absolute path can't survive on its own.

(defpackage :sbcl-bridge
  (:use :cl)
  (:export #:run-bridge #:suspend-bridge))

(in-package :sbcl-bridge)

(defparameter *default-poll-interval* 0.2
  "Seconds to sleep between directory checks when idle.")

(defparameter *default-request-timeout* 30
  "Default per-request evaluation timeout, in seconds. NIL disables the
timeout unless a request overrides it with a TIMEOUT header.")

(defparameter *bridge-directory* nil
  "Directory the running/most-recently-started bridge loop is watching.
Preserved across save-lisp-and-die so a resumed image can re-enter
run-bridge on the same directory without needing any arguments -- but
see RESUME-BRIDGE: an SBCL_BRIDGE_DIR in the resuming process's own
environment takes precedence over this saved value, since a saved
absolute path is exactly the kind of thing that goes stale when a core
image is moved (e.g. a shared workspace mounted at different paths in
a host environment and a container).")

(defparameter *bridge-poll-interval* *default-poll-interval*
  "Poll interval in effect for the running bridge loop; preserved across
suspend/resume the same way as *bridge-directory*. Unlike
*bridge-directory*, this is NOT overridden from the environment on
resume: it's a runtime tuning knob, not something tied to where the
image happens to be running, so there's no equivalent of the
moved-workspace problem to correct for here.")

(defparameter *bridge-default-timeout* *default-request-timeout*
  "Default per-request timeout in effect for the running bridge loop;
preserved across suspend/resume the same way as *bridge-directory*.
Like *bridge-poll-interval*, this is session configuration, not a
location, so it is intentionally NOT overridden from the environment
on resume.")

(defparameter *default-backtrace-frames* 20
  "Max number of stack frames to include in an error/backtrace report.")

(defparameter *bridge-backtrace-frames* *default-backtrace-frames*
  "Backtrace frame limit in effect for the running bridge loop; preserved
across suspend/resume the same way as *bridge-directory*. Session
configuration, not a location -- intentionally NOT overridden from the
environment on resume, same reasoning as *bridge-poll-interval*.")

(defparameter *cancel-file-name* "cancel-request"
  "Name of the control file an external tool can drop in the bridge
directory to cancel whatever request is currently running.")

(defvar *bridge-working-path* nil
  "Full pathname of the claimed-request file (next-sbcl-input.working)
for the running bridge loop; set by run-bridge. Lets suspend-bridge
archive its own request file before save-lisp-and-die exits the
process (see archive-own-request).")

(defvar *bridge-archive-dir* nil
  "Full pathname of the processed/ archive directory for the running
bridge loop; set by run-bridge. See *bridge-working-path*.")

;;; ---------------------------------------------------------------------
;;; Cancellation support

(define-condition request-cancelled (error)
  ((reqid :initarg :reqid :reader request-cancelled-reqid))
  (:report (lambda (c s)
             (format s "Request ~a was cancelled" (request-cancelled-reqid c)))))

(defvar *watchdog-thread* nil
  "Handle to the running watchdog thread, if any. save-lisp-and-die
refuses to run with other threads alive, so suspend-bridge must stop
this one first.")

(defvar *current-request-lock* (sb-thread:make-mutex :name "bridge-current-request"))
(defvar *current-request-id* nil
  "reqid of the request currently being evaluated, or NIL if idle.
Guarded by *current-request-lock* since the watchdog thread reads it
while the main thread updates it. (The interrupt closure injected by
the watchdog reads it WITHOUT the lock -- that closure runs on the
main thread itself, the sole writer, so no lock is needed there, and
taking the mutex from an interrupt that might be delivered while the
main thread already holds it would self-deadlock.)")

(defvar *evaluating-request* nil
  "Dynamically bound to T for the extent of eval-and-report's handling
of a request. The cancellation closure the watchdog injects via
interrupt-thread checks this before signalling: without the check,
a cancellation racing with request completion could deliver
REQUEST-CANCELLED after eval-and-report's handlers are gone (e.g.
between the END-OUTPUT line and clear-current-request, or during the
archive rename), where it would land in the main loop's LOOP-ERROR
backstop and spuriously archive the request as an error.")

(defun set-current-request (reqid)
  (sb-thread:with-mutex (*current-request-lock*)
    (setf *current-request-id* reqid)))

(defun clear-current-request ()
  (sb-thread:with-mutex (*current-request-lock*)
    (setf *current-request-id* nil)))

(defun current-request-id ()
  (sb-thread:with-mutex (*current-request-lock*)
    *current-request-id*))

;;; ---------------------------------------------------------------------
;;; Output serialization
;;;
;;; Two threads write to *standard-output*: the main thread (markers,
;;; values, condition reports, and whatever the evaluated code itself
;;; prints) and the watchdog (CANCEL-REQUESTED / WATCHDOG-ERROR
;;; lines). SBCL streams are not thread-safe, so an unlucky collision
;;; could interleave two lines mid-character. All bridge-emitted lines
;;; therefore go through *output-lock*. User code's own output is NOT
;;; locked -- we can't wrap arbitrary evaluated code, and it only ever
;;; races against the watchdog's rare one-liners.
;;;
;;; The lock is RECURSIVE on purpose: a cancellation interrupt can land
;;; on the main thread while it already holds the lock (e.g. mid ';;;
;;; =>' line), and the unwinding handler then needs the lock again to
;;; print its CANCELLED/END-OUTPUT lines. A plain mutex would
;;; self-deadlock there.

(defvar *output-lock* (sb-thread:make-mutex :name "bridge-output")
  "Serializes bridge-emitted lines on *standard-output* between the
main thread and the watchdog thread. Always taken via
WITH-OUTPUT-LOCK (recursively).")

(defmacro with-output-lock (&body body)
  `(sb-thread:with-recursive-lock (*output-lock*)
     ,@body))

;;; ---------------------------------------------------------------------
;;; Debugger-hook backstop
;;;
;;; In --non-interactive mode SBCL's own default behavior on an
;;; unhandled condition is already to print a backtrace and exit rather
;;; than hang -- but installing our own hook lets us log which request
;;; was active, using our own markers, before that happens. This should
;;; be rare: the per-request handler-case in eval-and-report is meant
;;; to catch everything routine first.

(defun install-debugger-hook ()
  (let ((hook (lambda (condition previous-hook)
                (declare (ignore previous-hook))
                ;; Deliberately NOT under with-output-lock: this is a
                ;; last-gasp path on the way to process exit, and a
                ;; wedged lock holder must not be able to block it.
                ;; Worst case is one garbled line in a log that's about
                ;; to end anyway.
                (ignore-errors
                  (format t "~&;;; FATAL id=~a condition=~a~%"
                          (or (current-request-id) "none") condition)
                  (format t "~&;;; BRIDGE EXITING due to an unhandled condition~%")
                  (finish-output))
                (sb-ext:exit :code 70 :abort t))))
    ;; Set BOTH the ANSI hook and SBCL's extension hook. invoke-debugger
    ;; consults cl:*debugger-hook* first per the standard, but
    ;; --non-interactive/--disable-debugger installs SBCL's own
    ;; print-and-exit handler in sb-ext:*invoke-debugger-hook*, and the
    ;; precise interplay between the two is an implementation detail
    ;; that has shifted across SBCL versions. Setting both guarantees
    ;; the reqid-logging backstop runs regardless of which one a given
    ;; SBCL consults on a given path.
    (setf *debugger-hook* hook)
    (setf sb-ext:*invoke-debugger-hook* hook)))

;;; ---------------------------------------------------------------------
;;; Helpers

(defun ensure-directory-pathname (path)
  "Coerce PATH (a string or pathname) into a proper directory
pathname -- one with no NAME or TYPE component of its own -- so that
\"/foo/bar\" and \"/foo/bar/\" both become #P\"/foo/bar/\" rather than
#P\"/foo/bar\" being read as a file named \"bar\" inside directory
\"/foo/\". This distinction is not pedantry: MERGE-PATHNAMES resolves a
relative pathname against the DIRECTORY of its default, ignoring the
default's NAME entirely, so a caller-supplied directory that still
carries a spurious NAME component silently loses its last path segment
the moment anything is merged against it -- e.g. merging
\"next-sbcl-input.lisp\" against the wrongly-parsed #P\"/workspace\"
(name \"workspace\", directory just (:ABSOLUTE)) produces
#P\"/next-sbcl-input.lisp\", not #P\"/workspace/next-sbcl-input.lisp\".
A previous version of this function attempted the same fix via
 (merge-pathnames (make-pathname :directory '(:relative)) p)
which looks plausible but does NOT work: MERGE-PATHNAMES's component-
substitution rule pulls the default pathname's NAME back in whenever
the pathname argument leaves NAME unspecified, even though the
DIRECTORY component came out correctly merged -- so the broken name
survived the \"fix\" untouched. The only reliable approach is to
reconstruct the name+type as an explicit final directory component by
hand, which is what this function does."
  (let ((p (pathname path)))
    (if (or (pathname-name p) (pathname-type p))
        (make-pathname
         :directory (append (or (pathname-directory p) '(:relative))
                             (list (file-namestring p)))
         :name nil :type nil
         :defaults p)
        p)))

(defun slurp-file (path)
  "Read the entire contents of PATH as a string."
  (with-open-file (in path :direction :input :element-type 'character
                           :external-format :utf-8)
    (let* ((len (file-length in))
           (buf (make-string len)))
      (let ((n (read-sequence buf in)))
        (subseq buf 0 n)))))

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

(defun extract-header (text key &optional default)
  "Scan leading ';;; KEY: value' comment lines (stopping at the first
non-header line) for KEY (case-insensitive) and return its trimmed
value, or DEFAULT if not present."
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

(defun extract-reqid (text)
  "Pull an id out of a leading ';;; REQID: <id>' header, or synthesize
one if absent."
  (or (extract-header text "REQID")
      (format nil "auto-~a-~a" (get-universal-time) (random 1000000))))

(defun sanitize-reqid-for-filename (reqid)
  "Return REQID reduced to characters that are safe to embed in an
archive filename: alphanumerics plus '.', '_', and '-'; everything
else becomes '_', leading dots are stripped (no hidden files), and the
result is truncated to 100 characters. sbcl-client.sh always generates
safe ids, but the REQID header is free text -- a hand-written id
containing path separators, pathname wildcard characters (* ? etc.),
or other junk would otherwise make the archive RENAME-FILE fail (or
worse, name a file outside processed/). Distinct raw ids can sanitize
to the same name, in which case the later archive overwrites the
earlier one. Only the archive FILENAME is sanitized; markers in the
output and input logs always use the reqid exactly as submitted, so
clients can still correlate on it."
  (let* ((cleaned (map 'string
                       (lambda (ch)
                         (if (or (alphanumericp ch) (find ch "._-"))
                             ch
                             #\_))
                       reqid))
         (trimmed (string-left-trim "."
                                    (subseq cleaned 0 (min 100 (length cleaned))))))
    (if (zerop (length trimmed)) "request" trimmed)))

(defun extract-timeout (text default)
  "Pull a per-request timeout override out of a leading
';;; TIMEOUT: <seconds-or-none>' header. Returns DEFAULT if the header
is absent or unparseable; returns NIL (meaning no timeout) if the value
is \"none\". Note that eval-and-report treats any non-positive timeout
(0 or negative) the same as \"none\" -- i.e. TIMEOUT: 0 DISABLES the
timeout rather than timing out immediately."
  (let ((v (extract-header text "TIMEOUT")))
    (cond
      ((null v) default)
      ((string-equal v "none") nil)
      (t (or (ignore-errors (parse-integer v :junk-allowed t)) default)))))

(defun ends-with-newline-p (string)
  (and (plusp (length string))
       (char= (char string (1- (length string))) #\Newline)))

(defun log-input (input-log-path reqid raw-text)
  "Append the raw request text to the input log, bracketed by markers."
  (with-open-file (log input-log-path
                        :direction :output
                        :if-exists :append
                        :if-does-not-exist :create
                        :external-format :utf-8)
    (format log "~&;;; BEGIN-INPUT id=~a ts=~a~%" reqid (get-universal-time))
    (write-string raw-text log)
    (unless (ends-with-newline-p raw-text) (terpri log))
    (format log ";;; END-INPUT id=~a~%~%" reqid)
    (finish-output log)))

(defun safe-prin1-to-string (value)
  "PRIN1-TO-STRING, except a value whose PRINTING itself signals (a
broken PRINT-OBJECT method, dead foreign state, ...) degrades to an
#<unprintable TYPE> placeholder instead of turning a successfully
evaluated request into status=error -- the evaluation was fine; only
the presentation failed. Non-terminating printing (circular structure
with *print-circle* off) is not a signal and can't be caught here; the
request timeout covers that case."
  (handler-case (prin1-to-string value)
    (serious-condition ()
      (format nil "#<unprintable ~a>"
              (handler-case (type-of value)
                (serious-condition () "object"))))))

(defun run-forms (raw-text)
  "Read and evaluate each top-level form in RAW-TEXT in turn, printing
each form's values."
  (with-input-from-string (stream raw-text)
    (loop
      (let ((form (read stream nil :eof)))
        (when (eq form :eof) (return))
        (let ((values (multiple-value-list (eval form))))
          (with-output-lock
            (format t "~&;;; => ~{~a~^ ; ~}~%"
                    (mapcar #'safe-prin1-to-string values))))))))

(defun capture-backtrace (&key (count *bridge-backtrace-frames*))
  "Capture the current call stack as a string, deepest-caller-first,
stopping at COUNT frames or as soon as bridge-internal machinery is
reached (whichever comes first) -- frames from run-forms on down are
our own polling/eval plumbing, never useful to someone debugging their
own submitted code. Must be called from within the dynamic extent of
the condition being reported (i.e. from a handler-bind handler, not a
handler-case handler, since handler-case has already unwound the stack
by the time its handler body runs).

Falls back to the unfiltered sb-debug:print-backtrace if the internal
frame-walking functions this relies on aren't available (they are
present but unexported across the SBCL versions this was tested
against; a future SBCL could rename them)."
  (with-output-to-string (out)
    (let ((n 0))
      (handler-case
          (block done
            (funcall (find-symbol "MAP-BACKTRACE" :sb-debug)
             (lambda (frame)
               (when (>= n count) (return-from done))
               (let ((line (string-right-trim
                            '(#\Newline)
                            (with-output-to-string (s)
                              (funcall (find-symbol "PRINT-FRAME-CALL" :sb-debug)
                                       frame s)))))
                 (when (search "SBCL-BRIDGE" line)
                   (return-from done))
                 (format out "~d: ~a~%" n line)
                 (incf n)))))
        (error ()
          (ignore-errors
            (sb-debug:print-backtrace :stream out :count count :print-thread nil)))))))

(defun report-condition (label condition reqid)
  "Print a labeled condition report plus a bracketed backtrace to
*standard-output*."
  (with-output-lock
    (format t "~&;;; ~a: ~a~%" label condition)
    (format t "~&;;; BACKTRACE-BEGIN id=~a~%" reqid)
    (write-string (capture-backtrace))
    (format t "~&;;; BACKTRACE-END id=~a~%" reqid)))

(defun eval-and-report (reqid raw-text timeout)
  "Evaluate each top-level form in RAW-TEXT, printing values and status
to *standard-output*, bracketed by BEGIN-OUTPUT/END-OUTPUT markers.
TIMEOUT (seconds, or NIL for no limit) bounds the whole request; the
request can also be cancelled early by the watchdog thread via the
request-cancelled condition.

Uses handler-bind rather than handler-case so that backtraces can be
captured from the original signalling context, before the stack
unwinds."
  (with-output-lock
    (format t "~&;;; BEGIN-OUTPUT id=~a ts=~a~%" reqid (get-universal-time))
    (finish-output))
  ;; *evaluating-request* tells a late-arriving cancellation interrupt
  ;; that it is still safe to signal request-cancelled here (the
  ;; handlers below are established); see the defvar for the race this
  ;; prevents.
  (let ((*evaluating-request* t))
   (block done
    (handler-bind
        ((request-cancelled
           (lambda (c)
             (with-output-lock
               (format t "~&;;; CANCELLED: ~a~%" c)
               (format t "~&;;; END-OUTPUT id=~a status=cancelled~%" reqid))
             (return-from done)))
         (sb-ext:timeout
           (lambda (c)
             (declare (ignore c))
             (with-output-lock
               (format t "~&;;; TIMEOUT after ~a seconds~%" timeout)
               (format t "~&;;; END-OUTPUT id=~a status=timeout~%" reqid))
             (return-from done)))
         (storage-condition
           (lambda (c)
             ;; Heap/stack exhaustion etc. -- not a subtype of ERROR.
             ;; Grab a shallow backtrace before trying to claw back
             ;; some breathing room via GC.
             (report-condition "STORAGE-CONDITION" c reqid)
             (ignore-errors (sb-ext:gc :full t))
             (with-output-lock
               (format t "~&;;; END-OUTPUT id=~a status=fatal-condition~%" reqid))
             (return-from done)))
         (error
           (lambda (c)
             (report-condition "ERROR" c reqid)
             (with-output-lock
               (format t "~&;;; END-OUTPUT id=~a status=error~%" reqid))
             (return-from done)))
         (serious-condition
           (lambda (c)
             ;; Catch-all for anything else serious that isn't a plain
             ;; ERROR, so it can't reach the debugger hook and kill
             ;; the process.
             (report-condition "SERIOUS-CONDITION" c reqid)
             (with-output-lock
               (format t "~&;;; END-OUTPUT id=~a status=fatal-condition~%" reqid))
             (return-from done))))
      (if (and timeout (plusp timeout))
          (sb-ext:with-timeout timeout (run-forms raw-text))
          (run-forms raw-text))
      (with-output-lock
        (format t "~&;;; END-OUTPUT id=~a status=ok~%" reqid)))))
  (finish-output))

(defun process-one (working-path input-log-path default-timeout)
  "Log and evaluate the claimed request file. Returns its reqid."
  (let* ((raw (slurp-file working-path))
         (reqid (extract-reqid raw))
         (timeout (extract-timeout raw default-timeout)))
    (log-input input-log-path reqid raw)
    (set-current-request reqid)
    (unwind-protect
        (eval-and-report reqid raw timeout)
      (clear-current-request))
    reqid))

;;; ---------------------------------------------------------------------
;;; Watchdog thread (cancellation)

(defun watchdog-loop (dir main-thread poll-interval)
  "Runs for the lifetime of the bridge. Watches for a small control
file (*cancel-file-name*) and, if it names (or leaves blank, meaning
'whatever is current') a request that matches the one currently
executing, asynchronously interrupts the main thread with a
request-cancelled condition."
  (let ((cancel-path (merge-pathnames *cancel-file-name* dir)))
    (loop
      (handler-case
          (when (probe-file cancel-path)
            (let ((target (string-trim '(#\Space #\Tab #\Newline #\Return)
                                        (slurp-file cancel-path))))
              (ignore-errors (delete-file cancel-path))
              (let ((current (current-request-id)))
                (when (and current
                           (or (zerop (length target)) (string= target current)))
                  (with-output-lock
                    (format t "~&;;; CANCEL-REQUESTED id=~a~%" current)
                    (finish-output))
                  (sb-thread:interrupt-thread
                   main-thread
                   (lambda ()
                     ;; This runs ON the main thread, at whatever point
                     ;; the interrupt lands. Only signal if that thread
                     ;; is still inside eval-and-report evaluating the
                     ;; SAME request; if the request finished (or a new
                     ;; one started) in the window between the check
                     ;; above and delivery here, silently do nothing --
                     ;; there would be no handler for request-cancelled
                     ;; anymore and it would spuriously trip the main
                     ;; loop's LOOP-ERROR backstop. *current-request-id*
                     ;; is read lock-free on purpose: the main thread is
                     ;; its only writer and we ARE the main thread here,
                     ;; and taking the mutex could self-deadlock if the
                     ;; interrupt lands inside set/clear-current-request.
                     (when (and *evaluating-request*
                                (equal current *current-request-id*))
                       (error 'request-cancelled :reqid current))))))))
        (error (c)
          (with-output-lock
            (format t "~&;;; WATCHDOG-ERROR: ~a~%" c)
            (finish-output))))
      (sleep poll-interval))))

;;; ---------------------------------------------------------------------
;;; Quicklisp integration
;;;
;;; If QUICKLISP_HOME is set in the environment, the bridge makes a
;;; best-effort attempt to have a working Quicklisp available at that
;;; location, and pointed there, every time run-bridge starts --
;;; whether that's a genuine first start or a resume. Three cases:
;;;
;;;   1. Nothing at QUICKLISP_HOME yet -> install fresh (see
;;;      LOCATE-QUICKLISP-INSTALLER / INSTALL-QUICKLISP-IF-NEEDED for
;;;      where the installer script itself comes from).
;;;   2. Quicklisp not yet loaded in THIS image, but already installed
;;;      at QUICKLISP_HOME (by a previous process, or by step 1 just
;;;      now) -> just (load ".../setup.lisp"), an ordinary first
;;;      bootstrap.
;;;   3. Quicklisp already loaded in this image (a resume where it was
;;;      loaded before suspend) -> if QUICKLISP_HOME now names a
;;;      DIFFERENT directory than what's baked in, redirect the
;;;      already-loaded client there (SYNC-QUICKLISP-HOME) rather than
;;;      trying to reload anything.
;;;
;;; This exists for the same reason the SBCL_BRIDGE_DIR/SBCL_HOME
;;; overrides do: in a shared-workspace-across-environments setup (a
;;; host and a container, say), QUICKLISP_HOME can legitimately be a
;;; different absolute path in each environment even when it's
;;; logically "the same" Quicklisp installation (or two independent
;;; ones the operator wants used in each place respectively) -- and,
;;; verified directly against the Quicklisp client source rather than
;;; assumed, simply SETF-ing ql:*quicklisp-home* is not sufficient to
;;; redirect an already-loaded client (see SYNC-QUICKLISP-HOME).
;;;
;;; Every entry point here is best-effort and defensive: none of this
;;; is allowed to prevent the bridge from starting. A failure at any
;;; step is logged and the bridge proceeds without a working Quicklisp
;;; for that session, available to try again on the next resume.
;;;
;;; A note on style: essentially everything Quicklisp-related below is
;;; accessed indirectly through QL-SYMBOL/QL-VALUE/QL-CALL rather than
;;; as ordinary package-qualified symbols like QL:QUICKLOAD. This is
;;; not a stylistic preference -- writing a literal reference to a
;;; symbol in a package that doesn't exist yet (ql, ql-setup,
;;; ql-dist, quicklisp-quickstart -- none of which exist on a system
;;; that has never loaded Quicklisp) is a READER error in Common Lisp,
;;; not a runtime error: it would prevent this FILE from loading at
;;; all, for every user, including those who never set QUICKLISP_HOME.
;;; Resolving everything through FIND-PACKAGE/FIND-SYMBOL on strings
;;; defers that resolution to runtime, after the relevant package is
;;; known to exist.

(defparameter *quicklisp-installer-url* "https://beta.quicklisp.org/quicklisp.lisp"
  "Default URL to download a quicklisp.lisp bootstrap installer from,
as a last resort, if one can't be found locally. Overridable per-run
via the QUICKLISP_INSTALLER_URL environment variable (see
EFFECTIVE-QUICKLISP-INSTALLER-URL) -- useful for pointing at an
internal mirror when the real one isn't reachable, and also what
makes it possible to test the \"nothing worked\" path deterministically
regardless of whether this machine's curl/wget can actually reach the
real internet (see sbcl-bridge-test.sh).")

(defun effective-quicklisp-installer-url ()
  "QUICKLISP_INSTALLER_URL from the environment if set and non-empty,
else *quicklisp-installer-url*."
  (let ((env (sb-ext:posix-getenv "QUICKLISP_INSTALLER_URL")))
    (if (and env (plusp (length env))) env *quicklisp-installer-url*)))

(defun ql-symbol (package-name symbol-name)
  "Find SYMBOL-NAME (a string) in PACKAGE-NAME (a string), or NIL if
either the package or the symbol doesn't exist. See the note at the
top of this section on why this indirection matters."
  (let ((package (find-package package-name)))
    (and package (find-symbol symbol-name package))))

(defun ql-value (package-name symbol-name)
  "SYMBOL-VALUE of PACKAGE-NAME:SYMBOL-NAME (both strings), or NIL if
the package, symbol, or binding doesn't exist."
  (let ((sym (ql-symbol package-name symbol-name)))
    (and sym (boundp sym) (symbol-value sym))))

(defun (setf ql-value) (new-value package-name symbol-name)
  "Set PACKAGE-NAME:SYMBOL-NAME (both strings) to NEW-VALUE. Errors if
the package or symbol doesn't exist -- unlike QL-VALUE's read side,
there's no sensible NIL fallback for a set that silently didn't
happen, so callers should confirm the target is expected to exist
(e.g. by checking FIND-PACKAGE first) before setting through this."
  (let ((sym (ql-symbol package-name symbol-name)))
    (unless sym (error "~a:~a not found" package-name symbol-name))
    (setf (symbol-value sym) new-value)))

(defun ql-call (package-name symbol-name &rest args)
  "Like (funcall (find-symbol ...) ...), resolved from strings. Errors
if the package or symbol doesn't exist."
  (let ((sym (ql-symbol package-name symbol-name)))
    (unless sym (error "~a:~a not found" package-name symbol-name))
    (apply sym args)))

(defun run-and-check (program args output-file)
  "Best-effort: run PROGRAM with ARGS via SB-EXT:RUN-PROGRAM (searching
PATH), discarding its own stdout/stderr, and report success only if it
exited zero AND OUTPUT-FILE exists and is non-empty afterward. Never
signals -- a missing PROGRAM, a network failure, or anything else
simply results in NIL, exactly like a failed download should."
  (ignore-errors
    (let ((process (sb-ext:run-program program args
                                        :search t
                                        :output nil
                                        :error nil
                                        :input nil
                                        :wait t)))
      (and process
           (eql (sb-ext:process-exit-code process) 0)
           (probe-file output-file)
           (plusp (with-open-file (s output-file :element-type '(unsigned-byte 8))
                    (file-length s)))))))

(defun download-file (url target-path)
  "Best-effort download of URL to TARGET-PATH using curl or wget,
whichever is found first on PATH. Downloads to a temp file and renames
into place atomically, so a failed or interrupted download never
leaves a partial file sitting at TARGET-PATH. Returns T on success,
NIL otherwise -- never signals. Deliberately shells out rather than
speaking HTTP/TLS directly: writing (and trusting) a TLS client is a
lot of surface area for what curl/wget already do robustly, and
that's almost always available on a system that also has SBCL."
  (ignore-errors
    (ensure-directories-exist target-path)
    (let ((tmp (make-pathname
                :name (concatenate 'string (pathname-name target-path) "-download-tmp")
                :defaults target-path)))
      (ignore-errors (delete-file tmp))
      (when (or (run-and-check "curl" (list "-fsSL" "--max-time" "30" "-o" (namestring tmp) url) tmp)
                (run-and-check "wget" (list "-q" "--timeout=30" "-O" (namestring tmp) url) tmp))
        (rename-file tmp target-path)
        t))))

(defun locate-quicklisp-installer (bridge-dir)
  "Best-effort search for a usable quicklisp.lisp bootstrap installer,
trying, in order:
  1. QUICKLISP_LISP -- an environment variable naming its exact path,
     for callers who already have a copy somewhere of their choosing;
  2. /usr/share/common-lisp/source/quicklisp/quicklisp.lisp -- where
     it lands on Debian/Ubuntu if installed via a system package;
  3. a copy already downloaded by a previous run of this function,
     cached in BRIDGE-DIR, so a working installer is only ever
     downloaded once even across many restarts;
  4. downloading a fresh copy from EFFECTIVE-QUICKLISP-INSTALLER-URL
     into that same cache location.
Returns a pathname, or NIL if every option failed."
  (let ((cached (merge-pathnames "quicklisp-installer.lisp" bridge-dir))
        (env-path (sb-ext:posix-getenv "QUICKLISP_LISP"))
        (url (effective-quicklisp-installer-url)))
    (or (and env-path (plusp (length env-path)) (probe-file env-path))
        (probe-file "/usr/share/common-lisp/source/quicklisp/quicklisp.lisp")
        (probe-file cached)
        (progn
          (with-output-lock
            (format t "~&;;; QUICKLISP: no local quicklisp.lisp found (checked QUICKLISP_LISP and ~
the usual Debian/Ubuntu path); attempting to download from ~a~%"
                    url)
            (finish-output))
          (and (download-file url cached)
               (probe-file cached))))))

(defun install-quicklisp-if-needed (target-home bridge-dir)
  "Best-effort fresh Quicklisp install at TARGET-HOME. Never signals;
on any failure, logs why and returns NIL, leaving TARGET-HOME without
a working Quicklisp for this session (a later resume/restart gets
another chance). Returns T on apparent success."
  (with-output-lock
    (format t "~&;;; QUICKLISP: no installation found at ~a; installing~%" target-home)
    (finish-output))
  (handler-case
      (let ((installer (locate-quicklisp-installer bridge-dir)))
        (unless installer
          (with-output-lock
            (format t "~&;;; QUICKLISP: could not find or download a quicklisp.lisp installer; ~
continuing without Quicklisp this session~%")
            (finish-output))
          (return-from install-quicklisp-if-needed nil))
        (load installer)
        (let ((install-fn (ql-symbol "QUICKLISP-QUICKSTART" "INSTALL")))
          (unless (and install-fn (fboundp install-fn))
            (with-output-lock
              (format t "~&;;; QUICKLISP: ~a loaded but did not define ~
QUICKLISP-QUICKSTART:INSTALL as expected; giving up~%" installer)
              (finish-output))
            (return-from install-quicklisp-if-needed nil))
          (funcall install-fn :path target-home))
        (with-output-lock
          (format t "~&;;; QUICKLISP: installed at ~a~%" target-home)
          (finish-output))
        t)
    (error (c)
      (with-output-lock
        (format t "~&;;; QUICKLISP: install failed: ~a; continuing without Quicklisp this session~%" c)
        (finish-output))
      nil)))

(defun paths-equal-p (a b)
  "T if A and B name the same existing filesystem location (compared
via TRUENAME, so equivalent-but-differently-spelled paths -- relative
vs. absolute, symlinks, trailing-slash differences -- compare equal);
NIL if either fails to resolve (e.g. doesn't exist, which is expected
whenever a suspended image's baked-in path doesn't exist in the
resuming environment) or if they genuinely differ."
  (let ((ta (ignore-errors (truename a)))
        (tb (ignore-errors (truename b))))
    (and ta tb (equal ta tb))))

(defun sync-quicklisp-home (target-home)
  "Point an already-loaded Quicklisp client at TARGET-HOME instead of
wherever ql:*quicklisp-home* currently points -- for the same reason
RESUME-BRIDGE overrides *bridge-directory* from SBCL_BRIDGE_DIR: an
absolute path baked into a suspended image can go stale when the
image moves to a different environment.

Setting ql-setup:*quicklisp-home* alone is NOT enough for this to
actually work, which was verified directly against the real Quicklisp
client source rather than assumed: ql:*local-project-directories* is a
DEFPARAMETER computed once, at load time, via (qmerge \"local-projects/\"),
not recomputed on every access -- so it silently keeps pointing at the
OLD home forever unless reset by hand here. Dist objects themselves
need no equivalent fix and are NOT handled here: ql-dist:all-dists
rebuilds its dist objects from scratch, via qmerge again, on every
single call (see standard-dist-enumeration-function in Quicklisp's own
dist.lisp) rather than caching them in a global -- so plain quickloads
of dist-hosted systems already follow *quicklisp-home* correctly with
no help needed."
  (setf (ql-value "QL-SETUP" "*QUICKLISP-HOME*") target-home)
  (setf (ql-value "QL" "*LOCAL-PROJECT-DIRECTORIES*")
        (list (ql-call "QL-SETUP" "QMERGE" "local-projects/")))
  ;; Re-running QL:SETUP is cheap and has two genuinely useful side
  ;; effects beyond what's fixed above: it creates local-projects/ at
  ;; the new home if missing, and re-runs any local-init/*.lisp files
  ;; found there -- relevant if the two environments have different
  ;; local customizations.
  (ql-call "QL" "SETUP"))

(defun ensure-quicklisp-configured (bridge-dir)
  "If QUICKLISP_HOME is set in the environment, make a best-effort
attempt to have a working Quicklisp available there and pointed there,
covering all three cases documented at the top of this section.
Called from RUN-BRIDGE on every start, fresh or resumed. Does nothing
at all if QUICKLISP_HOME is unset or empty -- this entire feature is
opt-in, purely by that variable's presence."
  (let ((env-home (sb-ext:posix-getenv "QUICKLISP_HOME")))
    (unless (and env-home (plusp (length env-home)))
      (return-from ensure-quicklisp-configured))
    (let* ((target-home (ensure-directory-pathname env-home))
           (setup-lisp-path (merge-pathnames "setup.lisp" target-home)))
      (unless (probe-file setup-lisp-path)
        (install-quicklisp-if-needed target-home bridge-dir))
      (unless (probe-file setup-lisp-path)
        (with-output-lock
          (format t "~&;;; QUICKLISP: still not available at ~a after an install attempt; ~
continuing without it this session~%" target-home)
          (finish-output))
        (return-from ensure-quicklisp-configured))
      (if (find-package "QL-SETUP")
          ;; Client already resident in this image -- either loaded
          ;; moments ago by install-quicklisp-if-needed as a side
          ;; effect of installing, or (the resume case) already loaded
          ;; before this image was suspended. Either way, just make
          ;; sure it's pointed at the right place; never reload it.
          (let ((current-home (ql-value "QL-SETUP" "*QUICKLISP-HOME*")))
            (unless (paths-equal-p current-home target-home)
              (with-output-lock
                (format t "~&;;; QUICKLISP: QUICKLISP_HOME changed: ~a -> ~a~%"
                        current-home target-home)
                (finish-output))
              (sync-quicklisp-home target-home)))
          ;; First time Quicklisp is being loaded in this image at all.
          (handler-case
              (progn
                (load setup-lisp-path)
                (with-output-lock
                  (format t "~&;;; QUICKLISP: loaded, home=~a~%" target-home)
                  (finish-output)))
            (error (c)
              (with-output-lock
                (format t "~&;;; QUICKLISP: loading ~a failed: ~a; continuing without ~
Quicklisp this session~%" setup-lisp-path c)
                (finish-output))))))))

;;; ---------------------------------------------------------------------
;;; Main loop

(defun run-bridge (&key (directory (error "DIRECTORY is required"))
                         (poll-interval *default-poll-interval*)
                         (default-timeout *default-request-timeout*)
                         (backtrace-frames *default-backtrace-frames*)
                         (input-name "next-sbcl-input.lisp")
                         (working-name "next-sbcl-input.working")
                         (input-log-name "sbcl-input.log")
                         (archive-subdir "processed"))
  "Monitor DIRECTORY for INPUT-NAME; when found, atomically claim it,
log it, evaluate it, and print correlated markers to *standard-output*.
Does not return under normal operation."
  (setf *bridge-directory* directory)
  (setf *bridge-poll-interval* poll-interval)
  (setf *bridge-default-timeout* default-timeout)
  (setf *bridge-backtrace-frames* backtrace-frames)
  (install-debugger-hook)
  (let* ((dir (ensure-directory-pathname directory))
         (input-path (merge-pathnames input-name dir))
         (working-path (merge-pathnames working-name dir))
         (input-log-path (merge-pathnames input-log-name dir))
         (archive-dir (merge-pathnames
                       (make-pathname :directory (list :relative archive-subdir))
                       dir)))
    (ensure-directories-exist archive-dir)
    ;; Recorded so suspend-bridge can archive its own request file
    ;; right before save-lisp-and-die (see archive-own-request).
    (setf *bridge-working-path* working-path
          *bridge-archive-dir* archive-dir)
    ;; A leftover working file means a prior run claimed a request but
    ;; never finished it -- e.g. it crashed, was SIGKILLed mid-request,
    ;; or called save-lisp-and-die directly rather than through
    ;; suspend-bridge (a normal suspend-bridge archives its own request
    ;; file under its reqid before saving, so it leaves no leftover).
    ;; Archive it out of the way rather than leaving it stuck there.
    (when (probe-file working-path)
      (rename-file working-path
                   (merge-pathnames
                    (format nil "leftover-~a.lisp" (get-universal-time))
                    archive-dir)))
    ;; Clear out any stale cancel-request left over from before a
    ;; restart -- it should never apply to a newly (re)started bridge.
    (let ((cancel-path (merge-pathnames *cancel-file-name* dir)))
      (when (probe-file cancel-path) (ignore-errors (delete-file cancel-path))))
    #+sb-thread
    (let ((main-thread sb-thread:*current-thread*))
      (setf *watchdog-thread*
            (sb-thread:make-thread
             (lambda () (watchdog-loop dir main-thread poll-interval))
             :name "bridge-watchdog")))
    #-sb-thread
    (format t "~&;;; WARNING: this SBCL has no thread support; cancellation is disabled (timeouts still work).~%")
    (with-output-lock
      (format t "~&;;; SBCL-BRIDGE STARTED dir=~a ts=~a default-timeout=~a~%"
              dir (get-universal-time) (or default-timeout "none"))
      (finish-output))
    ;; Best-effort, opt-in (via QUICKLISP_HOME) Quicklisp setup -- see
    ;; the "Quicklisp integration" section above. The function itself
    ;; is already internally defensive (every step has its own
    ;; handler-case/ignore-errors and logs rather than signals), but
    ;; this outer IGNORE-ERRORS is a deliberate second layer: nothing
    ;; in this feature, including a bug in it, may ever prevent the
    ;; bridge from reaching its main loop and becoming usable for
    ;; ordinary (non-Quicklisp) requests.
    (ignore-errors (ensure-quicklisp-configured dir))
    (loop
      (block iteration
        (handler-bind
            ((error (lambda (c)
                      ;; Infrastructure-level failure (e.g. rename-file
                      ;; itself failing) -- process-one already has its
                      ;; own comprehensive handling for request errors,
                      ;; so this is a rare backstop. Never let it kill
                      ;; the loop.
                      (report-condition "LOOP-ERROR" c "loop")
                      (finish-output)
                      (ignore-errors
                        (when (probe-file working-path)
                          (rename-file working-path
                                       (merge-pathnames
                                        (format nil "error-~a.lisp" (get-universal-time))
                                        archive-dir))))
                      (sleep poll-interval)
                      (return-from iteration))))
          (if (probe-file input-path)
              (progn
                (rename-file input-path working-path)
                (let ((reqid (process-one working-path input-log-path default-timeout)))
                  ;; The request may have disposed of its own working
                  ;; file: suspend-bridge archives it itself just
                  ;; before save-lisp-and-die, so if we get here after
                  ;; a FAILED save, there is nothing left to rename.
                  (when (probe-file working-path)
                    (rename-file working-path
                                  (merge-pathnames
                                   (format nil "~a.lisp"
                                           (sanitize-reqid-for-filename reqid))
                                   archive-dir)))))
              (sleep poll-interval)))))))

;;; ---------------------------------------------------------------------
;;; Suspend / resume
;;;
;;; save-lisp-and-die snapshots the entire heap (every function,
;;; variable, and package the bridge has picked up since it started)
;;; and then terminates the process. It does NOT resume execution where
;;; you called it from -- on reload it always starts over from a
;;; top-level entry point, which is exactly what we want here: give it
;;; a :toplevel function that just calls run-bridge again with the same
;;; settings we cached in *bridge-directory* / *bridge-poll-interval* /
;;; *bridge-default-timeout*.

(defun resume-bridge ()
  "Entry point baked into a suspended image via save-lisp-and-die's
:toplevel; re-enters the polling loop with the settings that were in
effect when the image was saved -- except for the watched directory,
which is instead taken from the resuming process's own SBCL_BRIDGE_DIR
environment variable when one is set.

This matters for exactly the scenario *bridge-directory*'s docstring
describes: a core suspended with one absolute path baked in (say
/home/andrew/workspace/sbcl-bridge, because that's where it happens to
live on the host) and then resumed somewhere the same shared workspace
is mounted at a different path (say /workspace/sbcl-bridge, inside a
container). Without this override the resumed bridge would be
healthy, watching, and running -- and silently looking in the wrong
directory, seeing no requests ever arrive. An --eval-based override on
the command line is not an option here: suspend-bridge saves with
:save-runtime-options t, which makes the resulting executable refuse
to parse ANY runtime options (including --eval) when run directly,
which is the primary way sbcl-bridge-ctl.sh's resume command invokes
it. Reading the environment from ordinary Lisp code after the runtime
has already started is the one mechanism that works uniformly
regardless of invocation style (direct executable, or `sbcl --core`).

Only the directory is treated this way. *bridge-poll-interval*,
*bridge-default-timeout*, and *bridge-backtrace-frames* are ordinary
session configuration rather than anything location-dependent, so they
continue to carry over from the saved image unconditionally -- see
their docstrings.

The comparison against the saved directory goes through PATHS-EQUAL-P
(truename-based), not a raw string/namestring comparison, precisely
because the two sides routinely have equivalent-but-differently-spelled
values that a plain string compare would treat as different: a fresh
start bakes in a trailing slash (sbcl-bridge-ctl.sh's cmd_start appends
one explicitly), but SBCL_BRIDGE_DIR as exported for a resume comes
from a plain `pwd`, which never has one. Without normalizing, a resume
onto the SAME directory a fresh start used would print a spurious
'overrides the directory saved in this image' message -- generally
harmless, but confusing, and once misleading enough to be worth
avoiding: after that first (spurious) override fired, *bridge-directory*
would be overwritten with the no-trailing-slash SBCL_BRIDGE_DIR string,
which would then happen to string-match on every SUBSEQUENT resume,
making the message appear exactly once and never again even though
nothing about the environment had actually changed."
  (let ((dir-override (sb-ext:posix-getenv "SBCL_BRIDGE_DIR")))
    (when (and dir-override (plusp (length dir-override))
               (not (paths-equal-p dir-override *bridge-directory*)))
      (with-output-lock
        (format t "~&;;; RESUME: SBCL_BRIDGE_DIR=~a overrides the directory saved in this ~
image (~a)~%"
                dir-override *bridge-directory*)
        (finish-output))
      (setf *bridge-directory* dir-override)))
  (run-bridge :directory *bridge-directory*
              :poll-interval *bridge-poll-interval*
              :default-timeout *bridge-default-timeout*
              :backtrace-frames *bridge-backtrace-frames*))

(defun version-sidecar-path (core-path)
  (concatenate 'string (namestring core-path) ".version"))

(defun write-version-sidecar (core-path)
  "Record the SBCL version, machine type, and home directory in effect
at save time, next to the core image. The version/machine-type are for
flagging a resume attempt on a different build; the home directory is
actually load-bearing (see suspend-bridge's docstring) and is restored
into SBCL_HOME by sbcl-bridge-ctl.sh's resume command."
  (with-open-file (s (version-sidecar-path core-path)
                      :direction :output
                      :if-exists :supersede
                      :if-does-not-exist :create)
    (format s "~a~%~a~%~a~%"
            (lisp-implementation-version)
            (machine-type)
            ;; Best-effort home: what this image derives itself, or --
            ;; important for a suspend of a RESUMED image, where the
            ;; derivation can come back NIL -- the SBCL_HOME that
            ;; sbcl-bridge-ctl.sh exported when resuming us. Normalized
            ;; via TRUENAME where possible so the sidecar carries
            ;; /usr/lib/sbcl/ rather than /usr/bin/../lib/sbcl/.
            (let* ((home (or (sb-int:sbcl-homedir-pathname)
                             (let ((env (sb-ext:posix-getenv "SBCL_HOME")))
                               (and env (plusp (length env))
                                    (ignore-errors (pathname env))))))
                   (home (and home
                              (or (ignore-errors (truename home)) home))))
              (if home (namestring home) "")))))

(defun archive-own-request ()
  "Archive the currently-claimed request file (if any) into processed/
under its own reqid, exactly as run-bridge would have done after the
request returned. For use by requests that never return control to
run-bridge: suspend-bridge's save-lisp-and-die exits the process
before run-bridge's own archive rename can run, which would otherwise
leave next-sbcl-input.working behind to be archived as
leftover-<ts>.lisp by the next (resumed) start. Deliberately
best-effort (ignore-errors): failing to archive must never abort a
suspend."
  (when (and *bridge-working-path* *bridge-archive-dir*)
    (let ((reqid (or (current-request-id)
                     (format nil "suspend-~a" (get-universal-time)))))
      (ignore-errors
        (when (probe-file *bridge-working-path*)
          (rename-file *bridge-working-path*
                       (merge-pathnames
                        (format nil "~a.lisp"
                                (sanitize-reqid-for-filename reqid))
                        *bridge-archive-dir*)))))))

(defun suspend-bridge (&key (core-path (error "core-path required")))
  "Save an executable image capturing all current state to CORE-PATH,
then terminate this process. Intended to be called as (part of) a
normal request submitted through the usual next-sbcl-input.lisp
mechanism. Running the saved image later (just executing the file)
resumes the polling loop on the same directory via resume-bridge.

IMPORTANT: a resumed executable image does not know where SBCL's
contrib modules (sb-rotate-byte, sb-posix, sb-bsd-sockets, etc.) live
on disk -- (sb-int:sbcl-homedir-pathname) comes back NIL in a resumed
image, since that's normally derived from the location of the running
sbcl binary itself, and the saved image is just a data blob executed
from wherever it happens to sit (typically the bridge's cores/
directory), not the original SBCL install. Anything that calls
cl:require for a contrib module NOT already loaded before this
suspend will fail with \"Don't know how to REQUIRE ...\" after a
resume, even though the exact same code works fine on a fresh start.
write-version-sidecar records the home directory this process actually
had at save time (normalized via TRUENAME, and falling back to the
SBCL_HOME we were ourselves resumed with, so the record survives
suspend/resume chains) so sbcl-bridge-ctl.sh's resume command can
restore a home via the SBCL_HOME environment variable. Resume treats
the recorded value as a VALIDATED CANDIDATE rather than gospel -- the
resuming machine may be a different host or container whose sbcl lives
at another prefix, in which case resume prefers the local
installation's own home when its build matches this image. The more
robust fix, when it's an option, is to load (via quickload or plain
require) everything your workload needs BEFORE suspending -- once a
contrib is loaded into the image, it's baked into the heap and never
needs to be found on disk again after a resume."
  (with-output-lock
    (format t "~&;;; SUSPENDING to ~a~%" core-path)
    (finish-output))
  ;; save-lisp-and-die refuses to run with other threads alive.
  #+sb-thread
  (when *watchdog-thread*
    (ignore-errors (sb-thread:terminate-thread *watchdog-thread*))
    (ignore-errors (sb-thread:join-thread *watchdog-thread* :timeout 5 :default nil))
    (setf *watchdog-thread* nil))
  (write-version-sidecar core-path)
  ;; Archive this request's own claimed file (next-sbcl-input.working)
  ;; under its reqid now: save-lisp-and-die never returns, so
  ;; run-bridge's usual post-request archive rename will never run for
  ;; this request. Without this, every normal suspend would leave the
  ;; working file behind to be archived as leftover-<ts>.lisp on
  ;; resume. Done as late as possible -- after the sidecar, right
  ;; before the save -- so that if anything above fails, the request
  ;; errors out through the normal path with its working file still in
  ;; place; and if the save itself fails, run-bridge's post-request
  ;; rename is conditional on the working file still existing, so
  ;; nothing conflicts.
  (archive-own-request)
  (sb-ext:gc :full t)
  (sb-ext:save-lisp-and-die core-path
                            :toplevel #'resume-bridge
                            :executable t
                            :save-runtime-options t))
