use remove.nu *

# Permanently delete workspaces and everything inside them
#
# Irreversible. Use `workspace trash` to keep the directories recoverable.
#
#   workspace delete ABC-123          # exact
#   workspace delete api              # substring; multi-select if ambiguous
#   workspace delete                  # pick from all
#   workspace delete --force ABC-123  # no confirmation
export def --env main [
  query?: string   # Workspace name or partial; omit to choose interactively
  --force (-f)     # Skip the confirmation prompt
]: nothing -> nothing {
  remove-workspaces $force false $query
}
