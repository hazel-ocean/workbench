# Workspace management commands.
#
# A "Workspace" is a direct subdirectory of the workspaces root. Inside a
# workspace you clone the repos needed for a given task (e.g. a Linear ticket)
# and operate on all of them at once.
#
# Typical flow:
#   workspace new ENG-123 web-app api-service          # create + clone
#   workspace in-each {|| git fetch origin main:main; git rebase main --autostash}
#   workspace in-each {|| git checkout -b eng-123-fix}
#   workspace list
#
# Reload after editing these files:
#   workspace use

# Utility commands live in util.nu. Plain `use` (not `export use`) keeps them
# out of the public `workspace` overlay. `path self` mirrors mod.nu so the path
# resolves regardless of the caller's cwd.
const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *
export use zellij.nu *

# Print the absolute path of the workspaces root
export def root []: nothing -> path {
  $env.WORKSPACES_ROOT
}

# List all workspaces (meta home first) with each repo's branch and status
#
# The `state` column reports the saved Zellij session's status (active / exited
# / gone), or is empty when no session is saved. See `session-state`.
#
# Orphan Zellij sessions, live sessions owned by no workspace, are mixed in as
# rows with a null `workspace` and no repos, so `list` surfaces every session,
# not just workspace-associated ones. See `orphan-sessions`.
#
# Rows sort case-insensitively by their identifying name: a workspace by its
# name, an orphan by its session name. The `key` column is internal, dropped
# before returning.
export def list []: nothing -> table {
  let sessions = (zellij-sessions)
  let home = (workspace-home)
  let rows = (workspace-names | each {|name|
    let saved = (read-session-name (workspace-dir $name))
    let state = (if ($saved | is-not-empty) { session-state $saved $sessions })
    {
      key: $name
      workspace: $name
      session: (if ($saved | is-not-empty) { paint-state $saved $state ($name == $home) })
      state: $state
      repos: (workspace-repos $name | each {|r| repo-summary $r })
    }
  })
  let orphans = (orphan-sessions --sessions $sessions | each {|s|
    {
      key: $s.name
      workspace: $"(ansi dark_gray)\(orphan\)(ansi reset)"
      session: (paint-state $s.name $s.state false)
      state: $s.state
      repos: []
    }
  })
  $rows ++ $orphans | sort-by --ignore-case key | reject key
}

# Summarize a workspace: name, path, saved Zellij session, and repos
#
# Defaults to the current workspace; pass --choose to pick one.
export def info [
  --choose (-c)   # Pick a workspace interactively instead of using the current one
]: nothing -> record {
  let name = (select-workspace $choose)
  let dir = (workspace-dir $name)
  let saved = (read-session-name $dir)
  {
    workspace: $name
    path: $dir
    session: $saved
    state: (if ($saved | is-not-empty) { session-state $saved (zellij-sessions) })
    repos: (workspace-repos $name | each {|r| repo-summary $r })
  }
}

# Create a new workspace and cd into it, optionally cloning repos
export def --env new [
  name: string       # Workspace directory name
  ...repos: string   # Repos to clone immediately: [<org>/]<repo>[@<tag|branch> | #<pr>]
  --full             # Clone complete history and all blobs instead of a shallow blobless clone
]: nothing -> nothing {
  let dir = ($env.WORKSPACES_ROOT | path join $name)
  if ($dir | path exists) {
    print $"(ansi yellow)workspace ($name) already exists(ansi reset)"
  } else {
    mkdir $dir
    print $"(ansi green)created workspace ($name)(ansi reset)"
  }
  cd $dir
  if not ($repos | is-empty) {
    clone ...$repos --full=$full
  }
}

# cd into an existing workspace, matched by name or partial
#
# The argument is matched case-insensitively: an exact name wins outright,
# otherwise every workspace whose name contains the substring is a candidate.
# More than one candidate, or omitting the name entirely, opens a picker;
# a query that matches nothing falls back to a picker over all workspaces.
#
#   workspace attach ENG-123   # exact
#   workspace attach sms       # substring; picks if more than one matches
#   workspace attach           # pick interactively
#
# If the workspace has a saved Zellij session (see `workspace zellij attach`),
# you're attached to it after attaching.
#
# The picker also offers orphan Zellij sessions (live sessions owned by no
# workspace). Picking one attaches to it in place, with no cd, since an orphan
# has no workspace directory to enter.
export def --env attach [
  name?: string   # Workspace name or partial; omit to choose interactively
]: nothing -> nothing {
  let sel = (select-workspaces $name --prompt "Attach to:" --color-state --with-orphans)
  if ($sel | is-empty) {
    print "Nothing selected."
    return
  }
  let name = ($sel | first)
  # An orphan session isn't a workspace: attach to it without cd'ing anywhere.
  if $name not-in (workspace-names) {
    zellij-attach-existing $name
    return
  }
  let dir = (workspace-dir $name)
  cd $dir
  let saved = (read-session-name $dir)
  if $saved != null {
    zellij-attach $dir $saved
  }
}

