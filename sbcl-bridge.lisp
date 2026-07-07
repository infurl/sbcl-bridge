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
;;;;   hook -- no --load/--eval flags needed on resume. A sidecar
;;;;   "<core-path>.version" file records the SBCL version and machine
;;;;   type in effect at save time, so a mismatched resume attempt can
;;;;   be flagged.

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
run-bridge on the same directory without needing any arguments.")

(defparameter *bridge-poll-interval* *default-poll-interval*
  "Poll interval in effect for the running bridge loop; preserved across
suspend/resume the same way as *bridge-directory*.")

(defparameter *bridge-default-timeout* *default-request-timeout*
  "Default per-request timeout in effect for the running bridge loop;
preserved across suspend/resume the same way as *bridge-directory*.")

(defparameter *default-backtrace-frames* 20
  "Max number of stack frames to include in an error/backtrace report.")

(defparameter *bridge-backtrace-frames* *default-backtrace-frames*
  "Backtrace frame limit in effect for the running bridge loop; preserved
across suspend/resume the same way as *bridge-directory*.")

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
  (let* ((dir (let ((p (pathname directory)))
                ;; make sure it's treated as a directory pathname
                (if (pathname-name p)
                    (merge-pathnames (make-pathname :directory '(:relative)) p)
                    p)))
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
effect when the image was saved."
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
            (let ((home (sb-int:sbcl-homedir-pathname)))
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
had at save time so sbcl-bridge-ctl.sh's resume command can restore it
via the SBCL_HOME environment variable. The more robust fix, when it's
an option, is to load (via quickload or plain require) everything your
workload needs BEFORE suspending -- once a contrib is loaded into the
image, it's baked into the heap and never needs to be found on disk
again after a resume."
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
