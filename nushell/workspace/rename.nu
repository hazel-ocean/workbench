use zellij

# Rename a workspace's Zellij session, or reconcile a rename made in Zellij itself
#
# Thin top-level alias for `workspace zellij rename`; see there for details.
export def --env main [
  new?: string              # New session name; omit to reconcile only
  --choose (-c)             # Pick a workspace interactively instead of using the current one
]: nothing -> nothing {
  zellij rename $new --choose=$choose
}
