# Workspace removal, shared by `workspace delete` and `workspace trash`.
#
# Imported with a plain `use`, so it stays out of the public `workspace` overlay.

const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Shared implementation for `delete` / `trash`.
#
# Resolves targets via `select-workspaces` (which handles the picker, the
# contents preview, and the confirmation when not forced), steps out of any
# target the shell is sitting in, then removes each directory, via the system
# trash when `trash` is set.
export def --env remove-workspaces [
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
  # the workbench root so we don't strand the session in a deleted directory: the
  # workspaces root can itself be removed, the workbench root never is. The meta
  # home is never removed, so it doesn't count as a target.
  let removed = ($targets | where {|t| $t != (workspace-home)})
  let current = (try-infer-workspace)
  if $current != null and ($current in $removed) {
    cd (workspace-dir (workspace-home))
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
