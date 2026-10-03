# Zellij session management for workspaces.

export use attach.nu *
export use delete.nu *
export use kill.nu *
export use rename.nu *

# Attach to (or create) this workspace's Zellij session
#
# Shorthand for `workspace zellij attach`. Inside a session it only reports the
# session, unless --choose is given.
export def --env main [
  --choose (-c)             # Pick a workspace or orphan session interactively
]: nothing -> nothing {
  let current = ($env.ZELLIJ_SESSION_NAME? | default "")
  if ($current | is-not-empty) and (not $choose) {
    print $"Already in Zellij session '($current)'."
    return
  }
  attach --choose=$choose
}
