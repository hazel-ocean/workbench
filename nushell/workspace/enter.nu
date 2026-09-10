const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# cd into an existing workspace without attaching to Zellij
#
# Same matching and display as `workspace attach`, but does not attach to
# the workspace's Zellij session (if one exists).
#
#   workspace enter ENG-123   # exact
#   workspace enter sms       # substring; picks if more than one matches
#   workspace enter           # pick interactively
export def --env main [
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
