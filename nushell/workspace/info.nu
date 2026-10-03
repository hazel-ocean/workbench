const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Summarize a workspace: name, path, saved Zellij session, repos, and metadata
#
# `metadata` is the `.workspace.meta.<format>` file at the workspace root, in
# any format nushell parses. It is absent when there is no file, so use
# `get metadata?`. Keys ending in `-link`, `-url` or `-uri` render as links.
#
#   # .workspace.meta.yaml
#   linear-url: https://linear.app/onesignal/issue/ENG-123
#   obsidian-link: "[SMS module notes](obsidian://open?vault=OneSignal&file=Projects/sms-module)"
#   things-link: things:///show?id=ABC123
export def main [
  --choose (-c)   # Pick a workspace interactively instead of using the current one
]: nothing -> record {
  let name = (select-workspace $choose)
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
