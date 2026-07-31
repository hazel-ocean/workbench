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
const UTIL = path self | path dirname | path join "util.nu"
use $UTIL *

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
  workspace-names | each {|name|
    let saved = (read-session-name (workspace-dir $name))
    {
      workspace: $name
      session: $saved
      state: (if ($saved | is-not-empty) { session-state $saved $sessions })
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
  ...repos: string   # Repos to clone immediately (name or owner/name)
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

# Attach to (or create) a Zellij session for a workspace
#
# The session name is remembered in `.zellij_session` at the workspace root. The
# first time (no saved name) you're prompted, prefilled with the workspace name.
# Press Enter to accept or type a replacement. Later runs reuse the saved name
# silently. If Zellij rejects a name you're re-prompted. Use `workspace zellij
# delete` to forget the saved name and optionally delete the session.
export def zellij [
  --choose (-c)             # Pick a workspace interactively instead of using the current one
]: nothing -> nothing {
  let name = (select-workspace $choose)
  let dir = (workspace-dir $name)
  let saved = (read-session-name $dir)
  if $saved != null {
    zellij-attach $dir $saved
  } else {
    zellij-attach $dir $name --prompt
  }
}

# Forget a workspace's saved Zellij session, optionally deleting the session too
#
# Removes the `.zellij_session` file, then, if a matching session exists,
# prompts to delete it entirely (killed if running, resurrectable state dropped).
#
#   workspace zellij delete        # current workspace
#   workspace zellij delete -c     # pick one
export def "zellij delete" [
  --choose (-c)             # Pick a workspace interactively instead of using the current one
]: nothing -> nothing {
  let name = (select-workspace $choose)
  let dir = (workspace-dir $name)
  let saved = (read-session-name $dir)
  let session = ($saved | default $name)
  remove-session-name $dir
  if $saved != null { print $"(ansi yellow)forgot saved session '($saved)'(ansi reset)" }
  if (zellij-session-exists $session) {
    let answer = (["no" "yes"] | input list $"Delete Zellij session '($session)' entirely?")
    if $answer == "yes" {
      zellij-delete-session $session
      print $"(ansi red)deleted Zellij session '($session)'(ansi reset)"
    }
  } else {
    print $"No Zellij session '($session)' to delete."
  }
}

# Rename a workspace's Zellij session and keep the saved name in sync
#
# Renames the live session in Zellij, then rewrites `.zellij_session` so later
# `workspace zellij` runs reuse the new name. Pass the new name, or omit it to
# be prompted (prefilled with the current name; Enter keeps it, empty cancels).
# Only a running session can be renamed; an EXITED/resurrectable one is left
# untouched (attach it first with `workspace zellij`).
#
#   workspace zellij rename my-new-name   # current workspace
#   workspace zellij rename -c            # pick one, prompt for the name
export def --env "zellij rename" [
  new?: string              # New session name; omit to be prompted
  --choose (-c)             # Pick a workspace interactively instead of using the current one
]: nothing -> nothing {
  let name = (select-workspace $choose)
  let dir = (workspace-dir $name)
  let old = (read-session-name $dir | default $name)
  let target = if $new != null {
    $new
  } else {
    prompt-session-name $"Rename Zellij session '($old)' to:" --default $old
  }
  if ($target | is-empty) or ($target == $old) {
    print "Nothing to do."
    return
  }
  if not (zellij-session-exists $old) {
    print $"No Zellij session '($old)' to rename."
    return
  }
  if not (zellij-rename-session $old $target) { return }
  save-session-name $dir $target
  sync-clawd-session-id $old $target
  if (($env.ZELLIJ_SESSION_NAME? | default "") == $old) {
    $env.ZELLIJ_SESSION_NAME = $target
  }
  print $"(ansi green)renamed Zellij session '($old)' -> '($target)'(ansi reset)"
}

# Kill a workspace's running Zellij session, leaving it resurrectable
#
# Tears down the running session but keeps both the resurrectable state and the
# saved `.zellij_session` name, so `workspace zellij` can bring it back later.
# Use `workspace zellij delete` instead to forget the name and drop the state.
#
#   workspace zellij kill        # current workspace
#   workspace zellij kill -c     # pick one
export def "zellij kill" [
  --choose (-c)             # Pick a workspace interactively instead of using the current one
]: nothing -> nothing {
  let name = (select-workspace $choose)
  let dir = (workspace-dir $name)
  let session = (read-session-name $dir | default $name)
  if (zellij-session-exists $session) {
    zellij-kill-session $session
    print $"(ansi yellow)killed Zellij session '($session)' \(resurrectable\)(ansi reset)"
  } else {
    print $"No Zellij session '($session)' to kill."
  }
}

# cd into an existing workspace, matched by name or partial
#
# The argument is matched case-insensitively: an exact name wins outright,
# otherwise every workspace whose name contains the substring is a candidate.
# More than one candidate — or omitting the name entirely — opens a picker;
# a query that matches nothing falls back to a picker over all workspaces.
#
#   workspace switch ENG-123   # exact
#   workspace switch sms       # substring; picks if more than one matches
#   workspace switch           # pick interactively
#
# If the workspace has a saved Zellij session (see `workspace zellij`), you're
# attached to it after switching.
export def --env switch [
  name?: string   # Workspace name or partial; omit to choose interactively
]: nothing -> nothing {
  let sel = (select-workspaces $name --prompt "Switch to:")
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

# Permanently delete workspaces and everything inside them
#
# Pass a name or partial, or omit it to pick from all. An exact name or unique
# substring resolves directly; anything ambiguous (or a no-match fall back to
# all) opens a fuzzy multi-select. Unless --force is given, the selection's
# contents are listed (including hidden files, flagging uncommitted work) and
# confirmed first. This is irreversible — use `workspace trash` to keep the
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
# target the shell is sitting in, then removes each directory — via the system
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

# Clone repos into a workspace via `gh` (defaults to the current workspace)
#
# Bare names are resolved against $env.WORKSPACES_GH_ORG; pass owner/name to
# override the org for a single repo.
export def clone [
  ...repos: string  # Repos to clone (name or owner/name)
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
    let slug = if ($repo | str contains "/") {
      $repo
    } else {
      $"($env.WORKSPACES_GH_ORG)/($repo)"
    }
    let target = ($dir | path join ($slug | path basename))
    if ($target | path exists) {
      print $"(ansi yellow)skip ($slug) \(already cloned\)(ansi reset)"
      continue
    }
    print $"(ansi green)clone ($slug)(ansi reset)"
    ^gh repo clone $slug $target
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
