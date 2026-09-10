const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Summarize a workspace: name, path, saved Zellij session, repos, and metadata
#
# Defaults to the current workspace; pass --choose to pick one.
#
# `metadata` is a `.workspace.meta.<format>` file at the workspace root, holding
# the context a workspace has that its repos cannot show: the ticket, the
# thread, the notes. The keys are yours; nothing validates them.
#
# The extension picks the parser, and the name is matched case-insensitively,
# so .workspace.meta.yaml, .workspace.meta.toml, .workspace.meta.json and
# .workspace.meta.nuon all read as a record. A format nushell cannot parse
# reads as text. A workspace with no metadata gets no `metadata` field, so
# reach for it as `get metadata?` when a workspace may not have one.
#
# A key ending in `-link`, `-url` or `-uri` (or named just that) is rendered as
# a clickable hyperlink, so a scheme the terminal does not auto-detect still
# opens. Write the value bare to show the URI, or as markdown to label it.
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
  # A workspace with no metadata file gets no `metadata` field at all: spreading
  # a null adds nothing, where a null field would report an empty row as data.
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
