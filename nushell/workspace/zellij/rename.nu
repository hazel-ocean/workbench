const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Rename a workspace's Zellij session, or reconcile a rename made in Zellij itself
#
# Only a running session can be renamed. It also offers to update the saved name
# and the Ghostty tab title to match the live session.
#
#   workspace rename my-new-name   # rename the live session
#   workspace rename               # ask for the name, then reconcile
#   workspace rename -c            # the same for a chosen workspace
export def --env main [
  new?: string              # New session name; omit to be asked
  --choose (-c)             # Pick a workspace interactively instead of using the current one
]: nothing -> nothing {
  let name = (select-workspace $choose)
  let dir = (workspace-dir $name)
  mut saved = (read-session-name $dir | default $name)
  mut acted = false

  # `(current)` is this pane's session, which says nothing about a chosen one.
  let current = (if $choose { null } else { zellij-current-session })
  if $current != null and $current != $saved {
    if (confirm-prompt
      $"Saved session is '($saved)' but the live Zellij session is '($current)'. Update saved state to '($current)'?") {
      save-session-name $dir $current
      sync-clawd-session-id $saved $current
      if (($env.ZELLIJ_SESSION_NAME? | default "") == $saved) {
        $env.ZELLIJ_SESSION_NAME = $current
      }
      print $"(ansi green)reconciled saved session '($saved)' -> '($current)'(ansi reset)"
      $saved = $current
      $acted = true
    }
  }

  mut target = $new
  if $target == null and (zellij-session-exists $saved) {
    $target = (prompt-session-name "Rename the Zellij session:" --default $saved)
  }

  if ($target | is-not-empty) and $target != $saved {
    if not (zellij-session-exists $saved) {
      print $"No Zellij session '($saved)' to rename."
      return
    }
    loop {
      if (zellij-rename-session $saved $target) { break }
      $target = (prompt-session-name
        "Zellij couldn't rename that session. Enter a different name:")
      if ($target | is-empty) { print "Cancelled."; return }
    }
    save-session-name $dir $target
    sync-clawd-session-id $saved $target
    if (($env.ZELLIJ_SESSION_NAME? | default "") == $saved) {
      $env.ZELLIJ_SESSION_NAME = $target
    }
    print $"(ansi green)renamed Zellij session '($saved)' -> '($target)'(ansi reset)"
    $saved = $target
    $acted = true
  }

  let title = (ghostty-title)
  if $title != null and $title != $saved {
    if (confirm-prompt $"Ghostty title is '($title)'.(char newline)Set it to '($saved)'?") {
      ghostty-set-title $saved
      print $"(ansi green)set Ghostty title to '($saved)'(ansi reset)"
      $acted = true
    }
  }

  if not $acted { print "Nothing to do." }
}
