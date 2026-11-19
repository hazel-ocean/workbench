# Workspace overlay

Nushell commands for per-task workspaces — one dir per Linear ticket, with the
repos you need cloned inside, and pipelines to run commands across all of them.

A *workspace* is a subdirectory of the workspaces root (defaults to
`./workspaces/`), or a directory listed in `extra-workspace-dirs`;
a *repo* is a `.git`-containing subdirectory of a workspace.

Requires [`mise`](https://mise.jdx.dev) and [`gh`](https://cli.github.com);
`mise` will install Nushell on first run.

## Getting started

```sh
mkdir -p ~/.config/workbench
cp config.example.toml ~/.config/workbench/config.toml   # then set your default GitHub org
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
workspace new ABC-123 web-app api-service            # create + cd + clone
workspace clone some-repo                            # clone into current workspace
workspace clone other-org/their-repo                 # override the default org
workspace clone their-repo=alt                       # clone into a named directory
workspace attach api                                 # cd into a workspace (name/partial; picker if ambiguous or omitted)
workspace delete api                                 # permanently remove (fuzzy multi-select + contents preview + confirm)
workspace trash api                                  # same, but route through the system trash (recoverable)
workspace zellij attach                              # attach to / create a zellij session for the workspace
workspace list                                       # all workspaces, with zellij session
workspace info                                       # one workspace: session, repos, metadata
workspace disk-usage                                 # dua size of every workspace, with per-repo sizes (alias: wdu)
workspace metadata                                   # edit this workspace's metadata in $EDITOR
workspace root                                       # workspaces root path
workspace secrets copy                               # copy gitignored files in from secrets/
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

## Workspace metadata

A `.workspace.meta.<format>` file at a workspace root holds whatever context
the repos cannot show: the ticket, the thread, the notes. `workspace info`
reports it as `metadata`.

`workspace metadata` opens that file in `$EDITOR` (falling back to `$VISUAL`),
seeding a commented `.workspace.meta.yaml` when the workspace has none. An
untouched seed is all comments, so it parses as no metadata until you fill in.

```yaml
# workspaces/ABC-123/.workspace.meta.yaml
linear-url: https://linear.app/acme/issue/ABC-123
things-link: things:///show?id=ABC123
obsidian-link: "[Feature notes](obsidian://open?vault=Notes&file=Projects/feature)"
slack-url: "[Rollout thread](https://acme.slack.com/archives/C0123/p1700000000)"
```

The extension picks the parser, so any format Nushell's `open` infers works:
`.yaml`, `.yml`, `.toml`, `.json`, `.nuon`. The whole name is matched
case-insensitively, extension included.

```nu
workspace info | get metadata.linear-url
workspace info -c | get metadata | transpose key value
```

The keys are yours; nothing validates them. A format Nushell cannot parse
reads as text. A workspace with no metadata gets no `metadata` field at all,
so use `get metadata?` when a workspace may not have one.

### Links

A key ending in `-link`, `-url` or `-uri`, or named just `link`/`url`/`uri`, is
rendered as a clickable hyperlink, at any depth and through lists. Two forms:

|Value                   |Shows      |
|------------------------|-----------|
|`https://example.com`   |the URI    |
|`[some text](https://…)`|`some text`|

A labelled link is painted blue, since the label hides where it points; a bare
URI is left plain. The key is the opt-in, so `slack-thread` stays text while
`slack-url` becomes a link, and nothing checks that the value is really a URI.

This exists because terminals auto-detect only the schemes on their own
allowlist. Ghostty's list has no `things:` or `obsidian:`, so those are never
clickable as plain text; an explicit hyperlink skips that matcher and the URI
goes to the system handler on a click.

## Secrets

`secrets/` at the workbench root holds gitignored files for cloned repos:
`.env` variants, keys, certificates. Git ignores the directory itself.

```
secrets/acme/api-service/.env.staging          →  api-service/.env.staging
secrets/acme/api-service/extra/key.pem         →  api-service/extra/key.pem
```

The first two levels are the GitHub org and repo, matched against the clone's
`origin` without regard to case. A clone in a renamed directory still finds its
files. The rest of the path is where the file lands in the repo.

`workspace secrets copy` lists the files for every repo in the workspace, or
for one with `--repo`. Each file you pick gets a one-key prompt:

|Key          |Action                                            |
|-------------|--------------------------------------------------|
|Enter or `y` |Copy as is                                        |
|`p`          |Print the file, then ask again                    |
|`r`          |Rename, as when `.env.staging` should land as `.env`|
|`n` or Esc   |Skip                                              |

The copy is verbatim, file mode included.

- A destination git tracks is never replaced, and is not offered.
- An identical existing file is reported `unchanged`, and is not offered.
- A destination that is not gitignored asks first, since git would offer to
  commit it.
- An existing file that differs asks before it is overwritten.

`workspace clone` shows the same picker after each clone that has files in the
store. Press Esc to skip it. It does not appear when stdin is no terminal, so a
scripted clone never blocks.

## Configuration

Settings live in `~/.config/workbench/config.toml`, or under
`$XDG_CONFIG_HOME` when it is set. `config.example.toml` is a starting point.
Every key is optional, and a missing file means every default.

|Key                   |Default        |Purpose                         |
|----------------------|---------------|--------------------------------|
|`workspaces-root`     |`./workspaces/`|Where workspaces live           |
|`default-github-org`  |unset          |Org prepended to bare repo names|
|`secrets-root`        |`./secrets/`   |Where `workspace secrets` reads |
|`extra-workspace-dirs`|`[]`           |Extra workspaces                |
|`new.clone`           |`[]`           |Repos `workspace new` clones    |
|`new.template`        |unset          |Files `workspace new` offers    |

A path may start with `~`. A relative path resolves against the workbench repo
root. An unknown key or a value of the wrong type is an error. The file is read
on every command, so an edit applies without reloading the overlay.

Each entry in `extra-workspace-dirs` is one workspace, named by its basename. A
directory that is itself a repo, such as `~/.config/nix-config`, is a workspace
with one repo. A missing directory is skipped. Two entries with the same
basename, or one that matches a workspace under the root, are an error.

Without a `default-github-org`, qualify every repo as `<org>/<repo>`.

`workspace new` sets up each workspace under the root from the `new` table.
Running it on an existing workspace adds what is missing.

- It offers each file in the `new.template` directory for the workspace root,
  with the same prompt as `workspace secrets copy` and no picker. Without a
  terminal, it skips the template. A copy gains the owner's write bit, since a
  template in the Nix store is read-only.
- It clones the repos you name, then each repo in `new.clone`. A repo already
  in the workspace is skipped, so a ref you give for a `new.clone` repo wins.
- An extra workspace gets neither, only the repos you name.

Set `WORKBENCH_CONFIG` to read a different file for one command:

```nu
WORKBENCH_CONFIG=/tmp/scratch.toml workspace list
```

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
