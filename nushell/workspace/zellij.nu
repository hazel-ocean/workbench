# Zellij session management for workspaces.
#
# Commands to attach to, create, rename, and manage Zellij sessions per workspace.

const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Attach to (or create) this workspace's Zellij session
#
# Shorthand for `workspace zellij attach`. When the shell is already inside a
# Zellij session there's nothing to attach to, so it just reports the session;
# pass --choose to pick a different workspace or orphan session anyway.
export def main [
  --choose (-c)             # Pick a workspace or orphan session interactively
]: nothing -> nothing {
  let current = ($env.ZELLIJ_SESSION_NAME? | default "")
  if ($current | is-not-empty) and (not $choose) {
    print $"Already in Zellij session '($current)'."
    return
  }
  zellij attach --choose=$choose
}

# Attach to (or create) a Zellij session for a workspace
#
# The session name is remembered in `.zellij_session` at the workspace root. The
# first time (no saved name) you're prompted, prefilled with the workspace name.
# Press Enter to accept or type a replacement. Later runs reuse the saved name
# silently. If Zellij rejects a name you're re-prompted. Use `workspace zellij
# delete` to forget the saved name and optionally delete the session.
export def "zellij attach" [
  --choose (-c)             # Pick a workspace or orphan session interactively
]: nothing -> nothing {
  let target = (select-zellij-target $choose)
  # Orphan session: no dir to launch from, and it already exists, so just attach.
  if $target.dir == null {
    zellij-attach-existing $target.session
    return
  }
  let saved = (read-session-name $target.dir)
  if $saved != null {
    zellij-attach $target.dir $saved
  } else {
    zellij-attach $target.dir $target.workspace --prompt
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
  --choose (-c)             # Pick a workspace or orphan session interactively
]: nothing -> nothing {
  let target = (select-zellij-target $choose)
  let session = $target.session
  # Orphans have no saved `.zellij_session` to forget; skip that bookkeeping.
  if $target.dir != null {
    let saved = (read-session-name $target.dir)
    remove-session-name $target.dir
    if $saved != null { print $"(ansi yellow)forgot saved session '($saved)'(ansi reset)" }
  }
  if (zellij-session-exists $session) {
    if (confirm-prompt $"Delete Zellij session '($session)' entirely?") {
      zellij-delete-session $session
      print $"(ansi red)deleted Zellij session '($session)'(ansi reset)"
    }
  } else {
    print $"No Zellij session '($session)' to delete."
  }
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
  --choose (-c)             # Pick a workspace or orphan session interactively
]: nothing -> nothing {
  let target = (select-zellij-target $choose)
  let session = $target.session
  if (zellij-session-exists $session) {
    zellij-kill-session $session
    print $"(ansi yellow)killed Zellij session '($session)' \(resurrectable\)(ansi reset)"
  } else {
    print $"No Zellij session '($session)' to kill."
  }
}

# Rename a workspace's Zellij session, or reconcile a rename made in Zellij itself
#
# With a NAME argument: renames the live session in Zellij and rewrites
# `.zellij_session` so later `workspace zellij` runs reuse the new name. Only a
# running session can be renamed; an EXITED/resurrectable one is left untouched
# (attach it first with `workspace zellij`).
#
# With NO argument: reconcile-only. If you renamed the session from Zellij's own
# UI, the saved `.zellij_session` name goes stale; this offers to update the saved
# state to the live session name. It then offers to set the Ghostty tab title to
# match. Both offers are confirm-first and appear only when there's an actual
# difference, so a clean state prints "Nothing to do."
#
#   workspace rename my-new-name   # rename the live session
#   workspace rename               # reconcile saved state + Ghostty title
#   workspace rename -c            # reconcile a chosen workspace
export def --env "zellij rename" [
  new?: string              # New session name; omit to reconcile only
  --choose (-c)             # Pick a workspace interactively instead of using the current one
]: nothing -> nothing {
  let name = (select-workspace $choose)
  let dir = (workspace-dir $name)
  mut saved = (read-session-name $dir | default $name)
  mut acted = false

  # Reconcile a rename made in Zellij's own UI. `(current)` reflects the pane
  # we're in, so only trust it when acting on the current workspace, not --choose.
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

  # Explicit rename of the live session to the given name.
  if $new != null {
    if ($new | is-empty) or ($new == $saved) {
      if not $acted { print "Nothing to do." }
      return
    }
    if not (zellij-session-exists $saved) {
      print $"No Zellij session '($saved)' to rename."
      return
    }
    if not (zellij-rename-session $saved $new) { return }
    save-session-name $dir $new
    sync-clawd-session-id $saved $new
    if (($env.ZELLIJ_SESSION_NAME? | default "") == $saved) {
      $env.ZELLIJ_SESSION_NAME = $new
    }
    print $"(ansi green)renamed Zellij session '($saved)' -> '($new)'(ansi reset)"
    $saved = $new
    $acted = true
  }

  # Offer to bring the Ghostty tab title in line with the session name.
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

