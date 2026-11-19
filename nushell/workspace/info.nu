const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Summarize a workspace: name, path, saved Zellij session, repos, and metadata
#
# `metadata` is the `.workspace.meta.<format>` file at the workspace root, in
# any format nushell parses. It is absent when there is no file, so use
# `get metadata?`. Keys ending in `-link`, `-url` or `-uri`, or a plural of
# those, render as links.
#
#   # .workspace.meta.yaml
#   linear-url: https://linear.app/acme/issue/ABC-123
#   obsidian-link: "[Feature notes](obsidian://open?vault=Notes&file=Projects/feature)"
#   things-link: things:///show?id=ABC123
export def main [
  workspace?: string@workspace-names # Workspace name or partial; omit to use the current one
  --choose (-c)                      # Pick a workspace interactively instead of using the current one
]: nothing -> record {
  let name = if $workspace == null {
    select-workspace $choose
  } else {
    let sel = (select-workspaces $workspace)
    if ($sel | is-empty) {
      error make --unspanned {
        msg: "Nothing selected."
        code: "workspace::nothing_selected"
      }
    }
    $sel | first
  }
  let dir = (workspace-dir $name)
  let saved = (read-session-name $dir)
  let metadata = (linkify (workspace-metadata $dir))
  {
    workspace: $name
    path: $dir
    session: $saved
    state: (if ($saved | is-not-empty) { session-state $saved (zellij-sessions) })
    ...(if $metadata != null { { metadata: $metadata } })
    repos: (repo-summaries $name)
  }
}