# cd into an existing workspace without attaching to Zellij
#
# Same matching and display as `workspace attach`, but does not attach to
# the workspace's Zellij session (if one exists).
#
#   workspace enter ENG-123   # exact
#   workspace enter sms       # substring; picks if more than one matches
#   workspace enter           # pick interactively
export def --env enter [
  name?: string   # Workspace name or partial; omit to choose interactively
]: nothing -> nothing {
  let sel = (select-workspaces $name --prompt "Enter workspace:" --color-state)
  if ($sel | is-empty) {
    print "Nothing selected."
    return
  }
  let name = ($sel | first)
  let dir = (workspace-dir $name)
  cd $dir
}

# Rename a workspace's Zellij session, or reconcile a rename made in Zellij itself
#
# Thin top-level alias for `workspace zellij rename`; see there for details.
export def --env rename [
  new?: string              # New session name; omit to reconcile only
  --choose (-c)             # Pick a workspace interactively instead of using the current one
]: nothing -> nothing {
  zellij rename $new --choose=$choose
}

# Permanently delete workspaces and everything inside them
#
# Pass a name or partial, or omit it to pick from all. An exact name or unique
# substring resolves directly; anything ambiguous (or a no-match fall back to
# all) opens a fuzzy multi-select. Unless --force is given, the selection's
# contents are listed (including hidden files, flagging uncommitted work) and
# confirmed first. This is irreversible; use `workspace trash` to keep the
# directories recoverable.
#
#   workspace delete ENG-123          # exact
#   workspace delete sms              # substring; multi-select if ambiguous
#   workspace delete                  # pick from all
#   workspace delete --force ENG-123  # no confirmation
export def --env delete [
  query?: string   # Workspace name or partial; omit to choose interactively
  --force (-f)     # Skip the confirmation prompt
]: nothing -> nothing {
  remove-workspaces $force false $query
}

# Move workspaces to the system trash (recoverable)
#
# Like `workspace delete`, but routes through the OS trash so the directories
# can be restored later. Selection, contents preview, and --force behave the
# same as `delete`.
#
#   workspace trash ENG-123           # exact
#   workspace trash sms               # substring; multi-select if ambiguous
#   workspace trash                   # pick from all
#   workspace trash --force ENG-123   # no confirmation
export def --env trash [
  query?: string   # Workspace name or partial; omit to choose interactively
  --force (-f)     # Skip the confirmation prompt
]: nothing -> nothing {
  remove-workspaces $force true $query
}

# Shared implementation for `delete` / `trash`.
#
# Resolves targets via `select-workspaces` (which handles the picker, the
# contents preview, and the confirmation when not forced), steps out of any
# target the shell is sitting in, then removes each directory, via the system
# trash when `trash` is set.
def --env remove-workspaces [
  force: bool           # Skip the confirmation prompt
  trash: bool           # Move to the system trash instead of deleting permanently
  query?: string        # Workspace name or partial; omit to pick interactively
]: nothing -> nothing {
  let verb = if $trash { "trash" } else { "delete" }
  let targets = if $force {
    select-workspaces $query --multi --prompt $"Workspaces to ($verb):"
  } else {
    select-workspaces $query --multi --confirm --list-contents --prompt $"Workspaces to ($verb):"
  }

  if ($targets | is-empty) {
    print "Nothing selected."
    return
  }

  # If the shell is sitting inside a target we'll actually remove, step back to
  # the root so we don't strand the session in a deleted directory. The meta home
  # is never removed, so it doesn't count.
  let removed = ($targets | where {|t| $t != (workspace-home)})
  let current = (try-infer-workspace)
  if $current != null and ($current in $removed) {
    cd $env.WORKSPACES_ROOT
  }

  for name in $targets {
    let dir = (workspace-dir $name)
    # Read the saved session before removing the dir; the file lives inside it.
    let saved = (read-session-name $dir)
    # The meta home's repo is never removed, only its session and saved name.
    if $name == (workspace-home) {
      remove-session-name $dir
      let note = if $saved != null {
        if $trash { zellij-kill-session $saved } else { zellij-delete-session $saved }
        let did = if $trash { "killed" } else { "deleted" }
        $"Zellij session '($saved)' ($did)"
      } else {
        "no Zellij session"
      }
      print $"(ansi yellow)($name): repo preserved; ($note)(ansi reset)"
      continue
    }
    if $trash {
      rm --recursive --trash $dir
      print $"(ansi yellow)trashed ($name)(ansi reset)"
    } else {
      rm --recursive --force $dir
      print $"(ansi red)deleted ($name)(ansi reset)"
    }
    # `trash` leaves the session resurrectable to match the recoverable dir;
    # `delete` removes it entirely.
    if $saved != null {
      if $trash { zellij-kill-session $saved } else { zellij-delete-session $saved }
    }
  }
}

