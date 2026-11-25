# Guix Manager

Day-to-day Guix without the ceremony: see what has a newer version, update
one app or everything, install and remove apps. Every change is written into
your Guix config file first and applied from it, so the file stays the one
description of your machine.

Two parts:

- **`guix bump`** and **`guix nightly`**, commands added to `guix`.
- **Guix Manager**, a window with *Updates*, *Install* and *Installed*
  pages. Each button runs a `guix bump` command in a terminal pane at the
  bottom of the window, so you see exactly what it does and can answer a
  password or yes/no question there.

It is for a setup where one config file holds pinned channels, a home
environment and a system (see
[FineConfig](https://github.com/Lightningbulb2/FineConfig) for a template).

## Install

With the [hyperguix](https://github.com/Lightningbulb2/hyperguix) channel,
add the packages `guix-bump` and `guix-manager` to your home environment.

To try a checkout without installing:

```sh
GUIX_EXTENSIONS_PATH=$PWD/extensions guix bump --help
```

## Commands

| Command | Does |
|---|---|
| `guix bump` | list channels: pinned, running and latest commit |
| `guix bump --check` | list the installed apps that have a newer version |
| `guix bump APP` | update that app now: move its channel's pin, pull, apply |
| `guix bump CHANNEL` / `all` | move one pin or every pin to the latest commit and pull |
| `guix bump --home` / `--system` | apply the config to your apps / to the system (sudo) |
| `guix bump --search WORD` | find packages by name or description |
| `guix bump --install NAME` | add it to the config's package list and apply |
| `guix bump --install NAME@VERSION` | install or keep a particular version |
| `guix bump --remove NAME` | take it out of the list and apply |
| `guix bump --installed` | list what your home has installed |
| `guix bump --undo` | put the pins back as they were before the last change |
| `guix bump --settings` / `--set KEY=VALUE` | which file and lists are used |
| `guix nightly` | update everything, apply system and home, clean up, power off; the screens stay off meanwhile (`--screen-on` keeps them on) |

`guix bump --help` has every option.

### Progress while building

Before applying, `guix bump` builds what the reconfigure needs itself and
shows one line for every build at once (Guix's own display shows a bar only
while a single build runs):

```
[ 41%] 3/14 built · craft-suite 44% · cosmic-suite build 12m · 2 downloading
```

The percentage weighs each build by how long it took the last time, so an
hour-long build counts for more than a one-minute one. Those times are kept
in `~/.local/state/guix-bump/build-times.scm`, first filled from the build
logs in `/var/log/guix/drvs`. A build's own percentage shows when it prints
one (CMake, Ninja, and the Rust packages of the hyperguix channel); for the
others the elapsed time is shown. In a log file (`--log`, `guix nightly`)
the line is written when a build starts or ends, and at most once a minute
otherwise. The reconfigure then finds everything built.

## What it expects in the config

- **Channels** written as `(channel ... (commit "..."))` forms. `guix bump`
  rewrites the commits; a channel with no `commit` gets one.
- **A list of packages** for `--install` and `--remove` to edit, which your
  home environment installs. Either a list of names:

  ```scheme
  (define %managed-packages
    '())
  ```

  with `(map specification->package %managed-packages)` among the home
  packages, or the list of package values you already have:

  ```scheme
  (define (%home-packages)
    (list firefox git ...))
  ```

  (`guix bump --set packages=%home-packages`). In such a list, variables
  and `(specification->package "NAME")` calls are understood; what is added
  is written as `(specification->package "NAME")`. Any other expression is
  shown but never edited.
- If the config is in a git repository, each change is committed and pushed
  (see *Keeping the config in git*).

## Settings

For a config laid out differently, say where things are (in the window:
menu, *Settings*):

| Key | Meaning | Default |
|---|---|---|
| `config` | the config file | `~/config.scm` |
| `packages` | the variable holding the list of package names | `%managed-packages`, else `%apps` |
| `channels` | the variable holding the channels; only channels in its definition are updated | every channel in the file |
| `git` | for a config in a git repository: `push` (commit each change and push it), `commit` (commit only) or `off` | `push` |
| `git-remote` | where changes are pushed: the config repository's `origin` (empty removes it) | as the repository has it |
| `git-name`, `git-email` | who the commits are by: the repository's `user.name` / `user.email` | your global git settings |

```sh
guix bump --set config=~/dotfiles/guix.scm packages=%my-packages channels=%my-channels
guix bump --settings
```

They are kept in `~/.config/guix-manager/settings`. The environment variable
`GUIX_BUMP_CONFIG`, when set, comes before the `config` setting.

## The window

- The bar at the top: **Update apps** (newest versions, applied to your
  home: no password, no logout), **Update system** (the same for the
  system, with your password), **Apply apps** / **Apply system** (the config
  file as it is now, after you edited it by hand).
- **Updates**, **Install**, **Installed**: one app at a time.
- Every button runs a `guix bump` command in the terminal pane; hover a
  button to see the command it runs.
- The strip under the buttons always shows what is running (or what
  happened last), its current step and latest line, the time so far and a
  bar, which shows how far the build is while `guix bump` builds.
  **Cancel** stops it as Ctrl-C would; a command stopped halfway
  switches nothing and puts the config file back.
- Drag the line above the terminal to give it more or less room (menu:
  show or hide it).
- The folder button opens the folder of your config file.

## Keeping the config in git

Optional, and worth it: the repository's history becomes the history of the
machine, and a broken change is one `git revert` away.

1. Put the config in a repository, and make `~/config.scm` a link to it (or
   set `config` to its path):

   ```sh
   mkdir ~/my-guix && mv ~/config.scm ~/my-guix/ && cd ~/my-guix
   git init && git add config.scm && git commit -m "My Guix config"
   ln -s ~/my-guix/config.scm ~/config.scm
   ```

2. To keep a copy online, add a remote you can push to without a password
   prompt (with GitHub's `gh`: `gh repo create my-guix --private --source .
   --push`, then `gh auth setup-git`).
3. Choose what happens on each change (window: *Settings*):
   `guix bump --set git=push` (the default; no remote, no push),
   `git=commit`, or `git=off`.

`guix bump` commits only the config file, with a message that says what
changed ("Bump guix e2a7a34 -> 30fa7fb", "Install hello"). A failed push
leaves the commit in place and says so; push later with `git push`.

## Limits

- Updating an app moves the pin of the channel it comes from, so the other
  apps of that channel move too. For Guix itself that is every package; you
  are asked first.
- A version can only be chosen among those the pinned Guix has.
- Installing and removing apply to the home environment, not the system.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
