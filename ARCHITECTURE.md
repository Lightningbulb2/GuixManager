# Architecture

## The one rule

The config file is the only description of the machine. Nothing is installed
imperatively and recorded afterwards: a change is an edit to the config,
then `guix pull` / `guix home reconfigure` / `guix system reconfigure` from
that file. If the apply fails, the edit is undone.

## Pieces

```
guix-manager (Python, GTK 4 + libadwaita + VTE)      the window
    |  runs, and reads the --porcelain output of
    v
extensions/guix/extensions/bump.scm                  `guix bump': all logic
extensions/guix/extensions/nightly.scm               `guix nightly': one call
    |  edits                |  runs
    v                       v
the user's config.scm       guix pull / home / system / time-machine / repl
```

`bump.scm` and `nightly.scm` are Guix extensions: any directory on
`GUIX_EXTENSIONS_PATH` that has `guix/extensions/NAME.scm` adds the command
`guix NAME`. They run inside the user's `guix` process, so they can use
Guix's modules (`(guix profiles)`, `(gnu packages)`, ...).

## The window decides nothing

`guix-manager` has no logic about Guix. It does two things:

- **Reads**: runs `guix bump --check|--search|--installed|--settings
  --porcelain` in the background and fills its lists from standard output.
- **Acts**: runs a `guix bump ...` command in its VTE terminal pane, exactly
  as a person would type it, and refreshes when it exits.

So the command line and the window cannot disagree, and everything the
window can do can be done, and debugged, from a shell.

### Porcelain protocol

With `--porcelain`, text for people goes to standard error and standard
output carries tab-separated lines, ending with `done`:

| First field | Other fields | From |
|---|---|---|
| `channel` | name, pinned commit, latest commit | `--check` |
| `package` | name, installed, newest, channel, `home`/`system`, `pulled`/`new` | `--check` |
| `result` | name, version, `installed`/`-`, synopsis | `--search` |
| `installed` | name, version, `list`/`config`, spec or `-`, versions (comma-separated) | `--installed` |
| `setting` | key, value (may be empty), what is in effect; `git-remote`, `git-name`, `git-email` are read from and written to the config's git repository | `--settings`, `--set` |

A missing `done` means the command failed. Add fields at the end only; the
window ignores lines it does not know.

## How `guix bump` treats the config

It never evaluates the config to edit it. It scans the text, skipping
comments and strings, for:

- `(channel ...)` forms: reads each with `read` to get name, URL and branch,
  and rewrites only the `(commit "...")` inside. With the `channels` setting
  the scan is limited to that variable's `(define ...)` form.
- the package list: either names, `(define NAME '("..." ...))`, or values,
  `(define (NAME) (list VARIABLE ... ))`. It finds the elements by
  position and adds, removes or replaces one, leaving formatting and
  comments alone. A variable is matched to a package name through a table
  of every public package variable of the running Guix (built on demand);
  an added element is written `(specification->package "NAME")`, which
  needs no module import.

Edits are written to a temporary file and renamed over the config, which is
resolved through symlinks first (its directory is where git runs).

## Flows

- **Bump** (`guix bump CHANNEL|all`): `git ls-remote` for each branch head,
  rewrite pins, `guix pull -C CONFIG`; on failure restore the file. The pins
  replaced are saved for `--undo`.
- **Check** (`--check`): versions are read by evaluating the config the way
  `guix home` and `guix system` do (a small script run with `guix repl`),
  once with the pulled Guix and, when a pin can move, once with the Guix of
  the latest commits via `guix time-machine -C` on a temporary copy of the
  config. That is exact (it sees the package the config really names) and
  costs what a pull costs the first time; afterwards it is cached by Guix.
- **Update one app** (`guix bump APP`): find its channel
  (`package-channels`, preferring any channel other than `guix`), bump that
  pin, pull, apply the home, or the system when the app is in the system
  profile.
- **Install / remove**: edit the package list, `guix home reconfigure`; on
  failure put the file back.
- **After applying**: compare the profile manifests from before and after
  to list version changes; look through `/proc` for programs still running
  from a replaced store item; compare `/run/booted-system/kernel` with
  `/run/current-system/kernel` to suggest a reboot.
- **Home inside the system**: when the config uses
  `home-with-system-service` (the system applies the home), `--system`
  alone covers the home.

## State

| Where | What |
|---|---|
| `~/.config/guix-manager/settings` | the settings (config, packages, channels, git); the git remote and identity live in the config's repository |
| `~/.local/state/guix-bump/previous-pins.scm` | pins before the last change, for `--undo` |
| `~/.local/state/guix-bump/*.log` | logs written with `--log` |
| `~/.local/state/guix-bump/check-*` | temporary files of `--check`, deleted afterwards |

## What is deliberately not here

- No daemon, no privileged helper: `sudo` is run in the terminal, by the
  command, when the system is applied.
- No package database of its own: search is `fold-packages` over the
  running Guix.
- No editing of packages the config names by variable. Rewriting arbitrary
  Scheme safely is not possible; those are shown read-only.
