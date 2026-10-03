const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Attach to (or create) a Zellij session for a workspace
#
# The first run prompts for a name, prefilled with the workspace name, and saves
# it to `.zellij_session`. Later runs reuse it.
export def --env main [
  --choose (-c)             # Pick a workspace or orphan session interactively
]: nothing -> nothing {
  let target = (select-zellij-target $choose)
  # See `restore-cwd`.
  let root = (workspace-dir (workspace-home))
  let origin = $env.PWD
  if $target.dir == null {
    zellij-attach-existing $target.session
    cd $root
    restore-cwd $origin
    return
  }
  let saved = (read-session-name $target.dir)
  if $saved != null {
    zellij-attach $target.dir $saved
  } else {
    zellij-attach $target.dir $target.workspace --prompt
  }
  cd $root
  restore-cwd $origin
}
