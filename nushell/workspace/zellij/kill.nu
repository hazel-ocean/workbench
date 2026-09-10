const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Kill a workspace's running Zellij session, leaving it resurrectable
#
# Tears down the running session but keeps both the resurrectable state and the
# saved `.zellij_session` name, so `workspace zellij` can bring it back later.
# Use `workspace zellij delete` instead to forget the name and drop the state.
#
#   workspace zellij kill        # current workspace
#   workspace zellij kill -c     # pick one
export def main [
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
