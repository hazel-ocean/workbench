use remove.nu *

# Permanently delete workspaces and everything inside them
#
# Pass a name or partial, or omit it to pick from all. An exact name or unique
# substring resolves directly; anything ambiguous (or a no-match fall back to
# all) opens a fuzzy multi-select. Unless --force is given, the selection's
# contents are listed (including hidden files, flagging uncommitted work) and
# confirmed first. This is irreversible; use `workspace trash` to keep the
# directories recoverable.
#
#   workspace delete ENG-123          # exact
#   workspace delete sms              # substring; multi-select if ambiguous
#   workspace delete                  # pick from all
#   workspace delete --force ENG-123  # no confirmation
export def --env main [
  query?: string   # Workspace name or partial; omit to choose interactively
  --force (-f)     # Skip the confirmation prompt
]: nothing -> nothing {
  remove-workspaces $force false $query
}
