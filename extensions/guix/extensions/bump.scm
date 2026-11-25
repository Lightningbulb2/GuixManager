;;; guix bump --- move the channel pins in a Guix config file and apply them
;;;
;;; A Guix extension: installed under share/guix/extensions, it is run as
;;; `guix bump'.  See `guix bump --help'.
;;;
;;; The config file holds every channel as a (channel ...) form with a
;;; (commit "...") pin.  `guix bump' rewrites those pins in place, then runs
;;; `guix pull -C CONFIG' so the running Guix always matches the file.  If
;;; the pull fails the file is put back as it was.
;;;
;;; When the config file is in a git repository, each change that was
;;; pulled or applied is committed there (and pushed, if it has a remote).
;;; State (the pins before the last change, logs) is kept in
;;; ~/.local/state/guix-bump.

(define-module (guix extensions bump)
  #:use-module (guix scripts)
  #:use-module (guix describe)
  #:use-module (guix channels)
  #:use-module (guix discovery)
  #:use-module (guix packages)
  #:use-module ((guix utils) #:select (version>?))
  #:use-module (guix profiles)
  #:use-module (gnu packages)
  #:use-module (ice-9 ftw)
  #:use-module ((guix build utils) #:select (mkdir-p))
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:export (guix-bump))

(define %version "2.6")

;; Replaced with a store file name when the package is built.
(define %git "@GIT@")
(define %bash "@BASH@")
(define %screen-off "@SCREEN_OFF@")

(define (git)
  (if (string-prefix? "/" %git) %git "git"))

(define (bash)
  (if (string-prefix? "/" %bash) %bash "sh"))

