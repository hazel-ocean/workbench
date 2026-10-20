use zellij

# Rename a workspace's Zellij session, or reconcile a rename made in Zellij itself
#
# Alias for `workspace zellij rename`.
export def --env main [
  new?: string              # New session name; omit to be asked
  --choose (-c)             # Pick a workspace interactively instead of using the current one
]: nothing -> nothing {
  zellij rename $new --choose=$choose
}
