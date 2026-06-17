# Workspace overlay

Nushell commands for per-task workspaces — one dir per Linear ticket, with the
repos you need cloned inside, and pipelines to run commands across all of them.

A *workspace* is a subdirectory of `$env.WORKSPACES_ROOT` (defaults to
`./workspaces/`); a *repo* is a `.git`-containing subdirectory of a workspace.

Requires [`mise`](https://mise.jdx.dev) and [`gh`](https://cli.github.com);
`mise` will install Nushell on first run.

## Getting started

```sh
mise run shell    # Nushell with the overlay loaded
```

Or load by hand:

```nu
overlay use mod.nu as workspace
workspace use                    # reload after editing a .nu file
help workspace                   # list commands
```

## Commands

```nu
workspace new ENG-123 web-app api-service            # create + cd + clone
workspace clone some-repo                            # clone into current workspace
workspace clone other-org/their-repo                 # override the default org
workspace switch ENG-123                             # cd into a workspace
workspace zellij                                     # attach to / create a zellij session for the workspace
workspace list                                       # all workspaces, with each repo's branch + status
workspace root                                       # workspaces root path
```

Run a closure in every repo of the current workspace (cwd = repo, returns a
`{repo, result}` table):

```nu
workspace in-each {|| git fetch origin main:main; git rebase main --autostash}
workspace in-each --parallel {|| ^git status --short}
workspace in-each --choose {|| ^git rev-parse --abbrev-ref HEAD}
workspace diff --cached          # shorthand for `in-each {|| git diff ...}`
```

Most commands default to the current workspace (inferred from `$env.PWD`).
Pass `--choose` (`-c`) to pick a different one from a list instead.

## Configuration

|Env var            |Default              |Purpose                                |
|-------------------|---------------------|---------------------------------------|
|`WORKSPACES_ROOT`  |`./workspaces/`      |Where workspaces live (set by `mod.nu`)|
|`WORKSPACES_GH_ORG`|`.github/default-org`|Org prepended to bare repo names       |
