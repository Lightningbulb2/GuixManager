;;; Tests of the text edits `guix bump' makes to a config file, and of the
;;; settings.  Run by tests/run.sh; exits non-zero on the first failure.

(use-modules (ice-9 match) (srfi srfi-1))

(define bump (resolve-module '(guix extensions bump)))
(define (f name) (module-ref bump name))

(define failures 0)
(define (check name got expected)
  (if (equal? got expected)
      (format #t "ok    ~a~%" name)
      (begin
        (set! failures (+ failures 1))
        (format #t "FAIL  ~a~%  got:      ~s~%  expected: ~s~%"
                name got expected))))

(define config "\
;; (channel (name 'commented) (url \"x\") (commit \"0\"))
(define %my-channels
  (list (channel
          (name 'guix)
          (url \"https://example.org/guix.git\")
          (branch \"master\")
          (commit \"aaaa\"))
        (channel
          (name 'extra)
          (url \"https://example.org/extra.git\"))))

(define %other
  (list (channel (name 'elsewhere) (url \"https://example.org/e.git\")
                 (commit \"cccc\"))))

(define %apps
  '(\"firefox\" \"git\"   ;browser, version control
    \"node@22.14.0\"))
")

;; Channels.
(check "every channel form, comments skipped"
       (map car ((f 'read-channels) config))
       '(guix extra elsewhere))
(check "pins"
       ((f 'pins) config)
       '((guix . "aaaa") (extra . #f) (elsewhere . "cccc")))
(check "set an existing pin"
       (assq-ref ((f 'pins) ((f 'set-pin) config 'guix "bbbb")) 'guix)
       "bbbb")
(check "add a pin where there was none"
       (assq-ref ((f 'pins) ((f 'set-pin) config 'extra "dddd")) 'extra)
       "dddd")

;; The `channels' setting limits the pins to one definition.
((f 'write-setting!) "channels" "%my-channels")
(check "channels setting"
       (map car ((f 'read-channels) config))
       '(guix extra))
((f 'write-setting!) "channels" "")
(check "channels setting cleared"
       (length ((f 'read-channels) config))
       3)

;; The package list.
(check "the list (default name %apps)"
       ((f 'managed-specs) config)
       '("firefox" "git" "node@22.14.0"))
(check "add"
       ((f 'managed-specs) ((f 'add-spec) config "hello"))
       '("firefox" "git" "node@22.14.0" "hello"))
(check "add keeps comments"
       (->bool (string-contains ((f 'add-spec) config "hello")
                                ";browser, version control"))
       #t)
(check "remove the first"
       ((f 'managed-specs) ((f 'remove-spec) config "firefox"))
       '("git" "node@22.14.0"))
(check "remove one with a version"
       ((f 'managed-specs) ((f 'remove-spec) config "node"))
       '("firefox" "git"))
(check "change a version"
       ((f 'managed-specs) ((f 'replace-spec) config "node"))
       '("firefox" "git" "node"))
(check "names are matched whole"
       ((f 'managed-specs) ((f 'remove-spec) config "fire"))
       '("firefox" "git" "node@22.14.0"))

(define lines "(define %apps\n  '(\"a\"\n    \"b\"\n    \"c\"))\n")
(check "remove one on its own line"
       ((f 'remove-spec) lines "b")
       "(define %apps\n  '(\"a\"\n    \"c\"))\n")
(check "remove the last after a comment keeps the list readable"
       ((f 'managed-specs)
        ((f 'remove-spec) "(define %apps\n  '(\"a\" ;note\n    \"b\"))\n" "b"))
       '("a"))

(define empty "(define %managed-packages\n  '())\n")
(check "add to an empty list"
       ((f 'add-spec) empty "hello")
       "(define %managed-packages\n  '(\"hello\"))\n")
(check "and back"
       ((f 'remove-spec) ((f 'add-spec) empty "hello") "hello")
       empty)

;; The `packages' setting names the list.
((f 'write-setting!) "packages" "%nope")
(check "packages setting, no such list"
       ((f 'managed-specs) config)
       #f)
((f 'write-setting!) "packages" "")
(check "settings file is empty again"
       ((f 'read-settings))
       '())

(exit (if (zero? failures) 0 1))
