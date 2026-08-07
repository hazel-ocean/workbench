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
export def list []: nothing -> table {
  let sessions = (zellij-sessions)
  let home = (workspace-home)
  workspace-names | each {|name|
    let saved = (read-session-name (workspace-dir $name))
    let state = (if ($saved | is-not-empty) { session-state $saved $sessions })
    {
      workspace: $name
      session: (if ($saved | is-not-empty) { paint-state $saved $state ($name == $home) })
      state: $state
      repos: (workspace-repos $name | each {|r| repo-summary $r })
    }
  }
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
    clone ...$repos
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
export def --env attach [
  name?: string   # Workspace name or partial; omit to choose interactively
]: nothing -> nothing {
  let sel = (select-workspaces $name --prompt "Attach to:" --color-state)
  if ($sel | is-empty) {
    print "Nothing selected."
    return
  }
  let name = ($sel | first)
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
    $"($env.WORKSPACES_GH_ORG)/($name)"
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

# Clone repos into a workspace via `gh` (defaults to the current workspace)
#
# Each repo is `[<org>/]<repo>[<ref>]`. A bare name is resolved against
# $env.WORKSPACES_GH_ORG; prefix `owner/` to override the org. An optional
# trailing ref checks out after cloning: `@<tag-or-branch>` or `#<pr-number>`.
#
#   workspace clone web-app
#   workspace clone OneSignal/web-app
#   workspace clone web-app@v1.2.3        # tag or branch
#   workspace clone web-app#1234          # PR number
#   workspace clone OneSignal/web-app@my-branch
export def clone [
  ...repos: string  # Repos to clone: [<org>/]<repo>[@<tag|branch> | #<pr>]
  --choose (-c)     # Pick a target workspace interactively instead of using the current one
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
    ^gh repo clone $slug $target
    if $parsed.ref != null {
      checkout-ref $target $parsed.ref
    }
  }
}

# Run `git diff --color=always ...args` inside each repo of a workspace
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
  in-each --choose=$choose --parallel=$parallel {|| ^git diff --color=always ...$args }
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