# Parse a repo spec into a clone slug and an optional ref to check out.
#
# Accepted forms (org defaults to $env.WORKSPACES_GH_ORG when omitted):
#   <repo>                 <org>/<repo>
#   <repo>@<ref>           <org>/<repo>@<ref>    ref = tag or branch
#   <repo>#<pr>            <org>/<repo>#<pr>     pr  = PR number
#
# The ref begins at the first `@` or `#`; everything before it is the
# `[<org>/]<repo>` name. Splitting there (rather than on `/`) keeps branch names
# that contain slashes intact. Returns { slug, ref: "@<ref>" | "#<pr>" | null }.
def parse-repo-spec [spec: string]: nothing -> record {
  let sigils = ([($spec | str index-of "@") ($spec | str index-of "#")]
    | where {|i| $i >= 0 })
  let cut = if ($sigils | is-empty) { null } else { $sigils | math min }
  let name = if $cut == null { $spec } else { $spec | str substring 0..<$cut }
  let ref = if $cut == null { null } else { $spec | str substring $cut.. }
  let slug = if ($name | str contains "/") {
    $name
  } else {
    let org = $env.WORKSPACES_GH_ORG?
    if ($org | is-empty) {
      error make {
        msg: $"No default org for bare repo '($name)'. Set WORKSPACES_GH_ORG in .env \(or the environment\), or qualify the repo as <org>/($name)."
      }
    }
    $"($org)/($name)"
  }
  { slug: $slug, ref: $ref }
}

# Check out a ref inside a freshly cloned repo. `@<name>` is a tag or branch
# (git checkout handles both, DWIM-tracking a remote branch); `#<num>` is a PR
# checked out via `gh pr checkout` from within the repo.
def checkout-ref [repo: path, ref: string]: nothing -> nothing {
  let value = ($ref | str substring 1..)
  if ($ref | str starts-with "#") {
    print $"(ansi green)checkout PR #($value)(ansi reset)"
    do { cd $repo; ^gh pr checkout $value }
  } else {
    print $"(ansi green)checkout ($value)(ansi reset)"
    ^git -C $repo checkout $value
  }
}

const CLONE_HISTORY_WINDOW = 90day

# Clone one repo, truncating history to the last $CLONE_HISTORY_WINDOW.
#
# `--filter=blob:none` skips file contents that only exist in history, so a
# large blob committed and later reverted is never downloaded. Blobs the
# checkout needs still come down during the clone, and anything else is fetched
# on demand, so reading old file contents offline is the one thing that breaks.
#
# `--no-single-branch` keeps every branch tip fetched so a later `@<ref>` or
# `#<pr>` checkout resolves. `--shallow-since` is a hard error when the remote
# has no commits in the window, so fall back to full history in that case.
def clone-repo [slug: string, target: path, full: bool]: nothing -> nothing {
  if $full {
    ^gh repo clone $slug $target
    return
  }
  let since = ((date now) - $CLONE_HISTORY_WINDOW | format date "%Y-%m-%d")
  try {
    (^gh repo clone $slug $target --
      $"--shallow-since=($since)"
      --no-single-branch
      --filter=blob:none)
  } catch {
    if ($target | path exists) { rm -rf $target }
    print $"(ansi yellow)no history since ($since); cloning full history(ansi reset)"
    ^gh repo clone $slug $target -- --filter=blob:none
  }
}

