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
| `guix nightly` | update everything, apply system and home, clean up, power off |

`guix bump --help` has every option.

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
- If the config is in a git repository, each change is committed and pushed.

## Settings

For a config laid out differently, say where things are (in the window:
menu, *Settings*):

| Key | Meaning | Default |
|---|---|---|
| `config` | the config file | `~/config.scm` |
| `packages` | the variable holding the list of package names | `%managed-packages`, else `%apps` |
| `channels` | the variable holding the channels; only channels in its definition are updated | every channel in the file |

```sh
guix bump --set config=~/dotfiles/guix.scm packages=%my-packages channels=%my-channels
guix bump --settings
```

They are kept in `~/.config/guix-manager/settings`. The environment variable
`GUIX_BUMP_CONFIG`, when set, comes before the `config` setting.

## Limits

- Updating an app moves the pin of the channel it comes from, so the other
  apps of that channel move too. For Guix itself that is every package; you
  are asked first.
- A version can only be chosen among those the pinned Guix has.
- Installing and removing apply to the home environment, not the system.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