;;;
;;; Settings: which file, and which lists in it.
;;;
;;; ~/.config/guix-manager/settings holds lines "KEY = VALUE":
;;;
;;;   config    the config file                   (default ~/config.scm)
;;;   packages  the variable holding the list of package names that
;;;             --install and --remove edit       (default %managed-packages,
;;;                                                else %apps)
;;;   channels  the variable holding the channels; only the (channel ...)
;;;             forms in its definition are pins  (default: every such form
;;;                                                in the file)
;;;   git       what to do when the config is in a git repository:
;;;             push (commit each change and push it), commit (commit
;;;             only) or off                      (default push)
;;;
;;; and three that live in the config's git repository itself, not in that
;;; file, shown and changed the same way:
;;;
;;;   git-remote  where changes are pushed (the remote `origin'); empty
;;;               removes it
;;;   git-name, git-email  who the commits are by (the repository's
;;;               user.name and user.email); empty falls back to the
;;;               global git configuration
;;;
;;; `guix bump --settings' shows them, `guix bump --set KEY=VALUE' changes
;;; one, and an empty value goes back to the default.

(define %setting-keys '("config" "packages" "channels" "git"))

(define %git-keys '("git-remote" "git-name" "git-email"))

(define (config-repository)
  ;; The directory of the config file, if it is in a git repository.
  (let ((dir (dirname (config-file))))
    (and (file-exists? dir)
         (quietly (git) "-C" dir "rev-parse" "--is-inside-work-tree")
         dir)))

(define (git-value dir key)
  ;; The value of the git setting KEY in the repository DIR, or "".
  (match (output-lines (git) "-C" dir
                       (if (string=? key "git-remote") "remote" "config")
                       (match key
                         ("git-remote" "get-url")
                         (_ "--get"))
                       (match key
                         ("git-remote" "origin")
                         ("git-name" "user.name")
                         ("git-email" "user.email")))
    ((value . _) value)
    (_ "")))

(define (set-git-value! key value)
  ;; Change the git setting KEY of the config's repository to VALUE.
  (let ((dir (or (config-repository)
                 (die "~a is not in a git repository" (config-file)))))
    (define (git! . args)
      (unless (apply quietly (git) "-C" dir args)
        (die "git ~a failed in ~a" (string-join args " ") dir)))
    (match key
      ("git-remote"
       (let ((has-origin? (member "origin"
                                  (or (output-lines (git) "-C" dir "remote")
                                      '()))))
         (cond ((string-null? value)
                (when has-origin? (git! "remote" "remove" "origin")))
               (has-origin? (git! "remote" "set-url" "origin" value))
               (else (git! "remote" "add" "origin" value)))))
      (_
       (let ((variable (if (string=? key "git-name") "user.name"
                           "user.email")))
         (if (string-null? value)
             ;; Exit status 5: it was not set.
             (apply quietly (git) "-C" dir
                    (list "config" "--unset" variable))
             (git! "config" variable value)))))))

(define (git-mode)
  ;; 'push, 'commit or 'off.
  (match (setting "git")
    ((or #f "push") 'push)
    ("commit" 'commit)
    ("off" 'off)
    (other (die "git = ~a: expected push, commit or off" other))))

(define (settings-file)
  (string-append (or (getenv "XDG_CONFIG_HOME")
                     (string-append (getenv "HOME") "/.config"))
                 "/guix-manager/settings"))

(define (read-settings)
  ;; Return ((KEY . VALUE) ...) from the settings file; '() without one.
  (if (file-exists? (settings-file))
      (filter-map
       (lambda (line)
         (let ((line (string-trim-both line)))
           (and (not (string-null? line))
                (not (string-prefix? "#" line))
                (and=> (string-index line #\=)
                       (lambda (i)
                         (cons (string-trim-both (substring line 0 i))
                               (string-trim-both (substring line (+ i 1)))))))))
       (string-split (call-with-input-file (settings-file) get-string-all)
                     #\newline))
      '()))

(define (setting key)
  ;; The value of KEY, or #f when it is unset or empty.
  (let ((value (assoc-ref (read-settings) key)))
    (and (string? value) (not (string-null? value)) value)))

(define (write-setting! key value)
  (let ((settings (filter (match-lambda
                            ((k . v) (and (not (string=? k key))
                                          (member k %setting-keys)
                                          (not (string-null? v)))))
                          (read-settings))))
    (mkdir-p (dirname (settings-file)))
    (call-with-output-file (settings-file)
      (lambda (port)
        (format port "# Settings of `guix bump' and Guix Manager.  \
See `guix bump --help'.~%")
        (for-each (match-lambda
                    ((k . v) (format port "~a = ~a~%" k v)))
                  (if (string-null? value)
                      settings
                      (append settings (list (cons key value)))))))))

(define (expand-home file)
  (if (string-prefix? "~/" file)
      (string-append (getenv "HOME") (substring file 1))
      file))

(define (config-file)
  ;; The real file, not a symlink to it: it gets replaced by renaming, and
  ;; its directory is where git is run.
  (let ((file (or (getenv "GUIX_BUMP_CONFIG")
                  (and=> (setting "config") expand-home)
                  (string-append (getenv "HOME") "/config.scm"))))
    (if (file-exists? file)
        (canonicalize-path file)
        file)))

(define (state-directory)
  (let ((dir (string-append (or (getenv "XDG_STATE_HOME")
                                (string-append (getenv "HOME") "/.local/state"))
                            "/guix-bump")))
    (mkdir-p dir)
    dir))

(define (previous-pins-file)
  (string-append (state-directory) "/previous-pins.scm"))

;; File that everything shown is also appended to, or #f.
(define %log #f)

;; With --porcelain, what is meant for people goes to standard error and
;; standard output carries only tab-separated lines for a program.
(define %porcelain? #f)

(define (emit fmt . args)
  (let ((text (apply format #f fmt args))
        (port (if %porcelain? (current-error-port) (current-output-port))))
    (display text port)
    (force-output port)
    (when %log
      (let ((port (open-file %log "a")))
        (display text port)
        (close-port port)))))

(define (pulled-guix)
  ;; The Guix that `guix pull' updates; after a pull this is the new one.
  (let ((file (string-append (getenv "HOME") "/.config/guix/current/bin/guix")))
    (if (file-exists? file) file "guix")))

(define (die fmt . args)
  (apply format (current-error-port) (string-append "guix bump: " fmt "~%") args)
  (exit 1))

(define (say fmt . args)
  (apply emit (string-append "~%==> " fmt "~%") args))


;;;
;;; Finding and editing the (channel ...) forms.
;;;

(define (skip-string text i)
  ;; I is at an opening double quote; return the index after the closing one.
  (let loop ((i (+ i 1)))
    (cond ((>= i (string-length text)) i)
          ((char=? (string-ref text i) #\\) (loop (+ i 2)))
          ((char=? (string-ref text i) #\") (+ i 1))
          (else (loop (+ i 1))))))

(define (skip-line text i)
  (or (string-index text #\newline i) (string-length text)))

(define (form-end text start)
  ;; START is at an opening parenthesis; return the index after the matching
  ;; closing one, skipping strings, comments and character literals.
  (let loop ((i start) (depth 0))
    (if (>= i (string-length text))
        i
        (let ((c (string-ref text i)))
          (cond ((char=? c #\;) (loop (skip-line text i) depth))
                ((char=? c #\") (loop (skip-string text i) depth))
                ((and (char=? c #\#) (< (+ i 1) (string-length text))
                      (char=? (string-ref text (+ i 1)) #\\))
                 (loop (+ i 3) depth))
                ((char=? c #\() (loop (+ i 1) (+ depth 1)))
                ((char=? c #\))
                 (if (= depth 1) (+ i 1) (loop (+ i 1) (- depth 1))))
                (else (loop (+ i 1) depth)))))))

(define (channel-form? text i)
  (let ((end (+ i (string-length "(channel"))))
    (and (< end (string-length text))
         (string=? (substring text i end) "(channel")
         (char-whitespace? (string-ref text end)))))

(define (definition-form text variables)
  ;; Return (START . END) of the first (define VARIABLE ...) form in TEXT
  ;; for one of VARIABLES, or #f.  Comments and strings are skipped.
  ;; Both (define VARIABLE ...) and (define (VARIABLE) ...).
  (define (definition? i)
    (any (lambda (variable)
           (any (lambda (prefix)
                  (let ((end (+ i (string-length prefix))))
                    (and (< end (string-length text))
                         (string=? (substring text i end) prefix)
                         (let ((c (string-ref text end)))
                           (or (char-whitespace? c) (char=? c #\)))))))
                (list (string-append "(define " variable)
                      (string-append "(define (" variable))))
         variables))
  (let loop ((i 0))
    (and (< i (string-length text))
         (let ((c (string-ref text i)))
           (cond ((char=? c #\;) (loop (skip-line text i)))
                 ((char=? c #\") (loop (skip-string text i)))
                 ((and (char=? c #\() (definition? i))
                  (cons i (form-end text i)))
                 (else (loop (+ i 1))))))))

(define (channel-forms text)
  ;; Return ((START . END) ...) for each (channel ...) form in TEXT that is
  ;; code, not a comment or part of a string: all of them, or with the
  ;; `channels' setting only those in that variable's definition.
  (define-values (first last)
    (match (setting "channels")
      (#f (values 0 (string-length text)))
      (variable
       (match (definition-form text (list variable))
         ((start . end) (values start end))
         (#f (die "the config has no (define ~a ...): see guix bump --settings"
                  variable))))))
  (let loop ((i first) (result '()))
    (if (>= i last)
        (reverse result)
        (let ((c (string-ref text i)))
          (cond ((char=? c #\;) (loop (skip-line text i) result))
                ((char=? c #\") (loop (skip-string text i) result))
                ((and (char=? c #\() (channel-form? text i))
                 (let ((end (form-end text i)))
                   (loop end (cons (cons i end) result))))
                (else (loop (+ i 1) result)))))))

;; A pinned channel as written in the file.
(define (field fields key)
  (match (assq key fields)
    ((_ ('quote value)) value)
    ((_ value) value)
    (_ #f)))

(define (read-channels text)
  ;; Return an alist NAME -> ((start . end) url branch commit) in file order.
  (filter-map
   (match-lambda
     ((start . end)
      (match (false-if-exception
              (call-with-input-string (substring text start end) read))
        (('channel fields ...)
         (let ((name (field fields 'name))
               (url  (field fields 'url)))
           (and (symbol? name) (string? url)
                (list name
                      (cons start end)
                      url
                      (or (field fields 'branch) "master")
                      (field fields 'commit)))))
        (_ #f))))
   (channel-forms text)))

(define %commit-rx
  (make-regexp "\\(commit[ \t\n]+\"[^\"]*\"\\)"))
(define %branch-rx
  (make-regexp "\\(branch[ \t\n]+\"[^\"]*\"\\)"))
(define %url-rx
  (make-regexp "\\(url[ \t\n]+\"[^\"]*\"\\)"))

(define (column text index)
  (let ((newline (string-rindex text #\newline 0 index)))
    (- index (if newline (+ newline 1) 0))))

(define (set-pin text name commit)
  ;; Return TEXT with channel NAME pinned to COMMIT.
  (match (assq name (read-channels text))
    ((_ (start . end) . _)
     (let* ((form (substring text start end))
            (new  (format #f "(commit ~s)" commit))
            (form (cond ((regexp-exec %commit-rx form)
                         => (lambda (m)
                              (string-append (match:prefix m) new
                                             (match:suffix m))))
                        ((or (regexp-exec %branch-rx form)
                             (regexp-exec %url-rx form))
                         => (lambda (m)
                              ;; No pin yet: add one under the branch or URL.
                              (string-append
                               (substring form 0 (match:end m))
                               "\n"
                               (make-string (column text
                                                    (+ start (match:start m)))
                                            #\space)
                               new
                               (match:suffix m))))
                        (else
                         (die "channel '~a' has no (url ...) field" name)))))
       (string-append (substring text 0 start) form (substring text end))))))

(define (pins text)
  ;; Return ((NAME . COMMIT) ...) as pinned in TEXT.
  (map (match-lambda
         ((name _ _ _ commit) (cons name commit)))
       (read-channels text)))

(define (write-config file text)
  (let ((tmp  (string-append file ".bump-tmp"))
        (mode (stat:perms (stat file))))
    (call-with-output-file tmp
      (lambda (port) (put-string port text)))
    (chmod tmp mode)
    (rename-file tmp file)))


;;;
;;; Remote state.
;;;

(define (latest-commit url branch)
  (let* ((pipe (open-pipe* OPEN_READ (git) "ls-remote" url
                           (string-append "refs/heads/" branch)))
         (line (read-line pipe))
         (status (close-pipe pipe)))
    (and (zero? status)
         (string? line)
         (match (string-tokenize line)
           ((commit . _) commit)
           (_ #f)))))

(define (running-commit name)
  ;; The commit of channel NAME in the Guix that is running this command.
  (any (lambda (channel)
         (and (eq? (channel-name channel) name)
              (channel-commit channel)))
       (current-channels)))

(define (short commit)
  (if commit
      (substring commit 0 (min 10 (string-length commit)))
      "-"))


;;;
;;; Running things.
;;;

(define (run-status . command)
  ;; Run COMMAND, showing it; with a log, its output goes there as well.
  ;; Return its exit status, or #f if a signal ended it.
  (emit "~%$ ~a~%" (string-join command " "))
  (status:exit-val
   (if %log
       (begin
         (setenv "GUIX_BUMP_LOG" %log)
         (apply system* (bash) "-c"
                "set -o pipefail; \"$@\" 2>&1 | tee -a \"$GUIX_BUMP_LOG\""
                "sh" command))
       (apply system* command))))

(define (run . command)
  ;; Run COMMAND as `run-status' does; return true on success.
  (eqv? 0 (apply run-status command)))

(define (quietly . command)
  ;; Run COMMAND with its output discarded; return true on success.
  (call-with-output-file "/dev/null"
    (lambda (null)
      (zero? (with-output-to-port null
               (lambda ()
                 (with-error-to-port null
                   (lambda ()
                     (apply system* command)))))))))

(define (output-lines . command)
  ;; Run COMMAND and return what it prints, standard error included, as a
  ;; list of lines, or #f if it failed.
  (let* ((pipe (apply open-pipe* OPEN_READ (bash) "-c" "\"$@\" 2>&1" "sh"
                      command))
         (lines (let loop ((lines '()))
                  (let ((line (read-line pipe)))
                    (if (eof-object? line)
                        (reverse lines)
                        (loop (cons line lines)))))))
    (and (zero? (close-pipe pipe)) lines)))

(define (start-sudo-keepalive)
  ;; Ask for the password now, then keep sudo's timestamp fresh so the
  ;; reconfigure, maybe an hour away, doesn't stop at a password prompt.
  (unless (zero? (system* "sudo" "-v"))
    (die "sudo is needed for the system reconfigure"))
  (let ((pid (primitive-fork)))
    (if (zero? pid)
        (begin
          (let loop ()
            (sleep 50)
            (when (= (getppid) 1) (primitive-exit 0)) ;parent is gone
            (when (zero? (system* "sudo" "-n" "-v"))
              (loop)))
          (primitive-exit 0))
        pid)))

(define (screen-off-program)
  ;; The helper that keeps the screens off (screen-off/ in the source): the
  ;; packaged one, else one built with `make' in this checkout, else #f.
  (if (string-prefix? "/" %screen-off)
      %screen-off
      ;; A checkout's extensions directory is on GUIX_EXTENSIONS_PATH (or
      ;; on the load path, with -L); the helper is beside it.
      (any (lambda (dir)
             (let ((built (string-append dir "/../screen-off/screen-off")))
               (and (file-exists?
                     (string-append dir "/guix/extensions/bump.scm"))
                    (file-exists? built)
                    (canonicalize-path built))))
           (append (string-split (or (getenv "GUIX_EXTENSIONS_PATH") "")
                                 #\:)
                   %load-path))))

(define (start-screen-off)
  ;; Turn the screens off a second after the last input, on at the next
  ;; input, off again after a minute without input, for as long as this
  ;; process runs; see screen-off/screen-off.c.  Only in a Wayland session.
  (let ((program (screen-off-program)))
    (cond ((not (getenv "WAYLAND_DISPLAY"))
           (emit "Not in a Wayland session: the screens stay on.~%"))
          ((not program)
           (emit "The screen-off helper is missing (build it with `make -C screen-off'): the screens stay on.~%"))
          (else
           (let ((parent (getpid))
                 (pid (primitive-fork)))
             (when (zero? pid)
               (catch #t
                 (lambda ()
                   ;; Not the terminal or a pipe: with `guix nightly | tee',
                   ;; tee would wait for the helper, which outlives us.
                   (let ((null (open-fdes "/dev/null" O_RDWR)))
                     (dup2 null 0)
                     (dup2 null 1)
                     (dup2 null 2))
                   (execl program program (number->string parent)))
                 (lambda _ #t))
               (primitive-exit 1))
             (emit "The screens turn off now; move the mouse to see how it is going.~%"))))))

(define (power-off)
  (say "Powering off in 60 seconds.  Ctrl-C to cancel.")
  (sleep 60)
  (or (run "loginctl" "poweroff")
      (run "sudo" "shutdown")))


;;;
;;; The config file's git repository.
;;;

(define (commit-config file message)
  ;; If FILE is in a git repository and differs from what is committed,
  ;; commit it with MESSAGE and, with the `git' setting at push (the
  ;; default), push.
  (let ((dir  (dirname file))
        (name (basename file)))
    (when (and (not (eq? (git-mode) 'off))
               (quietly (git) "-C" dir "rev-parse" "--is-inside-work-tree")
               (quietly (git) "-C" dir "add" "--" name)
               (not (quietly (git) "-C" dir "diff" "--cached" "--quiet"
                             "--" name)))
      (if (quietly (git) "-C" dir "commit" "-m" message "--" name)
          (begin
            (emit "~%Committed ~a: ~a~%" name
                  (car (string-split message #\newline)))
            ;; Never stop at a password prompt.
            (setenv "GIT_TERMINAL_PROMPT" "0")
            (when (and (eq? (git-mode) 'push)
                       (pair? (or (output-lines (git) "-C" dir "remote") '()))
                       (not (quietly (git) "-C" dir "push")))
              (emit "Could not push ~a; run `git -C ~a push' later.~%"
                    name dir)))
          (emit "~%Could not commit ~a in ~a.~%" name dir)))))


;;;
;;; What would be compiled here.
;;;

(define %heavy-rx
  ;; Packages that take a long time to compile, so worth a warning when no
  ;; substitute (ready-made build) is available for them.
  (make-regexp
   (or (getenv "GUIX_BUMP_HEAVY")
       (string-append
        "^(firefox|icecat|thunderbird|chromium|ungoogled-chromium"
        "|linux-[0-9]|linux-libre-[0-9]|libreoffice|blender|godot|inkscape"
        "|gimp|krita|qtwebengine|qtbase|qtdeclarative|webkitgtk|gtk[+-]"
        "|rust-[0-9]|llvm|clang|gcc-[0-9]|ghc|glibc|mesa|wine|openjdk"
        "|python-[0-9]|node-[0-9]|texlive|kwin|plasma|obs-[0-9]|handbrake)"))))

(define %drv-rx
  (make-regexp "^ +/gnu/store/[a-z0-9]+-(.+)\\.drv$"))

(define (to-build guix kind file build-options)
  ;; Return the names of what `guix KIND reconfigure FILE' would build
  ;; rather than download, or #f if that could not be determined.
  (and=> (apply output-lines guix kind "build" file "--dry-run" build-options)
         (lambda (lines)
           (filter-map (lambda (line)
                         (and=> (regexp-exec %drv-rx line)
                                (lambda (m) (match:substring m 1))))
                       lines))))

(define (confirm-builds guix kinds file build-options yes?)
  ;; Warn when applying would compile heavy packages for lack of
  ;; substitutes, and ask whether to go on.  Return #f to stop.
  (say "Checking what would have to be compiled here")
  (let* ((names (delete-duplicates
                 (append-map (lambda (kind)
                               (or (to-build guix kind file build-options)
                                   '()))
                             kinds)))
         (heavy (filter (lambda (name) (regexp-exec %heavy-rx name)) names)))
    (emit "~a items to build locally, ~a of them known to be slow.~%"
          (length names) (length heavy))
    (cond ((null? heavy) #t)
          (else
           (emit "~%WARNING: no substitute yet for:~%~{  ~a~%~}" heavy)
           (emit "These would be compiled from source, which can take hours.
The build farms usually catch up within a day or two.~%")
           (cond (yes?
                  (emit "Continuing anyway (--yes).~%")
                  #t)
                 (else
                  (ask "Continue anyway?")))))))

(define (ask question)
  ;; Ask a yes/no QUESTION; anything but yes is no.
  (display (string-append question " [y/N] "))
  (force-output)
  (let ((answer (read-line)))
    (and (string? answer)
         (member (string-downcase (string-trim-both answer)) '("y" "yes"))
         #t)))


;;;
;;; Building before applying, with one progress line for all builds.
;;;
;;; `guix system reconfigure' draws a progress bar only while exactly one
;;; build runs, and a spinner otherwise, though it tracks every build's
;;; progress.  So before a reconfigure, `guix bump' builds the same thing
;;; itself with this script, run by the pulled Guix (the modules of the Guix
;;; running `guix bump' are older after a pull, so it can't be done here),
;;; and shows:
;;;
;;;   [ 41%] 3/14 built · craft-suite 44% · cosmic-suite build 12m
;;;
;;; The percentage weighs each build by how long it took last time
;;; (build-times.scm in the state directory, first filled from the daemon's
;;; build logs), so a minute-long build doesn't count as much as an hour-long
;;; one.  The reconfigure then finds everything built.
;;;
;;; Arguments: KIND (system or home), the config file, the file of build
;;; times, then build options.  Exit status: 0 built, 1 a build (or the
;;; config) failed, 3 the script itself failed, in which case the
;;; reconfigure does the building as usual.

(define %build-script
  '(begin
     (use-modules (guix store) (guix monads) (guix derivations) (guix ui)
                  (guix status) (guix scripts) (guix scripts build)
                  ((guix build syscalls) #:select (terminal-columns))
                  (gnu system) (gnu home)
                  (srfi srfi-1) (srfi srfi-11) (srfi srfi-34)
                  (ice-9 match) (ice-9 format) (ice-9 popen) (ice-9 rdelim)
                  (ice-9 regex))

     (define (now) (/ (get-internal-real-time)
                      (exact->inexact internal-time-units-per-second)))

     (define (base-name file)
       ;; "craft-suite" for /gnu/store/HASH-craft-suite-0.drv (or a log
       ;; file HASH-craft-suite-0.drv.gz).
       (let* ((file (basename file))
              (file (substring file (+ 1 (or (string-index file #\-) -1))))
              (file (fold (lambda (suffix file)
                            (if (string-suffix? suffix file)
                                (string-drop-right file (string-length suffix))
                                file))
                          file '(".gz" ".bz2" ".zst" ".drv"))))
         ;; The version starts at the first hyphen followed by a digit
         ;; (`package-name->name+version' only splits NAME@VERSION).
         (match (string-match "-[0-9]" file)
           (#f file)
           (m (substring file 0 (match:start m))))))

     (define (clock seconds)
       (let* ((s (inexact->exact (round seconds)))
              (h (quotient s 3600))
              (m (quotient (remainder s 3600) 60)))
         (if (> h 0)
             (format #f "~d:~2,'0d:~2,'0d" h m (remainder s 60))
             (format #f "~d:~2,'0d" m (remainder s 60)))))

     (define (logged-times)
       ;; NAME -> seconds of its latest build, from the daemon's logs: a log
       ;; is created when its build starts and last written when it ends.
       ;; A graft has the name of what it grafts and a log of a few hundred
       ;; bytes, so a log over 2 KB beats any smaller one.
       (let ((table (make-hash-table))
             (best (make-hash-table))           ;NAME -> (big? . written)
             ;; stat, not find's %B: that one printed -1 here.
             (pipe (open-pipe* OPEN_READ "sh" "-c"
                               "find /var/log/guix/drvs -type f -print0 \
| xargs -0 -r stat -c '%W %Y %s %n' 2>/dev/null")))
         (define (better? a b)
           (or (and (car a) (not (car b)))
               (and (eq? (car a) (car b)) (> (cdr a) (cdr b)))))
         (let loop ()
           (match (read-line pipe)
             ((? eof-object?) #t)
             (line
              (match (string-split line #\space)
                ((born written size file)
                 (let* ((born (string->number born))
                        (written (string->number written))
                        (size (string->number size))
                        (name (base-name file))
                        (key (and size written
                                  (cons (> size 2000) written))))
                   (when (and born key (> born 0)
                              (<= 0 (- written born) 43200)
                              (better? key (hash-ref best name '(#f . 0))))
                     (hash-set! best name key)
                     (hash-set! table name
                                (inexact->exact
                                 (round (- written born)))))))
                (_ #t))
              (loop))))
         (close-pipe pipe)
         table))

     (define (read-times file)
       (if (file-exists? file)
           (let ((table (make-hash-table)))
             (for-each (match-lambda
                         ((name . seconds) (hash-set! table name seconds))
                         (_ #t))
                       (or (false-if-exception
                            (call-with-input-file file read))
                           '()))
             table)
           (logged-times)))

     (define (write-times table file)
       (let ((new (string-append file ".new")))
         (call-with-output-file new
           (lambda (port)
             (write (sort (hash-map->list cons table)
                          (lambda (a b) (string<? (car a) (car b))))
                    port)
             (newline port)))
         (rename-file new file)))

     (define (trivial? drv)
       ;; Grafts, profiles and profile hooks: seconds each, and many.
       ;; Downloads and checkouts (fixed-output), whose names start like
       ;; the package's ("cosmic-term-92b3fb5-checkout").  And an app taken
       ;; from a suite's output (hyperguix's `suite-member'), which has the
       ;; name, and so the old build times, of the app.
       (or (memq (assq-ref (derivation-properties drv) 'type)
                 '(graft profile profile-hook))
           (fixed-output-derivation? drv)
           (and (not (string-suffix? "-suite-0.drv"
                                     (derivation-file-name drv)))
                (any (lambda (input)
                       (string-suffix? "-suite-0.drv"
                                       (derivation-input-path input)))
                     (derivation-inputs drv)))))

     (define (main kind config times-file args)
       ;; --dry-run: only show what would be built and how long it took.
       (define dry-run? (member "--dry-run" args))
       (define build-args (delete "--dry-run" args))
       (define opts
         ;; The defaults of `guix build' (not exported there).
         (parse-command-line build-args %standard-build-options
                             (list '((graft? . #t)
                                     (substitutes? . #t)
                                     (offload? . #t)
                                     (print-build-trace? . #t)
                                     (print-extended-build-trace? . #t)
                                     (multiplexed-build-output? . #t)
                                     (debug . 0)))))
       (define object
         (begin
           ;; The config may choose what it returns by the command line.
           (set-program-arguments (list "guix" kind "reconfigure" config))
           (load* config (if (string=? kind "home")
                             '((gnu home))
                             '((gnu system) (gnu services)
                               (gnu system shadow))))))
       (define port (current-error-port))
       (define tty? (isatty? port))
       (define times (read-times times-file))

       (with-store store
         (set-build-options-from-command-line store opts)
         (let ((weights (make-hash-table))      ;.drv file -> seconds
               (real-files (make-hash-table))   ;.drv files counted as builds
               (trivial-files (make-hash-table))
               (total 0)                        ;seconds of weight to do
               (real-count 0)
               (started (make-hash-table))      ;.drv file -> time
               (done 0)                         ;seconds of weight done
               (built 0)                        ;real builds done
               (begun (now))
               (last-drawn 0)
               (last-logged 0)
               (last-percent -1)
               (drawn? #f))

           (define (lower graft?)
             (parameterize ((%graft? graft?))
               (run-with-store store
                 (if (operating-system? object)
                     (operating-system-derivation object)
                     (home-environment-derivation object)))))

           (define (plan! inputs)
             ;; Add what realizing INPUTS (derivation inputs) takes to the
             ;; totals.  Return the derivations to build and the number of
             ;; items to download.
             (let-values (((builds downloads)
                           (derivation-build-plan store inputs)))
               (for-each
                (lambda (d)
                  (let ((file (derivation-file-name d)))
                    (unless (hash-ref weights file #f)
                      (let ((w (if (trivial? d)
                                   1
                                   (max 1 (hash-ref times (base-name file)
                                                    60)))))
                        (hash-set! weights file w)
                        (set! total (+ total w))
                        (when (trivial? d)
                          (hash-set! trivial-files file #t))
                        ;; What is counted and named as a build: what took
                        ;; over 10 s last time (or is new), not the many
                        ;; scripts and files a system is made of.
                        (when (> w 10)
                          (hash-set! real-files file #t)
                          (set! real-count (+ real-count 1)))))))
                builds)
               (values builds (length downloads))))

           (define (handler continue store* things mode)
             ;; Builds asked for while the system is computed (grafts need
             ;; the outputs they graft): count them too, then go on.
             (plan! (filter-map
                     (lambda (thing)
                       (let ((file (if (pair? thing) (car thing) thing)))
                         (and (derivation-path? file)
                              (and=> (false-if-exception
                                      (read-derivation-from-file file))
                                     derivation-input))))
                     things))
             (continue #t))

           (define (weight file) (hash-ref weights file 0))
           (define (real? file) (hash-ref real-files file #f))
           (define (since file) (- (now) (hash-ref started file (now))))

           (define (running status)
             ;; The real builds, oldest first.
             (sort (filter (lambda (b) (real? (build-derivation b)))
                           (build-status-building status))
                   (lambda (a b)
                     (< (hash-ref started (build-derivation a) 0)
                        (hash-ref started (build-derivation b) 0)))))

           (define (percent status)
             (let ((running
                    (fold + 0
                          (map (lambda (b)
                                 (let* ((file (build-derivation b))
                                        (w (weight file))
                                        (c (build-completion b)))
                                   (* w (if c
                                            (/ (min c 100) 100.)
                                            (min 0.95
                                                 (/ (since file) (max w 1)))))))
                               (build-status-building status)))))
               (min 99 (inexact->exact
                        (floor (* 100 (/ (+ done running) (max total 1))))))))

           (define (line status)
             (define small
               (- (length (build-status-building status))
                  (length (running status))))
             (string-join
              (append
               (list (format #f "[~3d%] ~a/~a built" (percent status)
                             built real-count))
               (map (lambda (b)
                      (let ((file (build-derivation b)))
                        (string-append
                         (base-name file) " "
                         (cond ((build-completion b)
                                => (lambda (c)
                                     (format #f "~d%" (inexact->exact
                                                       (round c)))))
                               ((build-phase b)
                                => (lambda (phase)
                                     (format #f "~a ~a" phase
                                             (clock (since file)))))
                               (else (clock (since file)))))))
                    (running status))
               (if (zero? small) '() (list (format #f "~a small" small)))
               (match (length (build-status-downloading status))
                 (0 '())
                 (n (list (format #f "~a downloading" n)))))
              " · "))

           (define (erase)
             (when (and tty? drawn?)
               (display (string #\return (integer->char 27) #\[ #\K) port)
               (set! drawn? #f)))

           (define (draw status important?)
             ;; On a terminal, redraw the line (at most 4 times a second
             ;; unless IMPORTANT?); in a log, add a line when a real build
             ;; starts or ends, or once a minute.
             (let ((text (line status))
                   (p (percent status)))
               (cond (tty?
                      (when (or important? (> (- (now) last-drawn) 0.25))
                        (let ((width (max 20 (- (terminal-columns port) 1))))
                          (erase)
                          (display (if (> (string-length text) width)
                                       (string-take text width)
                                       text)
                                   port)
                          (force-output port)
                          (set! drawn? #t)
                          (set! last-drawn (now)))))
                     ((or important?
                          (and (not (= p last-percent))
                               (> (- (now) last-logged) 60)))
                      (display text port)
                      (newline port)
                      (force-output port)
                      (set! last-logged (now))
                      (set! last-percent p)))))

           (define (say-line text)
             (erase)
             (display text port)
             (newline port)
             (force-output port))

           (define (on-event event old status)
             (match event
               (('build-started file . _)
                (hash-set! started file (now))
                (draw status (real? file)))
               (('build-succeeded file . _)
                (let ((seconds (since file)))
                  (set! done (+ done (weight file)))
                  (unless (hash-ref trivial-files file #f)
                    (hash-set! times (base-name file)
                               (inexact->exact (round seconds))))
                  (when (real? file)
                    (set! built (+ built 1))
                    (say-line (format #f "built ~a in ~a" (base-name file)
                                      (clock seconds))))
                  (draw status (real? file))))
               (((or 'build-failed 'download-failed) . _)
                (erase)
                (print-build-event/quiet event old status port)
                (draw status #t))
               (('build-log #f text)
                ;; Messages of the daemon itself, not of a build; the
                ;; substitute queries redraw a line of their own.
                (let ((text (string-trim-both
                             (last (string-split text #\return)))))
                  (unless (or (string-null? text)
                              (string-prefix? "substitute:" text))
                    (say-line text)))
                (draw status #f))
               (_ (draw status #f))))

           (with-status-report on-event
             (say-line "Computing what to build...")
             ;; First everything that is compiled, without grafts: then it
             ;; is all known up front, whereas with grafts most of it is
             ;; built while the system is being computed.
             (let*-values (((ungrafted) (lower #f))
                           ((builds downloads)
                            (plan! (list (derivation-input ungrafted)))))
               (say-line (format #f "~a to build here (~a of earlier build \
time), ~a to download." real-count (clock total) downloads))
               (if dry-run?
                   (begin
                     (for-each (lambda (d)
                                 (say-line (format #f "  ~8a ~a"
                                         (clock (weight
                                                 (derivation-file-name d)))
                                         (base-name
                                          (derivation-file-name d)))))
                               (sort (delete-duplicates
                                      (filter (lambda (d)
                                                (real? (derivation-file-name d)))
                                              builds)
                                      (lambda (a b)
                                        (string=? (derivation-file-name a)
                                                  (derivation-file-name b))))
                                     (lambda (a b)
                                       (> (weight (derivation-file-name a))
                                          (weight (derivation-file-name b))))))
                     (say-line "(Then the grafts, not counted here.)")
                     0)
                   (guard (c ((store-protocol-error? c)
                              (erase)
                              (write-times times times-file)
                              (format port "~a~%"
                                      (store-protocol-error-message c))
                              1))
                     (with-build-handler handler
                       (let ((compiled (remove trivial? builds)))
                         (unless (null? compiled)
                           (build-derivations store compiled)))
                       ;; Then the system itself: what only grafting needs
                       ;; (replacements such as the NVIDIA driver), and the
                       ;; grafts.
                       (let ((drv (lower (assoc-ref opts 'graft?))))
                         (plan! (list (derivation-input drv)))
                         (build-derivations store (list drv))))
                     (erase)
                     (write-times times times-file)
                     (format port "Built everything in ~a.~%"
                             (clock (- (now) begun)))
                     0)))))))

     (let ((status
            (catch #t
              (lambda ()
                (match (drop-while (lambda (arg)
                                     (not (member arg '("system" "home"))))
                                   (cdr (command-line)))
                  ((kind config times . build-args)
                   (main kind config times build-args))))
              (lambda (key . args)
                (if (eq? key 'quit)
                    (apply throw key args)
                    (begin
                      (format (current-error-port)
                              "~%guix bump: the progress display failed (~a ~s); \
the reconfigure builds instead.~%"
                              key args)
                      3))))))
       (exit status))))

(define (build-times-file)
  (string-append (state-directory) "/build-times.scm"))

(define (prebuild guix kind file build-options)
  ;; Build what `guix KIND reconfigure FILE' needs, with one progress line
  ;; for every build at once (see above).  Return #f if a build failed; if
  ;; the script itself failed, return #t and let the reconfigure build.
  (say "Building the ~a" (if (string=? kind "system")
                             "system"
                             "home environment"))
  (let ((script (string-append (state-directory) "/build.scm")))
    (call-with-output-file script
      (lambda (port) (write %build-script port) (newline port)))
    (let ((status (apply run-status guix "repl" "--" script kind file
                         (build-times-file) build-options)))
      (false-if-exception (delete-file script))
      (case status
        ((0 3) #t)
        (else #f)))))


;;;
;;; Installed and available packages.
;;;

(define (home-profile)
  (string-append (getenv "HOME") "/.guix-home/profile"))

(define %system-profile "/run/current-system/profile")

(define (installed-in profile)
  ;; Return ((NAME VERSION ITEM) ...) for the packages of PROFILE.
  (or (false-if-exception
       (map (lambda (entry)
              (list (manifest-entry-name entry)
                    (manifest-entry-version entry)
                    (manifest-entry-item entry)))
            (manifest-entries (profile-manifest profile))))
      '()))

(define (available name)
  ;; Return (VERSION . CHANNEL) for the package called NAME in the Guix
  ;; running this command, or #f.  `package-channels' lists `guix' for every
  ;; package, so any other channel it names is the one the package is from.
  (match (false-if-exception (find-best-packages-by-name name #f))
    ((p . _)
     (let ((channels (or (false-if-exception
                          (map channel-name (package-channels p)))
                         '())))
       (cons (package-version p)
             (or (find (lambda (channel) (not (eq? channel 'guix))) channels)
                 'guix))))
    (_ #f)))

(define (processes-using item)
  ;; Return the names of the running programs started from the store
  ;; directory ITEM (those of other users can't be seen).
  (let ((prefix (string-append item "/")))
    (delete-duplicates
     (filter-map
      (lambda (pid)
        (and (string-every char-numeric? pid)
             (let* ((dir (string-append "/proc/" pid))
                    (exe (false-if-exception
                          (readlink (string-append dir "/exe"))))
                    (cmd (false-if-exception
                          (call-with-input-file
                              (string-append dir "/cmdline")
                            get-string-all))))
               (and exe
                    (or (string-prefix? prefix exe)
                        (and (string? cmd) (string-contains cmd prefix)))
                    (basename exe)))))
      (or (false-if-exception (scandir "/proc")) '())))))

(define (report-changes before after)
  ;; BEFORE and AFTER are `installed-in' lists of the same profile: say what
  ;; changed version, and what is still running from a replaced package.
  (let* ((changed (filter-map
                   (match-lambda
                     ((name version item)
                      (match (assoc name before)
                        ((_ old-version old-item)
                         (and (not (equal? item old-item))
                              (list name old-version version old-item)))
                        (_ (list name #f version #f)))))
                   after))
         (versions (filter (match-lambda
                             ((_ old new _) (not (equal? old new))))
                           changed))
         (running  (filter-map
                    (match-lambda
                      ((name _ _ old-item)
                       (and (string? old-item)
                            (pair? (processes-using old-item))
                            name)))
                    changed)))
    (unless (null? versions)
      (emit "~%Updated:~%")
      (for-each (match-lambda
                  ((name old new _)
                   (emit "  ~24a ~a~%" name
                         (if old
                             (format #f "~a -> ~a" old new)
                             (format #f "~a (new)" new)))))
                versions))
    (unless (null? running)
      (emit "~%Open right now in the old version (close and reopen to get the new one):~%  ~a~%"
            (string-join running ", ")))))

(define (reboot-needed?)
  ;; Does the system just applied have another kernel or other kernel
  ;; modules (drivers) than the one that booted?
  (let ((booted  (false-if-exception
                  (canonicalize-path "/run/booted-system/kernel")))
        (current (false-if-exception
                  (canonicalize-path "/run/current-system/kernel"))))
    (and booted current (not (string=? booted current)))))


;;;
;;; Which installed packages have a newer version.
;;;

;; Run by a Guix (`guix repl'): write ((NAME VERSION CHANNEL) ...), the packages
;; of the home and of the system of the config file given first, to the file
;; given second.  It evaluates the config the way `guix home' and `guix
;; system' do, so each package is the one the config really names.
(define %versions-script
  "(use-modules (guix ui) (guix packages) (guix describe) (guix channels)
             (gnu home) (gnu system) (ice-9 match) (srfi srfi-1))
(define (entry p)
  ;; `package-channels' names `guix' for every package: any other channel
  ;; it names is the one the package is from.
  (let ((channels (or (false-if-exception
                       (map channel-name (package-channels p)))
                      '())))
    (list (package-name p) (package-version p)
          (or (find (lambda (channel) (not (eq? channel 'guix))) channels)
              'guix))))
(match (reverse (command-line))
  ((out config . _)
   (let ((versions
          (lambda (kind packages)
            (set-program-arguments (list \"guix\" kind \"build\" config))
            (or (false-if-exception
                 (filter-map
                  (lambda (item)
                    (match item
                      ((? package? p) (entry p))
                      (((? package? p) . _) (entry p))
                      (_ #f)))
                  (packages (load* config '((guix profiles) (gnu))))))
                '()))))
     (call-with-output-file out
       (lambda (port)
         (write (append (versions \"home\" home-environment-packages)
                        (versions \"system\" operating-system-packages))
                port))))))
")

(define (config-versions guix text moved build-options)
  ;; Return ((NAME VERSION CHANNEL) ...) for the packages of the config TEXT, as
  ;; the pulled Guix has them or, when MOVED is not empty, as the Guix of
  ;; those pins, ((CHANNEL . COMMIT) ...), has them.  #f on failure.
  (let* ((dir     (state-directory))
         (config  (string-append dir "/check-config.scm"))
         (script  (string-append dir "/check-versions.scm"))
         (output  (string-append dir "/check-result.scm"))
         (pinned  (fold (lambda (move text)
                          (set-pin text (car move) (cdr move)))
                        text moved))
         (repl    (list "repl" "--" script config output)))
    (call-with-output-file config (lambda (port) (put-string port pinned)))
    (call-with-output-file script
      (lambda (port) (put-string port %versions-script)))
    (false-if-exception (delete-file output))
    (let ((ok? (zero? (if (null? moved)
                          (apply system* guix repl)
                          (apply system* guix "time-machine" "-C" config
                                 "--unsafe-channel-evaluation"
                                 (append build-options (list "--") repl))))))
      (for-each (lambda (file) (false-if-exception (delete-file file)))
                (list config script))
      (and ok? (file-exists? output)
           (let ((result (call-with-input-file output read)))
             (delete-file output)
             result)))))

(define (check guix text channels build-options)
  ;; Show which installed packages would change version if CHANNELS moved
  ;; to their latest commits, and which already can.  Changes nothing.
  (define installed                     ;((NAME VERSION WHERE) ...)
    (delete-duplicates
     (append (map (match-lambda ((name version _) (list name version "home")))
                  (installed-in (home-profile)))
             (map (match-lambda ((name version _) (list name version "system")))
                  (installed-in %system-profile)))
     (lambda (a b) (string=? (car a) (car b)))))

  (emit "Looking for new commits~%")
  (define moved                         ;((CHANNEL . COMMIT) ...)
    (filter-map
     (match-lambda
       ((name _ url branch commit)
        (let ((latest (latest-commit url branch)))
          (cond ((not latest)
                 (emit "  ~16a could not reach ~a~%" name url)
                 #f)
                ((equal? latest commit)
                 (emit "  ~16a up to date~%" name)
                 #f)
                (else
                 (emit "  ~16a ~a -> ~a~%" name (short commit) (short latest))
                 (cons name latest))))))
     channels))

  ;; What the config installs with the Guix already pulled.
  (define pulled
    (or (config-versions guix text '() build-options) '()))

  (define newest
    (cond ((null? moved) '())
          (else
           (emit "~%Reading the package versions of those commits.  This prepares that Guix
as a pull would, which takes minutes the first time.~%")
           (or (config-versions guix text moved build-options)
               (begin
                 (emit "~%guix bump: could not prepare the newer Guix; only what is already
pulled is shown.~%")
                 '())))))

  (define rows
    ;; (NAME INSTALLED NEW CHANNEL WHERE PULLED?)
    (filter-map
     (match-lambda
       ((name version where)
        (let ((pulled-version (match (assoc name pulled)
                                ((_ version . _) version)
                                (_ #f)))
              (new            (match (assoc name newest)
                                ((_ version . _) version)
                                (_ #f)))
              ;; The channel of the package the config really names, which
              ;; need not be the newest package of that name.
              (channel        (match (or (assoc name pulled)
                                         (assoc name newest))
                                ((_ _ channel) channel)
                                (_ "?"))))
          (cond ((and new (not (equal? new (or pulled-version version))))
                 (list name version new channel where #f))
                ((and pulled-version (not (equal? pulled-version version)))
                 (list name version pulled-version channel where #t))
                (else #f)))))
     installed))

  (when %porcelain?
    ;; channel NAME PINNED LATEST
    ;; package NAME INSTALLED NEWEST CHANNEL home|system pulled|new
    (for-each (match-lambda
                ((name . latest)
                 (format #t "channel\t~a\t~a\t~a~%" name
                         (match (assq name channels)
                           ((_ _ _ _ commit) (or commit "-")))
                         latest)))
              moved)
    (for-each (match-lambda
                ((name old new channel where pulled?)
                 (format #t "package\t~a\t~a\t~a\t~a\t~a\t~a~%"
                         name old new channel where
                         (if pulled? "pulled" "new"))))
              rows)
    (format #t "done~%")
    (force-output))

  (cond ((null? rows)
         (emit "~%Every installed package is at its newest version.~%"))
        (else
         (emit "~%  ~24a ~22a ~22a ~10a ~a~%"
               "package" "installed" "newest" "channel" "in")
         (for-each (match-lambda
                     ((name old new channel where pulled?)
                      (emit "  ~24a ~22a ~22a ~10a ~a~a~%"
                            name old new channel where
                            (if pulled? "  (already pulled)" ""))))
                   rows)
         (let ((system? (any (match-lambda ((_ _ _ _ where _)
                                            (string=? where "system")))
                             rows))
               (pulled? (every (match-lambda ((_ _ _ _ _ pulled?) pulled?))
                               rows)))
           (if pulled?
               (emit "~%Install them:  guix bump ~a~%"
                     (if system? "--system" "--home"))
               (emit "~%Update one:  guix bump ~a~%Update all:  guix bump all ~a~%"
                     (match rows (((name . _) . _) name))
                     (if system? "--system" "--home")))))))

;;;
;;; Installing and removing packages: the list of names in the config.
;;;
;;; The config holds one list of packages that is ours to edit, which the
;;; home environment installs.  It is either a list of names,
;;;
;;;   (define %managed-packages
;;;     '("hello"
;;;       "node@22.14.0"))
;;;
;;; used as (map specification->package %managed-packages), or a list of
;;; package values,
;;;
;;;   (define (%home-packages)
;;;     (list firefox node ...))
;;;
;;; Installing adds an element and applies the home; removing takes one
;;; out.  Elements that are neither a package variable nor a
;;; (specification->package "NAME") call are left to whoever wrote them.

;; The variable holding the list: the `packages' setting, else the first of
;; these that the config defines.  The setting may be written with the
;; parentheses of a procedure, "(%home-packages)".
(define (managed-variables)
  (match (setting "packages")
    (#f '("%managed-packages" "%apps"))
    (variable
     (list (string-trim-both variable
                             (lambda (c) (memv c '(#\( #\) #\space))))))))

(define (managed-form text)
  ;; Return (START . END) of the form defining the managed list in TEXT, or
  ;; #f.
  (definition-form text (managed-variables)))

;; The list can be written in two ways:
;;
;;   names    (define %apps '("firefox" "node@22.14.0"))
;;   values   (define (%home-packages) (list firefox node (f x)))
;;
;; In a list of values an element is a variable bound to a package, a
;; (specification->package "NAME") call, or anything else; only the first
;; two are understood, and the rest is left alone.

(define (managed-list text)
  ;; Return (KIND START END): the list inside the managed form, where START
  ;; is at its opening parenthesis, END is after its closing one and KIND is
  ;; `names' or `values'.  #f when there is none.
  (match (managed-form text)
    (#f #f)
    ((start . end)
     (let loop ((i (+ start 1)))
       (and (< i end)
            (let ((c (string-ref text i)))
              (cond ((char=? c #\;) (loop (skip-line text i)))
                    ((char=? c #\") (loop (skip-string text i)))
                    ((and (char=? c #\') (< (+ i 1) end)
                          (char=? (string-ref text (+ i 1)) #\())
                     (list 'names (+ i 1) (form-end text (+ i 1))))
                    ((and (char=? c #\() (< (+ i 6) end)
                          (string=? (substring text i (+ i 5)) "(list")
                          (char-whitespace? (string-ref text (+ i 5))))
                     (list 'values i (form-end text i)))
                    (else (loop (+ i 1))))))))))

(define (list-elements text kind start end)
  ;; Return ((S . E) ...), the elements of the list from START to END.
  (define (delimiter? c)
    (or (char-whitespace? c) (memv c '(#\( #\) #\" #\;))))
  (define last (- end 1))               ;the closing parenthesis
  (let loop ((i (+ start (if (eq? kind 'values) 5 1)))
             (result '()))
    (if (>= i last)
        (reverse result)
        (let ((c (string-ref text i)))
          (cond ((char-whitespace? c) (loop (+ i 1) result))
                ((char=? c #\;) (loop (skip-line text i) result))
                ((char=? c #\")
                 (let ((e (skip-string text i)))
                   (loop e (cons (cons i e) result))))
                ((char=? c #\()
                 (let ((e (form-end text i)))
                   (loop e (cons (cons i e) result))))
                (else
                 ;; An atom, or a prefix such as ' or #~ before a form.
                 (let* ((stop (or (string-index text delimiter? i last) last))
                        (e    (if (and (< stop last)
                                       (char=? (string-ref text stop) #\()
                                       (> stop i))
                                  (form-end text stop)
                                  stop)))
                   (loop (max e (+ i 1)) (cons (cons i e) result)))))))))

;; Variable name -> names of the packages public variables of that name are
;; bound to, in the running Guix.  Built when first needed: it loads every
;; package module.
(define %variable-packages
  (delay
    (let ((table (make-hash-table)))
      (fold-module-public-variables*
       (lambda (module symbol variable result)
         (let ((value (false-if-exception (variable-ref variable))))
           (when (package? value)
             (hash-set! table symbol
                        (lset-adjoin string=? (hash-ref table symbol '())
                                     (package-name value)))))
         result)
       #f
       (all-modules (%package-module-path) #:warn (const #f)))
      table)))

(define (element-specs text element)
  ;; Return the package specifications the ELEMENT (S . E) of the managed
  ;; list may stand for: one for a name, one or more for a variable (the
  ;; same variable name can exist in several modules), '() for anything
  ;; that is not understood.
  (match (false-if-exception
          (call-with-input-string (substring text (car element) (cdr element))
            read))
    ((? string? spec) (list spec))
    (('specification->package (? string? spec)) (list spec))
    ((? symbol? variable)
     (hash-ref (force %variable-packages) variable '()))
    (_ '())))

(define (managed-elements text)
  ;; Return (KIND ((S . E) SPEC ...) ...) for the managed list of TEXT, or
  ;; #f when there is no such list.
  (match (managed-list text)
    (#f #f)
    ((kind start end)
     (cons kind
           (map (lambda (element)
                  (cons element (element-specs text element)))
                (list-elements text kind start end))))))

(define (managed-specs text)
  ;; Return the package specifications ("NAME" or "NAME@VERSION") the
  ;; managed list of TEXT installs, as far as they are understood, or #f
  ;; when there is no such list.
  (match (managed-elements text)
    (#f #f)
    ((_ . elements)
     (append-map (match-lambda ((_ . specs) specs)) elements))))

(define (spec-name spec)
  (car (string-split spec #\@)))

(define (spec-version spec)
  (match (string-split spec #\@)
    ((_ version) version)
    (_ #f)))

(define (find-element text name)
  ;; Return the element (S . E) of the managed list that installs the
  ;; package NAME, or #f.
  (match (managed-elements text)
    (#f #f)
    ((_ . elements)
     (any (match-lambda
            ((element . specs)
             (and (any (lambda (spec) (string=? (spec-name spec) name)) specs)
                  element)))
          elements))))

(define (spec-text kind spec)
  ;; How SPEC is written in a list of KIND.
  (if (eq? kind 'names)
      (format #f "~s" spec)
      (format #f "(specification->package ~s)" spec)))

(define (blank? string)
  (string-every (lambda (c) (memv c '(#\space #\tab))) string))

(define (add-spec text spec)
  ;; Return TEXT with SPEC as the last element of the managed list.
  (match (managed-list text)
    ((kind start end)
     (let* ((elements (list-elements text kind start end))
            (close    (- end 1))
            (indent   (match elements
                        (((s . _) . _) (column text s))
                        (() #f))))
       (string-append (string-trim-right (substring text 0 close))
                      (cond (indent
                             (string-append "\n" (make-string indent #\space)))
                            ((eq? kind 'values) " ")
                            (else ""))
                      (spec-text kind spec)
                      (substring text close))))))

(define (remove-spec text name)
  ;; Return TEXT without the element of the managed list that installs
  ;; NAME.  Line breaks are kept, so a comment before it stays a comment
  ;; and nothing after it is drawn into one.  An element alone on its line
  ;; goes with the whole line, its trailing comment included.
  (match (find-element text name)
    (#f text)
    ((s . e)
     (let* ((line-start (match (string-rindex text #\newline 0 s)
                          (#f 0)
                          (i (+ i 1))))
            (line-end   (or (string-index text #\newline e)
                            (string-length text)))
            (before     (substring text line-start s))
            (after      (substring text e line-end))
            (rest       (string-trim after (lambda (c)
                                             (memv c '(#\space #\tab)))))
            (opening?   (let ((head (string-trim-right before)))
                          (or (string-suffix? "(" head)
                              (string-suffix? "(list" head)))))
       (cond
        ;; Alone on its line, perhaps with a comment about it.
        ((and (blank? before)
              (or (string-null? rest) (string-prefix? ";" rest))
              (< line-end (string-length text)))
         (string-append (substring text 0 line-start)
                        (substring text (+ line-end 1))))
        ;; The first element, right after the opening: bring the next one
        ;; up, unless a comment follows on this line.
        (opening?
         (if (string-prefix? ";" rest)
             (string-append (substring text 0 s) (substring text e))
             (string-append
              (substring text 0 s)
              (string-trim (substring text e) char-whitespace?))))
        (else
         (string-append (string-trim-right (substring text 0 s)
                                           (lambda (c)
                                             (memv c '(#\space #\tab))))
                        (substring text e))))))))

(define (replace-spec text spec)
  ;; Return TEXT with the element that installs SPEC's package written as
  ;; SPEC.
  (match (find-element text (spec-name spec))
    (#f text)
    ((s . e)
     (match (managed-list text)
       ((kind . _)
        (string-append (substring text 0 s) (spec-text kind spec)
                       (substring text e)))))))

(define (versions-of name)
  ;; The versions of the package NAME in the running Guix, newest first.
  (delete-duplicates
   (map package-version
        (or (false-if-exception (find-packages-by-name name)) '()))))

(define (require-managed-list file text)
  (unless (managed-specs text)
    (let ((variable (car (managed-variables))))
      (die "~a has no list of package names called ~a.  Either name the
list it does have (guix bump --set packages=NAME), or add this to it:

  (define ~a
    '())

and, in the home environment's packages:

  (map specification->package ~a)
" file variable variable variable))))

(define (apply-home guix file original updated message build-options)
  ;; Write UPDATED to FILE and apply the home.  On failure put ORIGINAL
  ;; back; on success say what changed and commit with MESSAGE.
  (let ((before (installed-in (home-profile))))
    (write-config file updated)
    (cond ((and (prebuild guix "home" file build-options)
                (begin
                  (say "Applying to the home environment")
                  (apply run guix "home" "reconfigure" file build-options)))
           (report-changes before (installed-in (home-profile)))
           (commit-config file message)
           (say "Done.")
           #t)
          (else
           (write-config file original)
           (emit "~%guix bump: that did not work; ~a is back as it was and nothing was
switched.~%" file)
           #f))))

(define (install guix file text specs build-options)
  ;; Add SPECS ("NAME" or "NAME@VERSION") to the managed list, or change
  ;; their version there, and apply the home.
  (require-managed-list file text)
  (let* ((managed   (managed-specs text))
         (installed (installed-in (home-profile)))
         (updated
          (fold
           (lambda (spec text)
             (let ((name    (spec-name spec))
                   (version (spec-version spec)))
               (unless (if version
                           (member version (versions-of name))
                           (pair? (versions-of name)))
                 (die "~a: no such package~a" spec
                      (if (pair? (versions-of name))
                          (format #f "; ~a has: ~a" name
                                  (string-join (versions-of name) ", "))
                          " (see guix bump --search WORD)")))
               (cond ((member spec managed)
                      (emit "  ~a is already in the list~%" spec)
                      text)
                     ((find (lambda (old) (string=? (spec-name old) name))
                            managed)
                      => (lambda (old)
                           (emit "  ~a -> ~a~%" old spec)
                           (replace-spec text spec)))
                     ((assoc name installed)
                      (die "~a is installed by ~a itself, not through the list: change it
there" name file))
                     (else
                      (emit "  + ~a~%" spec)
                      (add-spec text spec)))))
           text specs)))
    (cond ((string=? updated text)
           (emit "Nothing to do.~%")
           #t)
          (else
           (apply-home guix file text updated
                       (string-append "Install " (string-join specs ", "))
                       build-options)))))

(define (uninstall guix file text names build-options)
  ;; Take NAMES out of the managed list and apply the home.
  (require-managed-list file text)
  (let* ((managed   (managed-specs text))
         (installed (installed-in (home-profile)))
         (updated
          (fold
           (lambda (name text)
             (let ((name (spec-name name)))
               (cond ((find (lambda (old) (string=? (spec-name old) name))
                            managed)
                      (emit "  - ~a~%" name)
                      (remove-spec text name))
                     ((assoc name installed)
                      (die "~a is installed by ~a itself, not through the list: remove it
there" name file))
                     (else
                      (die "~a is not installed" name)))))
           text names)))
    (apply-home guix file text updated
                (string-append "Remove " (string-join names ", "))
                build-options)))

(define (one-line text)
  ;; TEXT without tabs or line breaks, for a tab-separated line.
  (string-join (string-tokenize (or text "")) " "))

(define (show-installed text)
  ;; List the packages of the home profile: version, whether the managed
  ;; list installed them, and the versions there are to choose from.
  (let ((managed (or (managed-specs text) '())))
    (for-each
     (match-lambda
       ((name version _)
        (let ((spec     (find (lambda (spec) (string=? (spec-name spec) name))
                              managed))
              (versions (versions-of name)))
          (if %porcelain?
              ;; installed NAME VERSION list|config SPEC VERSIONS,...
              (format #t "installed\t~a\t~a\t~a\t~a\t~a~%"
                      name version (if spec "list" "config") (or spec "-")
                      (string-join versions ","))
              (format #t "  ~28a ~22a ~a~%" name version
                      (if spec "" "(set in the config by hand)"))))))
     (sort (installed-in (home-profile))
           (lambda (a b) (string<? (car a) (car b)))))
    (when %porcelain?
      (format #t "done~%"))
    (force-output)))

(define (search terms)
  ;; List the packages whose name or one-line description has every one of
  ;; TERMS, best matches first.
  (let* ((installed (installed-in (home-profile)))
         (rxs     (map (lambda (term)
                         (make-regexp (regexp-quote term) regexp/icase))
                       terms))
         (found   (fold-packages
                   (lambda (p result)
                     (if (every (lambda (rx)
                                  (or (regexp-exec rx (package-name p))
                                      (regexp-exec rx (or (false-if-exception
                                                           (package-synopsis p))
                                                          ""))))
                                rxs)
                         (cons p result)
                         result))
                   '()))
         ;; One entry per name: its newest version.
         (newest  (let ((table (make-hash-table)))
                    (for-each
                     (lambda (p)
                       (let ((old (hash-ref table (package-name p))))
                         (when (or (not old)
                                   (version>? (package-version p)
                                              (package-version old)))
                           (hash-set! table (package-name p) p))))
                     found)
                    (hash-map->list (lambda (_ p) p) table)))
         (first   (string-downcase (car terms)))
         (rank    (lambda (p)
                    (let ((name (string-downcase (package-name p))))
                      (cond ((string=? name first) 0)
                            ((string-prefix? first name) 1)
                            ((string-contains name first) 2)
                            (else 3)))))
         (sorted  (sort newest
                        (lambda (a b)
                          (let ((ra (rank a)) (rb (rank b)))
                            (or (< ra rb)
                                (and (= ra rb)
                                     (string<? (package-name a)
                                               (package-name b))))))))
         (shown   (take sorted (min 100 (length sorted)))))
    (for-each
     (lambda (p)
       (let ((name (package-name p)))
         (if %porcelain?
             ;; result NAME VERSION installed|- SYNOPSIS
             (format #t "result\t~a\t~a\t~a\t~a~%" name (package-version p)
                     (if (assoc name installed) "installed" "-")
                     (one-line (package-synopsis p)))
             (format #t "  ~28a ~16a ~a~a~%" name (package-version p)
                     (one-line (package-synopsis p))
                     (if (assoc name installed) "  [installed]" "")))))
     shown)
    (cond (%porcelain? (format #t "done~%"))
          ((null? shown) (format #t "Nothing found.~%"))
          (else
           (format #t "~%~a found~a.  Install one: guix bump --install NAME~%"
                   (length sorted)
                   (if (> (length sorted) 100) ", the first 100 shown" ""))))
    (force-output)))


;;;
;;; Cleaning up.
;;;

(define (clean-up guix system?)
  ;; Drop old generations, then collect garbage if the disk is getting full.
  (let ((keep (or (getenv "GUIX_BUMP_KEEP") "1m"))
        (free (or (getenv "GUIX_BUMP_FREE") "100G")))
    (say "Deleting generations older than ~a" keep)
    (run guix "home" "delete-generations" keep)
    (run guix "pull" (string-append "--delete-generations=" keep))
    (when system?
      (run "sudo" guix "system" "delete-generations" keep))
    (say "Collecting garbage if less than ~a is free" free)
    (run guix "gc" (string-append "--free-space=" free))))


;;;
;;; Commands.
;;;

(define (show-status file channels)
  (format #t "Pins in ~a~%~%" file)
  (format #t "  ~16a ~12a ~12a ~12a~%" "channel" "pinned" "running" "latest")
  (for-each
   (match-lambda
     ((name _ url branch commit)
      (let ((latest  (latest-commit url branch))
            (running (running-commit name)))
        (format #t "  ~16a ~12a ~12a ~12a ~a~%"
                name (short commit) (short running) (short latest)
                (cond ((not commit) "not pinned")
                      ((not latest) "could not reach the repository")
                      ((not (equal? commit latest)) "update available")
                      ((not (equal? commit running)) "pinned, not pulled yet")
                      (else ""))))))
   channels)
  (newline))

(define (show-settings)
  ;; Show each setting, and what it comes to with the config as it is.
  (let* ((file     (config-file))
         (text     (and (file-exists? file)
                        (call-with-input-file file get-string-all)))
         (packages (and text
                        (find (lambda (variable)
                                (definition-form text (list variable)))
                              (managed-variables))))
         (channels (and text
                        (or (not (setting "channels"))
                            (definition-form text
                              (list (setting "channels"))))
                        (length (read-channels text))))
         (rows
          `(("config" ,(or (setting "config") "")
             ,(string-append
               file
               (if text "" " (no such file)")
               (if (getenv "GUIX_BUMP_CONFIG")
                   " (from $GUIX_BUMP_CONFIG, which comes first)"
                   "")))
            ("packages" ,(or (setting "packages") "")
             ,(or packages
                  (format #f "no (define ~a ...) in the config"
                          (car (managed-variables)))))
            ("channels" ,(or (setting "channels") "")
             ,(cond ((not text) "-")
                    ((not channels)
                     (format #f "no (define ~a ...) in the config"
                             (setting "channels")))
                    ((setting "channels")
                     (format #f "~a channels in ~a" channels
                             (setting "channels")))
                    (else
                     (format #f "~a channels (every channel in the file)"
                             channels))))
            ("git" ,(or (setting "git") "")
             ,(let* ((dir  (dirname file))
                     (repo (and text
                                (quietly (git) "-C" dir "rev-parse"
                                         "--is-inside-work-tree")))
                     (remote (and repo
                                  (match (output-lines (git) "-C" dir
                                                       "remote" "get-url"
                                                       "--push" "origin")
                                    ((url . _) url)
                                    (_ #f)))))
                (cond ((not repo)
                       "the config is not in a git repository: nothing to do")
                      ((eq? (git-mode) 'off)
                       "changes are not committed")
                      ((eq? (git-mode) 'commit)
                       (format #f "each change is committed in ~a" dir))
                      (remote
                       (format #f "each change is committed and pushed to ~a"
                               remote))
                      (else
                       (format #f "each change is committed in ~a (no remote to push to)"
                               dir)))))
            ,@(let ((dir (and text (config-repository))))
                (map (lambda (key)
                       (if dir
                           (let ((value (git-value dir key)))
                             (list key value
                                   (match key
                                     ("git-remote"
                                      (if (string-null? value)
                                          "no remote: changes are not pushed"
                                          (format #f "pushed to ~a" value)))
                                     (_
                                      (if (string-null? value)
                                          (let ((global
                                                 (match (output-lines
                                                         (git) "config" "--global"
                                                         (if (string=? key "git-name")
                                                             "user.name"
                                                             "user.email"))
                                                   ((v . _) v)
                                                   (_ #f))))
                                            (if global
                                                (format #f "~a (your global git setting)"
                                                        global)
                                                "not set: git will refuse to commit"))
                                          value)))))
                           (list key "" "the config is not in a git repository")))
                     %git-keys)))))
    (for-each (match-lambda
                ((key value effective)
                 (if %porcelain?
                     ;; setting KEY VALUE IN-EFFECT
                     (format #t "setting\t~a\t~a\t~a~%" key value effective)
                     (format #t "  ~10a ~24a ~a~%" key
                             (if (string-null? value) "(default)" value)
                             effective))))
              rows)
    (if %porcelain?
        (format #t "done~%")
        (format #t "~%Change one: guix bump --set KEY=VALUE   (in ~a)~%"
                (settings-file)))
    (force-output)))

(define (show-help)
  (display "Usage: guix bump [OPTION]... [CHANNEL|APP...|all] [-- BUILD-OPTION...]
Move the channel pins in the config file to the latest commit of each
channel's branch, then `guix pull' to them.  With no CHANNEL and no action,
show each channel's pinned, running and latest commit.

  guix bump --check    list the installed apps that have a newer version
  guix bump --search WORD...      find packages by name or description
  guix bump --install NAME...     add them to the config's list of packages
                                  and apply the home; NAME@VERSION picks or
                                  changes a version
  guix bump --remove NAME...      take them out of that list and apply
  guix bump --installed           list what the home has installed
  guix bump --settings            show which file and lists are used
  guix bump --set KEY=VALUE...    change that: config=FILE, packages=VARIABLE
                                  (the list --install edits), channels=VARIABLE
                                  (the list of channels), git=push|commit|off
                                  (for a config in a git repository: commit
                                  and push each change, commit only, or
                                  neither); empty = default.  In the config's
                                  repository: git-remote=URL (where to push;
                                  empty removes it), git-name=, git-email=
                                  (who commits)
  guix bump APP        update that app now: move the pin of the channel it
                       comes from, pull, and apply the home (or the system,
                       if that is where the app is installed)

      --check      change nothing; show which installed packages would get
                   a newer version (of the named channels, or of all)
      --porcelain  with --check, --search, --installed: tab-separated lines
                   on standard output, for programs (Guix Manager)
  -H, --home       then apply the home environment (guix home reconfigure)
  -S, --system     then apply the system (sudo guix system reconfigure);
                   this includes the home when the config's system applies
                   it (home-with-system-service)
      --undo       put the pins back as they were before the last change,
                   and pull; add -H / -S to apply that too
  -y, --yes        don't ask before compiling slow packages from source
      --gc         afterwards, delete generations older than a month and
                   collect garbage if less than 100G is free
      --log        also write everything to a file in ~/.local/state/guix-bump
      --shutdown   power the computer off once everything succeeded
      --screen-off turn the screens off while it runs: they come on at the
                   next input and go off after a minute without any (also
                   when a video or an app keeps the session awake).  If it
                   fails they stay off until the next input, with the error
                   on screen.  Wayland only
  -n, --dry-run    show which pins would move and stop
  -h, --help       show this help

With an action and no CHANNEL, nothing is bumped: the config as it is now
gets pulled (if it isn't already) and applied.  BUILD-OPTIONs after `--' are
passed to pull and reconfigure, for example: -- --cores=6 --max-jobs=6

Before applying freshly pulled pins, the packages that would be compiled
here for lack of a substitute are checked; if slow ones are among them you
are asked whether to continue.

--install and --remove edit one list of names in the config, (define
%managed-packages '(...)) or (define %apps '(...)), whose packages the home
installs.  Packages the config names in another way are not touched.

The config file is $GUIX_BUMP_CONFIG, else the `config' setting, else
~/config.scm.  Settings are in ~/.config/guix-manager/settings.  If it is in a git
repository, every change that was pulled or applied is committed and pushed
(the `git' setting: push, commit or off).
Environment: GUIX_BUMP_KEEP (1m), GUIX_BUMP_FREE (100G), GUIX_BUMP_HEAVY
(regexp of slow package names).

An app is updated by moving its channel, so the other apps of that channel
move with it.  For the `guix' channel that is everything Guix provides (and
`nonguix' moves along): you are asked first.  Afterwards the apps that are
still open in their old version are listed, and a reboot is suggested when
the kernel or a driver changed.

`guix nightly' is short for:
  guix bump all --system --home --yes --gc --log --shutdown --screen-off
(--screen-on leaves out --screen-off).
"))

(define-command (guix-bump . args)
  (category extension)
  (synopsis "move channel pins in the config to the latest commits and pull")

  (define-values (own-args build-options)
    (let ((tail (member "--" args)))
      (if tail
          (values (take args (- (length args) (length tail))) (cdr tail))
          (values args '()))))

  (define (flag? . names)
    (any (lambda (name) (member name own-args)) names))

  (when (flag? "-h" "--help")
    (show-help)
    (exit 0))
  (when (flag? "--version")
    (format #t "guix bump ~a~%" %version)
    (exit 0))

  (define check?    (flag? "--check"))
  (set! %porcelain? (flag? "--porcelain"))
  (define install?   (flag? "--install"))
  (define remove?    (flag? "--remove"))
  (define search?    (flag? "--search"))
  (define installed? (flag? "--installed"))
  ;; With these, the names are packages or words, not channels.
  (define settings?  (flag? "--settings"))
  (define set?       (flag? "--set"))
  (define manage?    (or install? remove? search? installed? settings? set?))
  (define shutdown? (flag? "--shutdown"))
  (define screen-off? (flag? "--screen-off"))
  (define dry-run?  (flag? "-n" "--dry-run"))
  (define undo?     (flag? "--undo"))
  (define yes?      (flag? "-y" "--yes"))
  (define gc?       (flag? "--gc"))
  (define log?      (flag? "--log"))
  (define names
    (remove (lambda (arg) (string-prefix? "-" arg)) own-args))

  (for-each (lambda (arg)
              (unless (member arg '("-H" "--home" "-S" "--system" "--shutdown"
                                    "--screen-off"
                                    "-n" "--dry-run" "--undo" "-y" "--yes"
                                    "--gc" "--log" "--check" "--porcelain"
                                    "--install" "--remove" "--search"
                                    "--installed" "--settings" "--set"
                                    "--version"))
                (die "~a: unknown option (see guix bump --help)" arg)))
            (filter (lambda (arg) (string-prefix? "-" arg)) own-args))

  (when (and undo? (pair? names))
    (die "--undo takes no channel names: it restores every pin"))

  (when set?
    ;; Check them all before changing any.
    (for-each
     (match-lambda
       ((key . value)
        (if (member key %git-keys)
            (set-git-value! key value)
            (write-setting! key value))))
     (map (lambda (pair)
            (match (string-index pair #\=)
              (#f (die "~a: expected KEY=VALUE" pair))
              (i (let ((key (substring pair 0 i)))
                   (unless (or (member key %setting-keys)
                               (member key %git-keys))
                     (die "~a: no such setting; there are: ~a" key
                          (string-join (append %setting-keys %git-keys)
                                       ", ")))
                   (when (and (string=? key "git")
                              (not (member (substring pair (+ i 1))
                                           '("" "push" "commit" "off"))))
                     (die "git=~a: expected push, commit or off"
                          (substring pair (+ i 1))))
                   (cons key (substring pair (+ i 1)))))))
          names)))
  (when (or set? settings?)
    (show-settings)
    (exit 0))

  (define file (config-file))
  (unless (file-exists? file)
    (die "~a: no such file (guix bump --set config=FILE)" file))

  (define original (call-with-input-file file get-string-all))
  ;; Does the system in the config apply the home itself?  (A use of
  ;; `home-with-system-service' at the start of a line, so not a comment.)
  ;; Then --system covers the home, and reconfiguring the home as well
  ;; would only add a second, identical generation.
  (define home-in-system?
    (->bool (string-match "(^|\n)[ \t]*\\(home-with-system-service[ \t\n]"
                          original)))
  (define channels (read-channels original))
  (when (null? channels)
    (die "~a: found no (channel ...) forms" file))

  ;; Names that are not channels are apps (packages).
  (define home-before   (installed-in (home-profile)))
  (define system-before (installed-in %system-profile))
  (define app-names
    (if manage?
        '()
        (remove (lambda (name)
                  (or (string=? name "all")
                      (assq (string->symbol name) channels)))
                names)))
  ;; What the config installs, as the pulled Guix has it: the package of
  ;; that name the config really uses, and the channel it is from.
  (define configured
    (if (null? app-names)
        '()
        (or (config-versions (pulled-guix) original '() build-options) '())))
  (define apps                          ;((NAME VERSION CHANNEL WHERE) ...)
    (filter-map
     (lambda (name)
       (and (member name app-names)
            (match (or (match (assoc name configured)
                         ((_ version channel) (cons version channel))
                         (_ #f))
                       (available name))
              ((version . channel)
               (unless (assq channel channels)
                 (die "~a comes from the channel '~a', which ~a doesn't pin"
                      name channel file))
               (list name version channel
                     (cond ((assoc name home-before) 'home)
                           ((assoc name system-before) 'system)
                           (else #f))))
              (_
               (die "~a: neither a channel of the config (~a) nor a package"
                    name
                    (string-join (map (compose symbol->string car) channels)
                                 ", "))))))
     names))
  (define (app-in? where)
    (any (match-lambda ((_ _ _ in) (eq? in where))) apps))

  (define home?   (or (flag? "-H" "--home") (app-in? 'home)))
  (define system? (or (flag? "-S" "--system") (app-in? 'system)))
  (define home-alone?
    (and home? (not (and system? home-in-system?))))

  (define selected
    (delete-duplicates
     (append
      (cond (manage? '())
            ((member "all" names) channels)
            (else
             (filter-map (lambda (name) (assq (string->symbol name) channels))
                         names)))
      ;; The channels the apps come from.  nonguix is written against a
      ;; particular Guix, so the two move together.
      (append-map (match-lambda
                    ((_ _ channel _)
                     (filter-map (lambda (name) (assq name channels))
                                 (if (eq? channel 'guix)
                                     '(guix nonguix)
                                     (list channel)))))
                  apps))))

  (define guix (pulled-guix))

  (when (> (length (filter identity (list install? remove? search?
                                          installed?)))
           1)
    (die "--install, --remove, --search and --installed don't go together"))
  (when (and (or install? remove? search?) (null? names))
    (die "~a what?  Give at least one name"
         (cond (install? "install") (remove? "remove") (else "search for"))))

  (cond
   (installed?
    (show-installed original))
   (search?
    (search names))
   (install?
    (exit (if (install guix file original names build-options) 0 1)))
   (remove?
    (exit (if (uninstall guix file original names build-options) 0 1)))
   (check?
    (check guix original (if (null? selected) channels selected)
           build-options))
   ((and (null? selected)
         (not (or home? system? shutdown? undo? gc?)))
    (show-status file channels))
   (else
    (let ()
      (when (and log? (not dry-run?))
        (set! %log (string-append (state-directory) "/"
                                  (strftime "%Y-%m-%d-%H%M%S"
                                            (localtime (current-time)))
                                  ".log"))
        (emit "Log: ~a~%" %log))

      ;; Ask for the password before the long part.
      (define keepalive
        (and system? (not dry-run?) (start-sudo-keepalive)))

      ;; After the password prompt, which needs the screen.
      (when (and screen-off? (not dry-run?))
        (start-screen-off))

      (define (finish code)
        (when keepalive
          (false-if-exception (kill keepalive SIGTERM)))
        (when (and %log (not (zero? code)))
          (emit "~%The log of this run is ~a~%" %log))
        (exit code))

      ;; What moved, as "NAME OLD -> NEW" strings, for the commit message.
      (define moves '())

      (define (move text name old new)
        (emit "  ~16a ~a -> ~a~%" name (short old) (short new))
        (set! moves
              (cons (format #f "~a ~a -> ~a" name (short old) (short new))
                    moves))
        (set-pin text name new))

      ;; 1. Move the pins.
      (define updated
        (if undo?
            (let ((previous
                   (if (file-exists? (previous-pins-file))
                       (call-with-input-file (previous-pins-file) read)
                       (die "nothing to undo: no earlier pins were saved"))))
              (fold (lambda (channel text)
                      (match channel
                        ((name _ _ _ commit)
                         (let ((old (assq-ref previous name)))
                           (if (and (string? old) (not (equal? old commit)))
                               (move text name commit old)
                               text)))))
                    original
                    channels))
            (fold (lambda (channel text)
                    (match channel
                      ((name _ url branch commit)
                       (let ((latest (latest-commit url branch)))
                         (cond ((not latest)
                                (emit "  ~16a could not reach ~a, left alone~%"
                                      name url)
                                text)
                               ((equal? latest commit)
                                (emit "  ~16a ~a  already the latest~%"
                                      name (short commit))
                                text)
                               (else
                                (move text name commit latest)))))))
                  original
                  selected)))

      (define changed? (not (string=? updated original)))

      (when (and undo? (not changed?))
        (emit "The pins are already what they were before the last change.~%"))

      ;; An app that is already the newest there is: nothing to do.
      (when (and (pair? apps) (not changed?)
                 (not (flag? "-H" "--home" "-S" "--system"))
                 (every (match-lambda
                          ((name version _ where)
                           (match (assoc name (append home-before
                                                      system-before))
                             ((_ installed . _) (equal? installed version))
                             (_ #f))))
                        apps))
        (for-each (match-lambda
                    ((name version . _)
                     (emit "~a ~a is installed and is the newest version.~%"
                           name version)))
                  apps)
        (finish 0))

      ;; An app of Guix itself: everything else Guix provides moves too.
      (when (and (not dry-run?) (not yes?)
                 (any (match-lambda ((_ _ channel _) (eq? channel 'guix)))
                      apps)
                 (not (equal? (assq-ref (pins updated) 'guix)
                              (assq-ref (pins original) 'guix))))
        (emit "~%~a comes from Guix itself.  Updating it moves the `guix' pin, and with
it every package Guix provides: all of them are updated together, which
can mean a lot to download or compile.~%"
              (string-join
               (filter-map (match-lambda
                             ((name _ channel _)
                              (and (eq? channel 'guix) name)))
                           apps)
               ", "))
        (unless (ask "Update everything from Guix?")
          (emit "Nothing was changed.~%")
          (finish 1)))

      (when dry-run?
        (when (or home? system?)
          (emit "Would apply: ~a.~%"
                (cond ((and system? home-in-system?)
                       "the system, which applies the home too")
                      ((and system? home?) "the system, then the home")
                      (system? "the system")
                      (else "the home"))))
        (finish 0))

      (define earlier-pins
        (and (file-exists? (previous-pins-file))
             (call-with-input-file (previous-pins-file) get-string-all)))

      (define (restore-earlier-pins)
        (if earlier-pins
            (call-with-output-file (previous-pins-file)
              (lambda (port) (put-string port earlier-pins)))
            (false-if-exception (delete-file (previous-pins-file)))))

      (when changed?
        ;; Remember the pins being replaced, for --undo.
        (call-with-output-file (previous-pins-file)
          (lambda (port) (write (pins original) port) (newline port)))
        (write-config file updated))

      ;; 2. Pull, unless the running Guix is already at the file's pins.
      (define need-pull?
        (any (match-lambda
               ((name _ _ _ commit)
                (not (and commit (equal? commit (running-commit name))))))
             (read-channels updated)))

      (when need-pull?
        (say "Pulling Guix to the pins in ~a" file)
        (unless (apply run guix "pull" "-C" file
                       "--unsafe-channel-evaluation" "--allow-downgrades"
                       build-options)
          (when changed?
            (write-config file original)
            (restore-earlier-pins)
            (emit "~%guix bump: pull failed; the pins in ~a are back as they were~%"
                  file))
          (finish 1)))

      (when changed?
        (commit-config file
                       (string-append (if undo? "Undo: " "Bump ")
                                      (string-join (reverse moves) ", "))))

      ;; 3. Before applying new pins: would this compile something big?
      (when (and need-pull? (or home? system?))
        (unless (confirm-builds guix
                                (append (if system? '("system") '())
                                        (if home-alone? '("home") '()))
                                file build-options yes?)
          (emit "~%Stopped: the new pins are pulled but nothing was applied.
`guix bump --undo' puts the old pins back; `guix bump~a~a' applies later.~%"
                (if system? " --system" "") (if home? " --home" ""))
          (finish 1)))

      ;; 4. Apply.
      (when system?
        (unless (and (prebuild guix "system" file build-options)
                     (begin
                       (say "Reconfiguring the system")
                       (apply run "sudo" guix "system" "reconfigure" file
                              build-options)))
          (emit "~%guix bump: system reconfigure failed; nothing was switched.
`guix bump --undo~a' goes back to the pins from before.~%"
                (if home? " --system --home" " --system"))
          (finish 1)))

      (when (and home? (not home-alone?))
        (say "The home environment was applied with the system"))
      (when home-alone?
        (unless (and (prebuild guix "home" file build-options)
                     (begin
                       (say "Reconfiguring the home environment")
                       (apply run guix "home" "reconfigure" file
                              build-options)))
          (emit "~%guix bump: home reconfigure failed; nothing was switched.
`guix bump --undo --home' goes back to the pins from before.~%")
          (finish 1)))

      (when home?
        (report-changes home-before (installed-in (home-profile))))
      (when system?
        (report-changes system-before (installed-in %system-profile))
        (when (reboot-needed?)
          (emit "~%The kernel or a driver changed: reboot to use it.~%")))
      (for-each (match-lambda
                  ((name _ _ #f)
                   (emit "~%~a is not installed: add it to the packages in ~a,
then run `guix bump --home'.~%"
                         name file))
                  (_ #t))
                apps)

      ;; Edits made by hand that were just applied successfully.
      (when (or home? system?)
        (commit-config file
                       (string-append "Applied to "
                                      (cond ((and home? system?)
                                             "system and home")
                                            (system? "system")
                                            (else "home")))))

      (when gc?
        (clean-up guix system?))

      (say "Done.~a"
           (cond ((or home? system?) "")
                 (need-pull?
                  "  New packages are installed by: guix bump --home")
                 (else "  Nothing to pull.")))

      (when shutdown?
        (when keepalive
          (false-if-exception (kill keepalive SIGTERM)))
        (power-off))
      (finish 0)))))
