const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Attach to (or create) a Zellij session for a workspace
#
# The session name is remembered in `.zellij_session` at the workspace root. The
# first time (no saved name) you're prompted, prefilled with the workspace name.
# Press Enter to accept or type a replacement. Later runs reuse the saved name
# silently. If Zellij rejects a name you're re-prompted. Use `workspace zellij
# delete` to forget the saved name and optionally delete the session.
export def --env main [
  --choose (-c)             # Pick a workspace or orphan session interactively
]: nothing -> nothing {
  let target = (select-zellij-target $choose)
  # Attaching blocks until the session ends, and the workspace may be deleted
  # while we wait. See `restore-cwd` for why these are captured up front.
  let root = (workspace-dir (workspace-home))
  let origin = $env.PWD
  # Orphan session: no dir to launch from, and it already exists, so just attach.
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
