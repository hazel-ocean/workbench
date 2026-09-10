# Zellij session management for workspaces.
#
# Commands to attach to, create, rename, and manage Zellij sessions per workspace.

export use attach.nu *
export use delete.nu *
export use kill.nu *
export use rename.nu *

# Attach to (or create) this workspace's Zellij session
#
# Shorthand for `workspace zellij attach`. When the shell is already inside a
# Zellij session there's nothing to attach to, so it just reports the session;
# pass --choose to pick a different workspace or orphan session anyway.
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
