const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# List all workspaces (meta home first) with each repo's branch and status
#
# The `state` column reports the saved Zellij session's status (active / exited
# / gone), or is empty when no session is saved. See `session-state`.
#
# Orphan Zellij sessions, live sessions owned by no workspace, are mixed in as
# rows with a null `workspace` and no repos, so `list` surfaces every session,
# not just workspace-associated ones. See `orphan-sessions`.
#
# Rows sort case-insensitively by their identifying name: a workspace by its
# name, an orphan by its session name. The `key` column is internal, dropped
# before returning.
export def main []: nothing -> table {
  let sessions = (zellij-sessions)
  let home = (workspace-home)
  let rows = (workspace-names | par-each {|name|
    let saved = (read-session-name (workspace-dir $name))
    let state = (if ($saved | is-not-empty) { session-state $saved $sessions })
    {
      key: $name
      workspace: $name
      session: (if ($saved | is-not-empty) { paint-state $saved $state ($name == $home) })
      state: $state
      repos: (repo-summaries $name)
    }
  })
  let orphans = (orphan-sessions --sessions $sessions | each {|s|
    {
      key: $s.name
      workspace: $"(ansi dark_gray)\(orphan\)(ansi reset)"
      session: (paint-state $s.name $s.state false)
      state: $s.state
      repos: []
    }
  })
  $rows ++ $orphans | sort-by --ignore-case key | reject key
}
