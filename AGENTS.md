# AGENTS.md

Notes for whoever works on this repository, human or coding agent. The
README is for users; [ARCHITECTURE.md](ARCHITECTURE.md) says how the pieces
fit and why. Read that first.

## Layout

- `extensions/guix/extensions/bump.scm`: `guix bump`. All logic lives here.
- `extensions/guix/extensions/nightly.scm`: `guix nightly`, one call into
  `bump.scm`.
- `guix-manager`: the window (one Python file, no extension, executable).
- `data/`: the desktop entry.
- `tests/`: `run.sh` and the Scheme tests of the text edits and settings.

## Rules

- **The config is the only description of the machine.** Never add a path
  that installs something without writing it into the config first, and
  never leave the config changed after a failed apply.
- **The window holds no Guix logic.** A new feature is a `guix bump` option
  (with `--porcelain` output if the window reads it) plus a button that runs
  it. If you are writing Guix knowledge in Python, stop.
- **Edit the config as text.** Never evaluate it to change it, never
  reformat it, keep the user's comments. Every text edit needs a test in
  `tests/edit.scm`, including the awkward cases (first element, last element
  after a comment, empty list).
- **Porcelain is a contract** (table in ARCHITECTURE.md). Add fields at the
  end; update the table and the window together.
- **Say what was tested.** Applying (`--home`, `--system`, `--install`,
  `--remove`) changes the machine: do not run those on the owner's real
  config to test. Test up to the apply (dry runs, the tests, a scratch
  config), say that the apply itself was not run, and leave it to the owner.
- **Commits:** a plain description of the change. No tool or AI attribution
  of any kind, in commit messages, PR text or files. Commit with the
  identity configured in the repository (a GitHub no-reply address).

## Working on it

```sh
# The commands, from this checkout:
export GUIX_EXTENSIONS_PATH=$PWD/extensions
guix bump --help

# Against a scratch copy of a config, with scratch settings:
export GUIX_BUMP_CONFIG=/tmp/scratch/config.scm XDG_CONFIG_HOME=/tmp/scratch
guix bump -n all            # -n: show which pins would move, change nothing

# The tests:
sh tests/run.sh
```

The window needs GTK 4, libadwaita, VTE and PyGObject; the simplest way to
get them is the environment of the packaged app:

```sh
guix shell python python-pygobject gtk libadwaita vte gobject-introspection \
     -- env GUIX_EXTENSIONS_PATH=$PWD/extensions ./guix-manager
```

Pitfalls met so far:

- A shell started by another graphical app may have `LD_LIBRARY_PATH` set; a
  second GLib then breaks PyGObject ("doesn't support property"). Unset it.
- In this Guix, `package-channels` lists `guix` for every package; the
  package's own channel is any other one it names.
- `specification->package`-style lookup by name returns the newest package
  of that name, which is not always the one a config uses (`node` versus an
  LTS variable). That is why `--check` evaluates the config instead.
- `guix repl FILE` runs a script with Guix's modules; `(load* FILE
  '((guix profiles) (gnu)))` evaluates a config as `guix home` does, and the
  config can branch on `(command-line)`, which the script sets.
- The placeholders `@GIT@` and `@BASH@` in `bump.scm` are replaced by store
  file names when packaged; unreplaced, it falls back to `git` and `sh` from
  `PATH`.

## Packaging

The hyperguix channel packages this repository at a pinned commit as
`guix-bump` (the extensions) and `guix-manager` (the window, wrapped with
its typelibs and with `GUIX_EXTENSIONS_PATH` pointing at `guix-bump`). Its
automatic updates follow `main`: every push here becomes an update there, so
keep `main` working. The version is the `%version` in `bump.scm` and
`VERSION` in `guix-manager`; bump both together.
