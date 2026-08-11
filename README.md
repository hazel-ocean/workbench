# Workspace overlay

Nushell commands for per-task workspaces — one dir per Linear ticket, with the
repos you need cloned inside, and pipelines to run commands across all of them.

A *workspace* is a subdirectory of `$env.WORKBENCH_WORKSPACES_ROOT` (defaults to
`./workspaces/`); a *repo* is a `.git`-containing subdirectory of a workspace.

Requires [`mise`](https://mise.jdx.dev) and [`gh`](https://cli.github.com);
`mise` will install Nushell on first run.

## Getting started

```sh
cp .env.example .env    # then set your default GitHub org
mise run shell          # Nushell with the overlay loaded
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
workspace attach sms                                 # cd into a workspace (name/partial; picker if ambiguous or omitted)
workspace delete sms                                 # permanently remove (fuzzy multi-select + contents preview + confirm)
workspace trash sms                                  # same, but route through the system trash (recoverable)
workspace zellij attach                              # attach to / create a zellij session for the workspace
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

|Env var                        |Default        |Purpose                         |
|-------------------------------|---------------|--------------------------------|
|`WORKBENCH_WORKSPACES_ROOT`    |`./workspaces/`|Where workspaces live           |
|`WORKBENCH_DEFAULT_GITHUB_ORG` |unset          |Org prepended to bare repo names|

Loading the overlay sources `.env` from the repo root, which is untracked and
machine-local. Copy the example and edit it (`cp .env.example .env`) so bare
repo names resolve, or always qualify repos as `<org>/<repo>`. Variables already
set in your environment take precedence over `.env`.

Clones are shallow and blobless: the last 90 days of history, and file contents
only for what's checked out. Blobs that exist solely in history (an accidentally
committed snapshot, say) are never downloaded; anything the working tree needs
is. Reading historical file contents lazily fetches over the network, so `git
log -p` and `git blame` on old revisions need connectivity.

Pass `--full` to `workspace clone` or `workspace new` for a complete clone. To
promote an existing one in place, drop both config keys before refetching;
unsetting the filter alone leaves the remote marked as a promisor and objects
still missing:

```nu
git config --unset remote.origin.partialclonefilter
git config --unset remote.origin.promisor
git fetch --refetch --unshallow
```
