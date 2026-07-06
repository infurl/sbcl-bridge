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
;;;;   currently running, whether or not it has timed out yet.
;;;;
;;;; Condition handling:
;;;;   Beyond ordinary ERROR conditions, STORAGE-CONDITION (e.g. heap
;;;;   exhaustion) and other SERIOUS-CONDITIONs are caught per-request
;;;;   so a single bad request can't silently take the whole process
;;;;   down. A *debugger-hook* is also installed as a last-resort
;;;;   backstop: if something still escapes all of that, it is logged
;;;;   with the active request id before the process exits, rather than
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

(defparameter *cancel-file-name* "cancel-request"
  "Name of the control file an external tool can drop in the bridge
directory to cancel whatever request is currently running.")

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
while the main thread updates it.")

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
;;; Debugger-hook backstop
;;;
;;; In --non-interactive mode SBCL's own default behavior on an
;;; unhandled condition is already to print a backtrace and exit rather
;;; than hang -- but installing our own hook lets us log which request
;;; was active, using our own markers, before that happens. This should
;;; be rare: the per-request handler-case in eval-and-report is meant
;;; to catch everything routine first.

(defun install-debugger-hook ()
  (setf *debugger-hook*
        (lambda (condition hook)
          (declare (ignore hook))
          (ignore-errors
            (format t "~&;;; FATAL id=~a condition=~a~%"
                    (or (current-request-id) "none") condition)
            (format t "~&;;; BRIDGE EXITING due to an unhandled condition~%")
            (finish-output))
          (sb-ext:exit :code 70 :abort t))))

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

(defun extract-timeout (text default)
  "Pull a per-request timeout override out of a leading
';;; TIMEOUT: <seconds-or-none>' header. Returns DEFAULT if the header
is absent or unparseable; returns NIL (meaning no timeout) if the value
is \"none\"."
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

(defun run-forms (raw-text)
  "Read and evaluate each top-level form in RAW-TEXT in turn, printing
each form's values."
  (with-input-from-string (stream raw-text)
    (loop
      (let ((form (read stream nil :eof)))
        (when (eq form :eof) (return))
        (let ((values (multiple-value-list (eval form))))
          (format t "~&;;; => ~{~S~^ ; ~}~%" values))))))

(defun eval-and-report (reqid raw-text timeout)
  "Evaluate each top-level form in RAW-TEXT, printing values and status
to *standard-output*, bracketed by BEGIN-OUTPUT/END-OUTPUT markers.
TIMEOUT (seconds, or NIL for no limit) bounds the whole request; the
request can also be cancelled early by the watchdog thread via the
request-cancelled condition."
  (format t "~&;;; BEGIN-OUTPUT id=~a ts=~a~%" reqid (get-universal-time))
  (finish-output)
  (handler-case
      (progn
        (if (and timeout (plusp timeout))
            (sb-ext:with-timeout timeout (run-forms raw-text))
            (run-forms raw-text))
        (format t "~&;;; END-OUTPUT id=~a status=ok~%" reqid))
    (request-cancelled (c)
      (format t "~&;;; CANCELLED: ~a~%" c)
      (format t "~&;;; END-OUTPUT id=~a status=cancelled~%" reqid))
    (sb-ext:timeout ()
      (format t "~&;;; TIMEOUT after ~a seconds~%" timeout)
      (format t "~&;;; END-OUTPUT id=~a status=timeout~%" reqid))
    (error (c)
      (format t "~&;;; ERROR: ~a~%" c)
      (format t "~&;;; END-OUTPUT id=~a status=error~%" reqid))
    (storage-condition (c)
      ;; Heap/stack exhaustion etc. -- not a subtype of ERROR. Try to
      ;; claw back some breathing room before resuming the main loop.
      (format t "~&;;; STORAGE-CONDITION: ~a~%" c)
      (ignore-errors (sb-ext:gc :full t))
      (format t "~&;;; END-OUTPUT id=~a status=fatal-condition~%" reqid))
    (serious-condition (c)
      ;; Catch-all for anything else serious that isn't a plain ERROR,
      ;; so it can't reach the debugger hook and kill the process.
      (format t "~&;;; SERIOUS-CONDITION: ~a~%" c)
      (format t "~&;;; END-OUTPUT id=~a status=fatal-condition~%" reqid)))
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
                  (format t "~&;;; CANCEL-REQUESTED id=~a~%" current)
                  (finish-output)
                  (sb-thread:interrupt-thread
                   main-thread
                   (lambda () (error 'request-cancelled :reqid current)))))))
        (error (c)
          (format t "~&;;; WATCHDOG-ERROR: ~a~%" c)
          (finish-output)))
      (sleep poll-interval))))

;;; ---------------------------------------------------------------------
;;; Main loop

(defun run-bridge (&key (directory (error "DIRECTORY is required"))
                         (poll-interval *default-poll-interval*)
                         (default-timeout *default-request-timeout*)
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
    ;; A leftover working file means a prior run claimed a request but
    ;; never finished it (e.g. it called suspend-bridge, or crashed).
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
    (format t "~&;;; SBCL-BRIDGE STARTED dir=~a ts=~a default-timeout=~a~%"
            dir (get-universal-time) (or default-timeout "none"))
    (finish-output)
    (loop
      (handler-case
          (if (probe-file input-path)
              (progn
                (rename-file input-path working-path)
                (let ((reqid (process-one working-path input-log-path default-timeout)))
                  (rename-file working-path
                                (merge-pathnames
                                 (format nil "~a.lisp" reqid)
                                 archive-dir))))
              (sleep poll-interval))
        (error (c)
          ;; Never let a bad request kill the loop.
          (format t "~&;;; LOOP-ERROR: ~a~%" c)
          (finish-output)
          (ignore-errors
            (when (probe-file working-path)
              (rename-file working-path
                            (merge-pathnames
                             (format nil "error-~a.lisp" (get-universal-time))
                             archive-dir))))
          (sleep poll-interval))))))

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
              :default-timeout *bridge-default-timeout*))

(defun version-sidecar-path (core-path)
  (concatenate 'string (namestring core-path) ".version"))

(defun write-version-sidecar (core-path)
  "Record the SBCL version and machine type in effect at save time,
next to the core image, so a resume attempt on a different build can
be flagged."
  (with-open-file (s (version-sidecar-path core-path)
                      :direction :output
                      :if-exists :supersede
                      :if-does-not-exist :create)
    (format s "~a~%~a~%" (lisp-implementation-version) (machine-type))))

(defun suspend-bridge (&key (core-path (error "core-path required")))
  "Save an executable image capturing all current state to CORE-PATH,
then terminate this process. Intended to be called as (part of) a
normal request submitted through the usual next-sbcl-input.lisp
mechanism. Running the saved image later (just executing the file)
resumes the polling loop on the same directory via resume-bridge."
  (format t "~&;;; SUSPENDING to ~a~%" core-path)
  (finish-output)
  ;; save-lisp-and-die refuses to run with other threads alive.
  #+sb-thread
  (when *watchdog-thread*
    (ignore-errors (sb-thread:terminate-thread *watchdog-thread*))
    (ignore-errors (sb-thread:join-thread *watchdog-thread* :timeout 5 :default nil))
    (setf *watchdog-thread* nil))
  (write-version-sidecar core-path)
  (sb-ext:gc :full t)
  (sb-ext:save-lisp-and-die core-path
                            :toplevel #'resume-bridge
                            :executable t
                            :save-runtime-options t))
