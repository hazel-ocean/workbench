use remove.nu *

# Move workspaces to the system trash (recoverable)
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