# Clone repos into a workspace via `gh` (defaults to the current workspace)
#
# Each repo is `[<org>/]<repo>[<ref>]`. A bare name is resolved against
# $env.WORKSPACES_GH_ORG; prefix `owner/` to override the org. An optional
# trailing ref checks out after cloning: `@<tag-or-branch>` or `#<pr-number>`.
#
# Clones are shallow and blobless by default: the last 90 days of history, and
# file contents only for what's checked out. Pass --full for a complete clone.
#
#   workspace clone web-app
#   workspace clone other-org/web-app
#   workspace clone web-app@v1.2.3        # tag or branch
#   workspace clone web-app#1234          # PR number
#   workspace clone other-org/web-app@my-branch
#   workspace clone web-app --full        # complete history
export def clone [
  ...repos: string  # Repos to clone: [<org>/]<repo>[@<tag|branch> | #<pr>]
  --choose (-c)     # Pick a target workspace interactively instead of using the current one
  --full            # Clone complete history and all blobs instead of a shallow blobless clone
]: nothing -> nothing {
  let name = (select-workspace $choose)
  if $name == (workspace-home) {
    error make { msg: "Cannot clone into the meta workspace; pick a real workspace." }
  }
  let dir = (workspace-dir $name)
  if not ($dir | path exists) {
    error make {
      msg: $"Workspace '($name)' does not exist. Create it with `workspace new`."
    }
  }
  if ($repos | is-empty) {
    error make { msg: "No repos given. Usage: workspace clone <repo>..." }
  }
  for repo in $repos {
    let parsed = (parse-repo-spec $repo)
    let slug = $parsed.slug
    let target = ($dir | path join ($slug | path basename))
    if ($target | path exists) {
      print $"(ansi yellow)skip ($slug) \(already cloned\)(ansi reset)"
      continue
    }
    let suffix = if $parsed.ref != null { $" ($parsed.ref)" } else { "" }
    print $"(ansi green)clone ($slug)($suffix)(ansi reset)"
    clone-repo $slug $target $full
    if $parsed.ref != null {
      checkout-ref $target $parsed.ref
    }
  }
}

# Run `git diff --color=always ...args` inside each repo of a workspace
#
# Returns a `repo`/`diff` table; `in-each`'s generic `result` column is renamed
# so `| get diff` reads naturally. Built by hand rather than with `rename`, which
# this module shadows with its own `rename` command.
#
# The def is `--wrapped`, so any unrecognized flags, revisions, and paths pass
# straight through to `git diff` (only --choose/--parallel are consumed here):
#   workspace diff
#   workspace diff --cached
#   workspace diff HEAD~1 -- src/
export def --wrapped diff [
  ...args: string   # Extra arguments forwarded to `git diff`
  --choose (-c)     # Pick a workspace interactively instead of using the current one
  --parallel (-p)   # Run repos concurrently
]: nothing -> table {
  # `--wrapped` forwards --help into $args, so handle it ourselves.
  if ("--help" in $args) or ("-h" in $args) { print (help workspace diff); return }
  (in-each --choose=$choose --parallel=$parallel {|| ^git diff --color=always ...$args }
    | each {|row| { repo: $row.repo, diff: $row.result } })
}

# Run a closure inside each repo of a workspace
#
# The closure runs with the repo directory as the working directory, so git
# and other tools operate on that repo. Defaults to the current workspace.
#
#   workspace in-each {|| git fetch origin main:main; git rebase main --autostash}
#   workspace in-each --parallel {|| ^git status --short}
export def "in-each" [
  action: closure   # Closure run inside each repo (cwd = repo)
  --choose (-c)     # Pick a workspace interactively instead of using the current one
  --parallel (-p)   # Run repos concurrently
]: nothing -> table {
  let name = (select-workspace $choose)
  let repos = (workspace-repos $name)
  if ($repos | is-empty) {
    error make { msg: $"No git repos found in workspace '($name)'." }
  }
  let runner = {|repo|
    let name = ($repo | path basename)
    let result = do { cd $repo; do $action }
    { repo: $name result: $result }
  }
  if $parallel {
    $repos | par-each $runner
  } else {
    $repos | each $runner
  }
}
