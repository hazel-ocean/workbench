# Workspace removal, shared by `workspace delete` and `workspace trash`.

const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

export def --env remove-workspaces [
  force: bool           # Skip the confirmation prompt
  trash: bool           # Move to the system trash instead of deleting permanently
  query?: string        # Workspace name or partial; omit to pick interactively
]: nothing -> nothing {
  let verb = if $trash { "trash" } else { "delete" }
  let targets = if $force {
    select-workspaces $query --multi --show-size --prompt $"Workspaces to ($verb):"
  } else {
    select-workspaces $query --multi --confirm --list-contents --show-size --prompt $"Workspaces to ($verb):"
  }

  if ($targets | is-empty) {
    print "Nothing selected."
    return
  }

  # Step out of a doomed directory. The workbench root is never removed.
  let removed = ($targets | where {|t| $t != (workspace-home)})
  let current = (try-infer-workspace)
  if $current != null and ($current in $removed) {
    cd (workspace-dir (workspace-home))
  }

  for name in $targets {
    let dir = (workspace-dir $name)
    # The file lives inside the directory about to go.
    let saved = (read-session-name $dir)
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
    # Trash keeps the session resurrectable, to match the recoverable directory.
    if $saved != null {
      if $trash { zellij-kill-session $saved } else { zellij-delete-session $saved }
    }
  }
}
