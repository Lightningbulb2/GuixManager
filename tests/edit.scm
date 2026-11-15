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

(define values-config "\
(define (%home-packages)
  (list hello
        guix ;the package manager
        ;; a comment on its own line
        (specification->package \"node@22.14.0\")
        (list glib \"bin\")
        coreutils))
")
((f 'write-setting!) "packages" "(%home-packages)")
(check "a list of values: what is understood"
       ((f 'managed-specs) values-config)
       '("hello" "guix" "node@22.14.0" "coreutils"))
(check "values: remove the first"
       ((f 'remove-spec) values-config "hello")
       "\
(define (%home-packages)
  (list guix ;the package manager
        ;; a comment on its own line
        (specification->package \"node@22.14.0\")
        (list glib \"bin\")
        coreutils))
")
(check "values: remove one with its comment"
       ((f 'managed-specs) ((f 'remove-spec) values-config "guix"))
       '("hello" "node@22.14.0" "coreutils"))
(check "values: remove a specification"
       ((f 'managed-specs) ((f 'remove-spec) values-config "node"))
       '("hello" "guix" "coreutils"))
(check "values: remove the last"
       ((f 'managed-specs) ((f 'remove-spec) values-config "coreutils"))
       '("hello" "guix" "node@22.14.0"))
(check "values: what is not understood stays"
       (->bool (string-contains ((f 'remove-spec) values-config "coreutils")
                                "(list glib \"bin\")"))
       #t)
(check "values: add"
       ((f 'managed-specs) ((f 'add-spec) values-config "sed"))
       '("hello" "guix" "node@22.14.0" "coreutils" "sed"))
(check "values: an added one is written as a specification"
       (->bool (string-contains ((f 'add-spec) values-config "sed")
                                "\n        (specification->package \"sed\"))"))
       #t)
(check "values: keep a version of a variable"
       ((f 'managed-specs) ((f 'replace-spec) values-config "hello@2.10"))
       '("hello@2.10" "guix" "node@22.14.0" "coreutils"))
(check "values: every edit still reads as Scheme"
       (every (lambda (text)
                (->bool (false-if-exception
                         (call-with-input-string text read))))
              (list ((f 'remove-spec) values-config "hello")
                    ((f 'remove-spec) values-config "guix")
                    ((f 'remove-spec) values-config "coreutils")
                    ((f 'add-spec) values-config "sed")))
       #t)
((f 'write-setting!) "packages" "")

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

((f 'write-setting!) "git" "commit")
(check "git setting" ((f 'git-mode)) 'commit)
((f 'write-setting!) "git" "")
(check "git setting default" ((f 'git-mode)) 'push)

(exit (if (zero? failures) 0 1))
