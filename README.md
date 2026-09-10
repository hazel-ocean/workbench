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
workspace clone their-repo=alt                       # clone into a named directory
workspace attach sms                                 # cd into a workspace (name/partial; picker if ambiguous or omitted)
workspace delete sms                                 # permanently remove (fuzzy multi-select + contents preview + confirm)
workspace trash sms                                  # same, but route through the system trash (recoverable)
workspace zellij attach                              # attach to / create a zellij session for the workspace
workspace list                                       # all workspaces, with each repo's branch + status
workspace info                                       # one workspace: session, repos, metadata
workspace metadata                                   # edit this workspace's metadata in $EDITOR
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

## Workspace metadata

A `.workspace.meta.<format>` file at a workspace root holds whatever context
the repos cannot show: the ticket, the thread, the notes. `workspace info`
reports it as `metadata`.

`workspace metadata` opens that file in `$EDITOR` (falling back to `$VISUAL`),
seeding a commented `.workspace.meta.yaml` when the workspace has none. An
untouched seed is all comments, so it parses as no metadata until you fill in.

```yaml
# workspaces/ENG-123/.workspace.meta.yaml
linear-url: https://linear.app/onesignal/issue/ENG-123
things-link: things:///show?id=ABC123
obsidian-link: "[SMS module notes](obsidian://open?vault=OneSignal&file=Projects/sms-module)"
slack-url: "[Rollout thread](https://onesignal.slack.com/archives/C0123/p1700000000)"
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
