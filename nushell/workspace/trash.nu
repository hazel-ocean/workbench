use remove.nu *

# Move workspaces to the system trash (recoverable)
#
# Like `workspace delete`, but routes through the OS trash so the directories
# can be restored later. Selection, contents preview, and --force behave the
# same as `delete`.
#
#   workspace trash ENG-123           # exact
#   workspace trash sms               # substring; multi-select if ambiguous
#   workspace trash                   # pick from all
#   workspace trash --force ENG-123   # no confirmation
export def --env main [
  query?: string   # Workspace name or partial; omit to choose interactively
  --force (-f)     # Skip the confirmation prompt
]: nothing -> nothing {
  remove-workspaces $force true $query
}
