const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Open a workspace's metadata file in your editor, creating it if there is none
#
# The file is the `.workspace.meta.<format>` that `workspace info` reports as
# `metadata`; see there for what belongs in it. A workspace without one gets a
# commented `.workspace.meta.yaml`, which parses as no metadata until filled in.
#
# $EDITOR wins over $VISUAL. Defaults to the current workspace; pass --choose
# to pick one.
#
#   workspace metadata        # edit this workspace's metadata
#   workspace metadata -c     # pick the workspace first
export def main [
  --choose (-c)   # Pick a workspace interactively instead of using the current one
]: nothing -> nothing {
  let name = (select-workspace $choose)
  let dir = (workspace-dir $name)
  let existing = (metadata-file $dir)
  let file = if $existing != null {
    $existing
  } else {
    let created = (metadata-new-file $dir)
    metadata-template $name | save $created
    print $"(ansi green)created ($created | path basename) in ($name)(ansi reset)"
    $created
  }
  open-in-editor $file
}
