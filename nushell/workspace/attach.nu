const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

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
export def --env main [
  name?: string   # Workspace name or partial; omit to choose interactively
]: nothing -> nothing {
  let sel = (select-workspaces $name --prompt "Attach to:" --color-state --with-orphans)
  if ($sel | is-empty) {
    print "Nothing selected."
    return
  }
  let name = ($sel | first)
  # Attaching blocks until the session ends, and the workspace may be deleted
  # while we wait. See `restore-cwd` for why these are captured up front.
  let root = (workspace-dir (workspace-home))
  let origin = $env.PWD
  # An orphan session isn't a workspace: attach to it without cd'ing anywhere.
  if $name not-in (workspace-names) {
    zellij-attach-existing $name
    cd $root
    restore-cwd $origin
    return
  }
  let dir = (workspace-dir $name)
  cd $dir
  let saved = (read-session-name $dir)
  if $saved != null {
    zellij-attach $dir $saved
    cd $root
    restore-cwd $dir
  }
}
