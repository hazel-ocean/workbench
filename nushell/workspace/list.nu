const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# List all workspaces with their Zellij session and metadata
#
# Zellij sessions owned by no workspace appear as orphan rows. See
# `workspace info` for metadata.
export def main []: nothing -> table {
  let sessions = (zellij-sessions)
  let home = (workspace-home)
  let rows = (workspace-names | par-each {|name|
    let dir = (workspace-dir $name)
    let saved = (read-session-name $dir)
    let state = (if ($saved | is-not-empty) { session-state $saved $sessions })
    {
      key: $name
      workspace: $name
      zellij: (if ($saved | is-not-empty) { paint-state $saved $state ($name == $home) })
      state: $state
      metadata: (description-first (linkify (workspace-metadata $dir)))
    }
  })
  let orphans = (orphan-sessions --sessions $sessions | each {|s|
    {
      key: $s.name
      workspace: $"(ansi dark_gray)\(orphan\)(ansi reset)"
      zellij: (paint-state $s.name $s.state false)
      state: $s.state
      metadata: null
    }
  })
  $rows ++ $orphans | sort-by --ignore-case key | reject key
}

def description-first [metadata: any]: nothing -> any {
  match ($metadata | describe --detailed | get type) {
    "record" if ("description" in ($metadata | columns)) => (
      $metadata | move description --first
    )
    _ => $metadata
  }
}
