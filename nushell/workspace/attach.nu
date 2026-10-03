const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# cd into a workspace and attach to its saved Zellij session
#
# The picker also offers orphan Zellij sessions, which attach without a cd.
#
#   workspace attach ABC-123   # exact
#   workspace attach api       # substring; picks if more than one matches
#   workspace attach           # pick interactively
export def --env main [
  name?: string   # Workspace name or partial; omit to choose interactively
]: nothing -> nothing {
  let sel = (select-workspaces $name --prompt "Attach to:" --color-state --with-orphans)
  if ($sel | is-empty) {
    print "Nothing selected."
    return
  }
  let name = ($sel | first)
  # See `restore-cwd`.
  let root = (workspace-dir (workspace-home))
  let origin = $env.PWD
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
