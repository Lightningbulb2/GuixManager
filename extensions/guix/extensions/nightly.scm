;;; guix nightly --- update everything, then power off
;;;
;;; Bump every channel pin, pull, reconfigure the system and the home
;;; environment, clean up old generations, and power off, with a log.  The
;;; screens are off while it runs (--screen-on keeps them on).  If a step
;;; fails the computer stays on with the error on screen.

(define-module (guix extensions nightly)
  #:use-module (guix scripts)
  #:use-module (guix extensions bump)
  #:use-module (srfi srfi-1)
  #:export (guix-nightly))

(define-command (guix-nightly . args)
  (category extension)
  (synopsis "bump every channel, pull, reconfigure system and home, power off")
  ;; Only our own options, not the build options after `--'.
  (define own (take-while (lambda (arg) (not (string=? arg "--"))) args))
  (if (or (member "-h" own) (member "--help" own))
      (begin
        (display "Usage: guix nightly [--screen-on] [-- BUILD-OPTION...]
Short for: guix bump all --system --home --yes --gc --log --shutdown --screen-off

Asks for the sudo password once at the start, then turns the screens off:
they come on when you move the mouse or press a key, and go off again after
a minute without input.  --screen-on keeps them on.

Everything is also written to a log in ~/.local/state/guix-bump.  If any
step fails, the computer stays on and the error stays on screen.  Add
--dry-run to see which pins would move.
")
        (exit 0))
      (let ((screen-on? (member "--screen-on" own))
            (options (remove (lambda (arg) (string=? arg "--screen-on")) own))
            (build-options (drop args (length own)))) ;"--" and after
        (apply guix-bump "all" "--system" "--home" "--yes" "--gc" "--log"
               "--shutdown"
               (append (if screen-on? '() '("--screen-off"))
                       options build-options)))))
