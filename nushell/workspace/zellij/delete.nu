const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Forget a workspace's saved Zellij session, optionally deleting the session too
#
# Removes the `.zellij_session` file, then, if a matching session exists,
# prompts to delete it entirely (killed if running, resurrectable state dropped).
#
#   workspace zellij delete        # current workspace
#   workspace zellij delete -c     # pick one
export def main [
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
