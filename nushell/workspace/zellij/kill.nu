const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Kill a workspace's running Zellij session, leaving it resurrectable
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
