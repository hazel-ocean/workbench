# Helpers for the workspace commands. A plain `use` keeps them out of the
# public `workspace` overlay.

# The meta workspace's name: the workbench repo root's basename.
export def workspace-home []: nothing -> string {
  $env.WORKBENCH_WORKSPACES_ROOT | path dirname | path basename
}

export def workspace-dir [name: string]: nothing -> path {
  if $name == (workspace-home) {
    $env.WORKBENCH_WORKSPACES_ROOT | path dirname
  } else {
    $env.WORKBENCH_WORKSPACES_ROOT | path join $name
  }
}

# Git can't track an empty directory, so a fresh clone has no workspaces root.
export def workspace-names []: nothing -> list<string> {
  let subdirs = if ($env.WORKBENCH_WORKSPACES_ROOT | path exists) {
    ls $env.WORKBENCH_WORKSPACES_ROOT
    | where type == dir
    | get name
    | each { $in | path basename }
    | where {|n| not ($n | str starts-with "_") }
  } else {
    []
  }
  ([(workspace-home)] ++ $subdirs) | sort --ignore-case
}

# `complete` traps a non-zero exit but not a missing binary, so check this
# before shelling out.
export def tool-installed [tool: string]: nothing -> bool {
  which $tool | is-not-empty
}

export def assert-tool [tool: string, purpose: string]: nothing -> nothing {
  if not (tool-installed $tool) {
    error make --unspanned {
      msg: $"'($tool)' is not installed."
      code: "workspace::missing_tool"
      help: $"Install ($tool) to ($purpose)."
    }
  }
}

# Only sizes the visual guide. Zellij enforces its own name rules.
const ZELLIJ_RULER_WIDTH = 24

const ZELLIJ_SESSION_FILE = ".zellij_session"

# Without --default, empty input returns "", which callers treat as cancel.
export def prompt-session-name [
  message: string
  --default (-d): string   # Prefill; Enter accepts it. Omitted → empty input = cancel.
]: nothing -> string {
  let bar = (0..<($ZELLIJ_RULER_WIDTH - 1) | each {|| "-" } | str join)
  print ([
    ""
    $"(ansi light_blue)($message)(ansi reset)"
    ""
    (if $default != null { $"(ansi green)Enter to keep: ($default)(ansi reset)" })
    $"(ansi light_blue)($bar)|(ansi reset) <- Limit"
  ] | compact | str join (char newline))
  let entered = if $default != null {
    input --default $default $"(ansi light_blue)" | str trim
  } else {
    input $"(ansi light_blue)" | str trim
  }
  print (ansi reset)  # clear color, and separate this attempt from the next
  $entered
}

export def confirm-prompt [message: string]: nothing -> bool {
  print --no-newline $"($message) \(y/N\) > "
  let key = ((input listen --types [key]).code? | default "")
  print $key  # `input listen` does not echo
  ($key | str lowercase) == "y"
}

export def read-session-name [dir: path]: nothing -> oneof<string, nothing> {
  let file = ($dir | path join $ZELLIJ_SESSION_FILE)
  if not ($file | path exists) { return null }
  let name = (open $file | str trim)
  if ($name | is-empty) { null } else { $name }
}

export def save-session-name [dir: path, name: string]: nothing -> nothing {
  $name | save --force ($dir | path join $ZELLIJ_SESSION_FILE)
}

export def remove-session-name [dir: path]: nothing -> nothing {
  let file = ($dir | path join $ZELLIJ_SESSION_FILE)
  if ($file | path exists) { rm --force $file }
}

const METADATA_PREFIX = ".workspace.meta."

# Matched case-insensitively, because `open` lowercases the extension before
# picking a parser.
export def metadata-file [dir: path]: nothing -> oneof<path, nothing> {
  if not ($dir | path exists) { return null }
  let found = (ls --all $dir
    | where type == file
    | get name
    | where {|f| $f | path basename | str starts-with --ignore-case $METADATA_PREFIX }
    | sort --ignore-case)
  if ($found | is-empty) { return null }
  if ($found | length) > 1 {
    let ignored = ($found | skip 1 | each {|f| $f | path basename } | str join ", ")
    print $"(ansi yellow)multiple ($METADATA_PREFIX)* files; ignoring ($ignored)(ansi reset)"
  }
  $found | first
}

# Parsed by extension, falling back to text. A broken file is a warning, not an
# error, so callers still answer.
export def workspace-metadata [dir: path]: nothing -> any {
  let file = (metadata-file $dir)
  if $file == null { return null }
  let name = ($file | path basename)
  let ext = ($file | path parse | get extension | str lowercase)
  # Without a `from <ext>` command, `open` returns bytes.
  if (which $"from ($ext)" | is-empty) {
    return (read-text $file $name)
  }
  try {
    open $file
  } catch {|e|
    print $"(ansi yellow)could not parse ($name) as ($ext): ($e.msg)(ansi reset)"
    read-text $file $name
  }
}

# YAML needs the least quoting: a bare URI is a valid scalar.
export def metadata-new-file [dir: path]: nothing -> path {
  $dir | path join $"($METADATA_PREFIX)yaml"
}

# Comments only, so an untouched file parses as no metadata.
export def metadata-template [name: string]: nothing -> string {
  ([
    $"# Metadata for the ($name) workspace, reported by `workspace info`."
    "#"
    "# The keys are yours. One ending in -link, -url or -uri is rendered as a"
    "# clickable link, written either bare or as markdown: [label](uri)"
    ""
    "# ticket-url: https://example.com/issue/ABC-123"
    '# notes-link: "[Design notes](obsidian://open?vault=Notes&file=Projects/x)"'
    "# task-link: things:///show?id=ABC123"
    ""
  ] | str join (char newline))
}

# Split on whitespace so a value with flags, such as `code -w`, works.
export def open-in-editor [file: path]: nothing -> nothing {
  let editor = ([($env.EDITOR? | default ""), ($env.VISUAL? | default "")]
    | each {|candidate| $candidate | str trim }
    | where {|candidate| $candidate | is-not-empty }
    | get 0?)
  if $editor == null {
    error make --unspanned {
      msg: "No editor configured."
      code: "workspace::no_editor"
      help: "Set $env.EDITOR (or $env.VISUAL) to the editor to open files with."
    }
  }
  let parts = ($editor | split row --regex '\s+')
  let command = ($parts | first)
  assert-tool $command "open a file in your editor"
  ^$command ...($parts | skip 1) $file
}

const LINK_SUFFIXES = ["link", "url", "uri"]

def link-key [key: string]: nothing -> bool {
  let lowered = ($key | str lowercase)
  $LINK_SUFFIXES | any {|suffix|
    ($lowered == $suffix) or ($lowered | str ends-with $"-($suffix)")
  }
}

# A label hides its URI, so it is painted blue to read as a link.
def link-value [value: string]: nothing -> string {
  let md = ($value
    | str trim
    | parse --regex '^\[(?<label>[^\]]*)\]\((?<uri>[^\s)]+)\)$')
  if ($md | is-empty) { return ($value | ansi link) }
  let link = ($md | first)
  if ($link.label | str trim | is-empty) {
    return ($link.uri | ansi link)
  }
  $link.uri | ansi link --text $"(ansi blue)($link.label)(ansi reset)"
}

# Terminals auto-detect only allowlisted schemes, so `things:///` and
# `obsidian://` need an explicit OSC 8 hyperlink to be clickable.
export def linkify [value: any, key?: string]: nothing -> any {
  match ($value | describe --detailed | get type) {
    "record" => (
      $value
      | transpose k v
      # `insert` would read a dotted key as a nested path.
      | reduce --fold {} {|pair, acc| $acc | merge { ($pair.k): (linkify $pair.v $pair.k) } }
    )
    "list" => ($value | each {|item| linkify $item $key })
    "string" => (if ($key != null) and (link-key $key) { link-value $value } else { $value })
    _ => $value
  }
}

def read-text [file: path, name: string]: nothing -> oneof<string, nothing> {
  try {
    open --raw $file | decode utf-8 | str trim
  } catch {|e|
    print $"(ansi yellow)could not read ($name): ($e.msg)(ansi reset)"
    null
  }
}

# Keeps clawd-back's notify/click resolving the right pane after a rename.
# `zellij_session_id` is clawd-back's legacy schema.
export def sync-clawd-session-id [old: string, new: string]: nothing -> nothing {
  let dir = ($env.HOME | path join ".cache" "clawd-back")
  if not ($dir | path exists) { return }
  for file in (glob ($dir | path join "*.json")) {
    let state = (try { open $file } catch { null })
    if $state == null { continue }
    mut next = $state
    if (($next | get multiplexer?.session? | default "") == $old) {
      $next = ($next | update multiplexer.session $new)
    }
    if (($next | get zellij_session_id? | default "") == $old) {
      $next = ($next | update zellij_session_id $new)
    }
    if $next != $state {
      $next | to json | save --force $file
    }
  }
}

# Leaves the session resurrectable.
export def zellij-kill-session [name: string]: nothing -> nothing {
  if not (tool-installed "zellij") { return }
  let result = (^zellij kill-session -- $name | complete)
  if $result.exit_code != 0 {
    print $"(ansi yellow)could not kill Zellij session '($name)': ($result.stderr | str trim)(ansi reset)"
  }
}

export def zellij-delete-session [name: string]: nothing -> nothing {
  if not (tool-installed "zellij") { return }
  let result = (^zellij delete-session --force -- $name | complete)
  if $result.exit_code != 0 {
    print $"(ansi yellow)could not delete Zellij session '($name)': ($result.stderr | str trim)(ansi reset)"
  }
}

# Fails on an exited session, which has no server to act on. Do not persist the
# new name on false.
export def zellij-rename-session [from: string, to: string]: nothing -> bool {
  if not (tool-installed "zellij") { return false }
  let result = (^zellij --session $from action rename-session -- $to | complete)
  if $result.exit_code != 0 {
    print $"(ansi yellow)could not rename Zellij session '($from)' -> '($to)': ($result.stderr | str trim)(ansi reset)"
    return false
  }
  true
}

export def zellij-session-exists [name: string]: nothing -> bool {
  if not (tool-installed "zellij") { return false }
  ^zellij list-sessions --no-formatting --short
  | complete
  | get stdout
  | lines
  | any {|s| ($s | str trim) == $name }
}

# `--short` drops the EXITED marker. Filtering on "[Created" also drops the "No
# active zellij sessions" notice.
export def zellij-sessions []: nothing -> table {
  if not (tool-installed "zellij") { return [] }
  let result = (^zellij list-sessions --no-formatting | complete)
  if $result.exit_code != 0 { return [] }
  $result.stdout
  | lines
  | each {|line| $line | str trim }
  | where {|line| $line | str contains "[Created" }
  | each {|line|
      {
        # Session names can contain spaces.
        name: ($line | split row " [Created" | first | str trim)
        state: (if ($line | str contains "EXITED") { "exited" } else { "active" })
      }
    }
  | sort-by --ignore-case name
}

export def claimed-sessions []: nothing -> list<string> {
  workspace-names
  | each {|n| read-session-name (workspace-dir $n) }
  | compact
}

# Zellij sessions owned by no workspace.
export def orphan-sessions [
  --sessions: table   # Precomputed `zellij-sessions`; omit to fetch fresh
]: nothing -> table {
  let all = ($sessions | default (zellij-sessions))
  let claimed = (claimed-sessions)
  $all | where name not-in $claimed
}

# $env.ZELLIJ_SESSION_NAME goes stale after a rename in the Zellij UI. The
# "(current)" marker does not.
export def zellij-current-session []: nothing -> oneof<string, nothing> {
  if not (tool-installed "zellij") { return null }
  let result = (^zellij list-sessions --no-formatting | complete)
  if $result.exit_code != 0 { return null }
  let line = ($result.stdout | lines | where {|l| $l | str contains "(current)" } | get 0?)
  if $line == null { return null }
  let name = ($line | str trim | split row " [Created" | first | str trim)
  if ($name | is-empty) { null } else { $name }
}

# Reading `name` works, although setting it does not.
export def ghostty-title []: nothing -> oneof<string, nothing> {
  let result = (^osascript -e 'tell application "Ghostty" to get name of front window' | complete)
  if $result.exit_code != 0 { return null }
  let title = ($result.stdout | str trim)
  if ($title | is-empty) { null } else { $title }
}

# Needs Accessibility permission and the target tab focused. See the AppleScript
# for why it drives the UI.
export def ghostty-set-title [title: string]: nothing -> nothing {
  const script = (path self | path dirname | path dirname
    | path join "applescript" "ghostty-set-title.applescript")
  let result = (^osascript $script $title | complete)
  if $result.exit_code != 0 {
    print $"(ansi yellow)could not set Ghostty title to '($title)': ($result.stderr | str trim)(ansi reset)"
  }
}

# "active", "exited", or "offline" when Zellij has no session of that name.
export def session-state [
  saved: string    # A workspace's saved session name
  sessions: table  # Rows from `zellij-sessions`
]: nothing -> string {
  let match = ($sessions | where name == $saved)
  if ($match | is-empty) { "offline" } else { $match | first | get state }
}

export def paint-state [
  text: string                       # The string to color
  state: oneof<string, nothing>      # A `session-state` value, or null for no session
  is_home: bool                      # Whether this is the meta workbench workspace
]: nothing -> string {
  let color = match $state {
    "active" => (if $is_home { (ansi purple) } else { (ansi blue) })
    "exited" | "offline" => (ansi red)
    _ => null
  }
  if $color == null { $text } else { $"($color)($text)(ansi reset)" }
}

# Creation and entry are one step. A session made with `--create-background`
# never starts its first pane, so the client lands on the status bar plugin
# (zellij 0.45).
export def zellij-attach [
  dir: path        # Workspace directory to launch from
  session: string  # Session name (a saved name, or the workspace name on a first run)
  --prompt         # Prompt for a name before the first attempt, prefilled with `session`
]: nothing -> nothing {
  assert-tool "zellij" "attach to a session"
  cd $dir
  mut session = $session
  if $prompt {
    let named = (prompt-session-name "Name the Zellij session:" --default $session)
    $session = (if ($named | is-empty) { $session } else { $named })
  }
  # Entry blocks until detach, so the name is saved first and put back on a
  # rejection.
  let previous = (read-session-name $dir)
  loop {
    if $session == ($env.ZELLIJ_SESSION_NAME? | default "") {
      print $"Already in Zellij session '($session)'."
      save-session-name $dir $session
      return
    }
    save-session-name $dir $session
    try {
      zellij-enter $dir $session
      return
    }
    if $previous == null { remove-session-name $dir } else { save-session-name $dir $previous }
    let next = (prompt-session-name "Zellij couldn't create that session. Enter a different name:")
    if ($next | is-empty) { print "Cancelled."; return }
    $session = $next
  }
}

# Nested `attach` stalls, so switch when already in a session.
#
# `attach` takes no `--`: zellij reads what follows it as a command.
def zellij-enter [
  dir: path        # Working directory for a session being created
  session: string  # Session name
]: nothing -> nothing {
  if ($env.ZELLIJ_SESSION_NAME? | default "" | is-not-empty) {
    ^zellij action switch-session --cwd $dir -- $session
  } else {
    ^zellij attach --create $session
  }
}

export def zellij-attach-existing [session: string]: nothing -> nothing {
  assert-tool "zellij" "attach to a session"
  if $session == ($env.ZELLIJ_SESSION_NAME? | default "") {
    print $"Already in Zellij session '($session)'."
    return
  }
  if ($env.ZELLIJ_SESSION_NAME? | default "" | is-not-empty) {
    ^zellij action switch-session -- $session
  } else {
    ^zellij attach $session
  }
}

export def try-infer-workspace []: nothing -> oneof<string, nothing> {
  let ws_root = ($env.WORKBENCH_WORKSPACES_ROOT | path expand)
  let home_dir = ($ws_root | path dirname)
  let pwd = ($env.PWD | path expand)
  if ($pwd != $ws_root) and ($pwd | str starts-with ($ws_root | path join "")) {
    return ($pwd | path relative-to $ws_root | path split | first)
  }
  if ($pwd == $home_dir) or ($pwd | str starts-with ($home_dir | path join "")) {
    return (workspace-home)
  }
  null
}

# A blocking `zellij` attach can return into a directory deleted in the
# meantime. Nushell then runs nothing but `cd` until PWD exists, so callers
# recover in this exact order:
#
#   let root = (workspace-dir (workspace-home))   # before blocking; a call now still works
#   let origin = $env.PWD
#   zellij-attach $dir $session                   # blocks; $origin may vanish
#   cd $root                                      # bare cd with a captured path: the only
#   restore-cwd $origin                           # thing that runs when cwd is gone
#
# The workbench root is never a delete target, so `cd $root` always lands.
export def --env restore-cwd [dir: path]: nothing -> nothing {
  if ($dir | path exists) {
    cd $dir
  }
}

export def workspace-repos [name: string]: nothing -> list<path> {
  let dir = (workspace-dir $name)
  if not ($dir | path exists) {
    error make --unspanned {
      msg: $"Workspace '($name)' does not exist."
      code: "workspace::unknown_workspace"
      help: "Create it with `workspace new <name>`, or list them with `workspace list`."
    }
  }
  if $name == (workspace-home) {
    if ($dir | path join ".git" | path exists) { [$dir] } else { [] }
  } else {
    ls $dir
    | where type == dir
    | get name
    | where {|p| ($p | path join ".git" | path exists) }
    | sort
  }
}

# Kept under `branch.<name>`, so git carries them on rename and drops them on
# delete. Git stores keys lowercased, so `--get-regexp` must match that form.
const BASE_KEY = "workbenchBase"
const BASE_SHA_KEY = "workbenchBaseSha"

const CHAIN_DEPTH_LIMIT = 10

export def current-branch [repo: path]: nothing -> oneof<string, nothing> {
  let name = (^git -C $repo branch --show-current | str trim)
  if ($name | is-empty) { null } else { $name }
}

export def local-branch-exists [repo: path, branch: string]: nothing -> bool {
  let out = (^git -C $repo rev-parse --verify --quiet $"refs/heads/($branch)" | complete)
  $out.exit_code == 0
}

def config-value [rows: table, key: string]: nothing -> oneof<string, nothing> {
  let hits = ($rows | where key == $key | get value)
  if ($hits | is-empty) { null } else { $hits | first }
}

# A branch name can contain dots, so it is not split on them.
export def branch-records [repo: path]: nothing -> table {
  let key = ($BASE_KEY | str lowercase)
  let sha_key = ($BASE_SHA_KEY | str lowercase)
  let out = (^git -C $repo config --get-regexp $"^branch\\..+\\.($key)\(sha\)?$" | complete)
  if $out.exit_code != 0 { return [] }
  let parsed = ($out.stdout
    | lines
    | parse --regex $"^branch\\.\(?<branch>.+\)\\.\(?<key>($sha_key)|($key)\) \(?<value>\\S+\)$")
  $parsed | get branch | uniq | each {|b|
    let rows = ($parsed | where branch == $b)
    {
      branch: $b
      base: (config-value $rows $key)
      sha: (config-value $rows $sha_key)
    }
  }
}

export def set-branch-base [
  repo: path
  branch: string
  base: string
  sha: string
]: nothing -> nothing {
  ^git -C $repo config set $"branch.($branch).($BASE_KEY)" $base
  ^git -C $repo config set $"branch.($branch).($BASE_SHA_KEY)" $sha
}

export def clear-branch-base [repo: path, branch: string]: nothing -> nothing {
  ^git -C $repo config unset $"branch.($branch).($BASE_KEY)" | complete | ignore
  ^git -C $repo config unset $"branch.($branch).($BASE_SHA_KEY)" | complete | ignore
}

# `gh repo clone` sets origin/HEAD. The `gh` call covers other clones.
export def default-branch [repo: path]: nothing -> oneof<string, nothing> {
  let head = (^git -C $repo symbolic-ref --short refs/remotes/origin/HEAD | complete)
  if $head.exit_code == 0 {
    return ($head.stdout | str trim | str replace --regex '^origin/' '')
  }
  if not (tool-installed "gh") { return null }
  let out = (do { cd $repo; ^gh repo view --json defaultBranchRef } | complete)
  if $out.exit_code != 0 { return null }
  $out.stdout | from json | get defaultBranchRef.name
}

export def remote-branch-exists [repo: path, branch: string]: nothing -> bool {
  let out = (^git -C $repo rev-parse --verify --quiet $"refs/remotes/origin/($branch)" | complete)
  $out.exit_code == 0
}

const PR_LIST_LIMIT = 100

# Scoped to `--author @me`: an unscoped list truncates in a busy repo and can
# drop the edge you need. `pr-for-branch` covers the rest.
export def repo-prs [repo: path]: nothing -> table {
  if not (tool-installed "gh") { return [] }
  let out = (do {
    cd $repo
    ^gh pr list --author @me --json number,headRefName,baseRefName,url --limit $PR_LIST_LIMIT
  } | complete)
  if $out.exit_code != 0 { return [] }
  $out.stdout | from json
}

export def pr-for-branch [repo: path, branch: string]: nothing -> oneof<record, nothing> {
  if not (tool-installed "gh") { return null }
  let out = (do {
    cd $repo
    ^gh pr list --head $branch --json number,headRefName,baseRefName,url --limit 1
  } | complete)
  if $out.exit_code != 0 { return null }
  let rows = ($out.stdout | from json)
  if ($rows | is-empty) { null } else { $rows | first }
}

# A recorded base whose branch is gone is a merged parent. It falls through to
# the PR, which GitHub retargets on merge.
export def resolve-base [
  repo: path
  branch: string
  records: table
  prs: table
  default: oneof<string, nothing>
]: nothing -> record {
  let recorded = ($records | where branch == $branch)
  if ($recorded | is-not-empty) {
    let r = ($recorded | first)
    if $r.base != null and (local-branch-exists $repo $r.base) {
      return { base: $r.base, sha: $r.sha, source: "recorded" }
    }
  }
  let bulk = ($prs | where headRefName == $branch)
  let pr = if ($bulk | is-not-empty) {
    $bulk | first
  } else if (remote-branch-exists $repo $branch) {
    pr-for-branch $repo $branch
  }
  if $pr != null {
    return { base: $pr.baseRefName, sha: null, source: "pr" }
  }
  if $default != null and $branch != $default {
    return { base: $default, sha: null, source: "default" }
  }
  { base: null, sha: null, source: null }
}

# Tip first. The last row's base is the root.
export def branch-chain [
  repo: path
  branch: string
  records: table
  prs: table
  default: oneof<string, nothing>
]: nothing -> table {
  mut chain = []
  mut seen = []
  mut current = $branch
  loop {
    if ($current in $seen) {
      error make --unspanned {
        msg: $"Base chain for '($branch)' cycles at '($current)'."
        code: "workspace::base_chain_cycle"
        help: "Point one branch at a different base with `workspace branch base <ref>`."
      }
    }
    if ($chain | length) >= $CHAIN_DEPTH_LIMIT {
      error make --unspanned {
        msg: $"Base chain for '($branch)' is deeper than ($CHAIN_DEPTH_LIMIT) links."
        code: "workspace::base_chain_too_deep"
        help: "Inspect the chain with `workspace branch base`, then shorten it with `workspace branch base <ref>`."
      }
    }
    $seen = ($seen | append $current)
    let resolved = (resolve-base $repo $current $records $prs $default)
    if $resolved.base == null { break }
    $chain = ($chain | append {
      branch: $current
      base: $resolved.base
      sha: $resolved.sha
      source: $resolved.source
    })
    if $resolved.base == $default { break }
    if not (local-branch-exists $repo $resolved.base) { break }
    $current = $resolved.base
  }
  $chain
}

def upstream-divergence [repo: path]: nothing -> record {
  let counts = (^git -C $repo rev-list --count --left-right "@{upstream}...HEAD" | complete)
  if $counts.exit_code != 0 {
    return { ahead: null, behind: null }
  }
  let pair = ($counts.stdout | str trim | split row --regex '\s+')
  { ahead: ($pair | get 1 | into int), behind: ($pair | get 0 | into int) }
}

const PR_FIELDS = "number,url,state,isDraft,reviewDecision,mergeable,statusCheckRollup"

def branch-pr [repo: path, upstream: bool]: nothing -> oneof<record, nothing> {
  if (not $upstream) or (not (tool-installed "gh")) {
    return null
  }
  let out = (do { cd $repo; ^gh pr view --json $PR_FIELDS } | complete)
  if $out.exit_code != 0 {
    return null
  }
  $out.stdout | from json
}

# A check run carries `conclusion` once finished. A commit status carries
# `state`.
def check-verdict [entry: record]: nothing -> string {
  let conclusion = ($entry.conclusion? | default "")
  if ($conclusion | is-not-empty) {
    return (match $conclusion {
      "SUCCESS" | "NEUTRAL" | "SKIPPED" => "passing"
      "FAILURE" | "TIMED_OUT" | "CANCELLED" | "ACTION_REQUIRED" | "STARTUP_FAILURE" => "failing"
      _ => "pending"
    })
  }
  match ($entry.state? | default "") {
    "SUCCESS" => "passing"
    "FAILURE" | "ERROR" => "failing"
    _ => "pending"
  }
}

def checks-state [rollup: list]: nothing -> oneof<string, nothing> {
  if ($rollup | is-empty) { return null }
  let verdicts = ($rollup | each {|entry| check-verdict $entry })
  match $verdicts {
    _ if "failing" in $verdicts => "failing"
    _ if "pending" in $verdicts => "pending"
    _ => "passing"
  }
}

# Only the first gate reports: it is what has to change before the PR merges.
def pr-tag [pr: record]: nothing -> record {
  let checks = (checks-state ($pr.statusCheckRollup? | default []))
  let review = ($pr.reviewDecision? | default "")
  match $pr {
    _ if $pr.state == "MERGED" => { label: "merged", paint: (ansi purple) }
    _ if $pr.state == "CLOSED" => { label: "closed", paint: (ansi red) }
    _ if $pr.isDraft => { label: "draft", paint: (ansi dark_gray) }
    _ if $review == "CHANGES_REQUESTED" => { label: "changes requested", paint: (ansi red) }
    _ if $checks == "failing" => { label: "checks failing", paint: (ansi red) }
    _ if $pr.mergeable? == "CONFLICTING" => { label: "conflicts", paint: (ansi red) }
    _ if $checks == "pending" => { label: "checks running", paint: (ansi yellow) }
    _ if $review == "APPROVED" => { label: "approved", paint: (ansi green) }
    _ => { label: "in review", paint: (ansi blue) }
  }
}

def pr-link [pr: oneof<record, nothing>]: nothing -> any {
  if $pr == null { return null }
  let tag = (pr-tag $pr)
  $pr.url | ansi link --text $"($tag.paint)#($pr.number) ($tag.label)(ansi reset)"
}

# A detached HEAD reports synced. Its branch name already says detached.
def upstream-state [repo: path, branch: string, divergence: record]: nothing -> string {
  if $divergence.ahead != null {
    return (if ($divergence.ahead > 0) or ($divergence.behind > 0) {
      "out-of-sync"
    } else {
      "synced"
    })
  }
  if ($branch | is-empty) { return "synced" }
  # A configured remote with no tracking branch means it was deleted.
  let configured = (^git -C $repo config --get $"branch.($branch).remote" | complete)
  if $configured.exit_code == 0 { "gone" } else { "unpushed" }
}

def mark-branch [branch: string, state: string]: nothing -> string {
  match $state {
    "out-of-sync" => $"(ansi yellow)($branch)(ansi reset)"
    "unpushed" => $"(ansi dark_gray)($branch)(ansi reset)"
    "gone" => $"(ansi attr_strike)(ansi red)($branch)(ansi reset)"
    _ => $branch
  }
}

export def repo-summary [repo: path]: nothing -> record {
  let current = (^git -C $repo branch --show-current | str trim)
  let branch = if ($current | is-empty) {
    let sha = (^git -C $repo rev-parse --short HEAD | str trim)
    $"detached@($sha)"
  } else {
    $current
  }
  let porcelain = (^git -C $repo status --porcelain)
  let divergence = (upstream-divergence $repo)
  let pr = (branch-pr $repo ($divergence.ahead != null))
  {
    name: ($repo | path basename)
    branch: (mark-branch $branch (upstream-state $repo $current $divergence))
    status: (if ($porcelain | str trim | is-empty) { "clean" } else { "dirty" })
    ...$divergence
    pr: (pr-link $pr)
  }
}

export def repo-summaries [name: string]: nothing -> table {
  workspace-repos $name | par-each --keep-order {|r| repo-summary $r }
}

export def workspace-entry-sizes [name: string]: nothing -> table {
  let dir = (workspace-dir $name)
  let home = ($name == (workspace-home))
  # The home workspace is itself the repo, and it contains the workspaces root.
  let inputs = if $home { [$dir] } else { ls --all $dir | get name }
  let ignore = if $home {
    [--ignore-dirs $env.WORKBENCH_WORKSPACES_ROOT]
  } else {
    []
  }
  let rows = match ($inputs | length) {
    # `dua` with no inputs measures the cwd.
    0 => []
    _ => (dua-rows ...$ignore ...$inputs)
  }
  match ($inputs | length) {
    # `dua` lists the children of a lone directory input, not the input.
    1 => [{ path: $inputs.0 size: ($rows | get size | math sum | default 0b) }]
    _ => $rows
  }
}

def dua-rows [...args: string]: nothing -> table {
  ^dua aggregate --format bytes --no-total --no-sort ...$args
  | complete
  | get stdout
  | lines
  | parse --regex '^\s*(?<bytes>\d+) b (?<path>.+)$'
  | each {|row| { path: $row.path size: ($row.bytes | into filesize) } }
}

def workspace-usage [names: list<string>]: nothing -> record {
  $names
  | par-each {|n| { $n: (workspace-entry-sizes $n) } }
  | reduce --fold {} {|it, acc| $acc | merge $it }
}

def usage-total [entries?: table]: nothing -> oneof<filesize, nothing> {
  match $entries {
    null => null
    _ => ($entries | get size | math sum | default 0b)
  }
}

def size-suffix [size?: filesize]: nothing -> string {
  match $size {
    null => ""
    _ => $" (ansi dark_gray)\(($size)\)(ansi reset)"
  }
}

def match-workspaces [query: string, pool: list<string>]: nothing -> list<string> {
  if $query in $pool {
    [$query]
  } else {
    $pool | where {|n| $n | str contains --ignore-case $query }
  }
}

def print-workspace-contents [
  name: string
  usage?: table
]: nothing -> nothing {
  let dir = (workspace-dir $name)
  if $name == (workspace-home) {
    print $"  (ansi cyan)($name)(ansi reset)(size-suffix (usage-total $usage)) (ansi yellow)[meta: repo preserved; only the Zellij session is removed](ansi reset)"
    let saved = (read-session-name $dir)
    if $saved != null {
      print $"    (ansi magenta)Zellij session: ($saved)(ansi reset)"
    }
    return
  }
  let repos = (repo-summaries $name)
  let dirty = ($repos | where status == "dirty" | length)
  let unpushed = ($repos | where ($it.ahead | default 0) > 0 | length)
  let note = ([
    (if $dirty > 0 { $"($dirty) dirty repo\(s\)" })
    (if $unpushed > 0 { $"($unpushed) repo\(s\) with unpushed commits" })
  ] | compact | if ($in | is-empty) {
    ""
  } else {
    $" (ansi red)[($in | str join '; ')](ansi reset)"
  })
  print $"  (ansi cyan)($name)(ansi reset)(size-suffix (usage-total $usage))($note)"
  let saved = (read-session-name $dir)
  if $saved != null {
    print $"    (ansi magenta)Zellij session: ($saved)(ansi reset)"
  }
  let entries = (ls --all $dir | sort-by name)
  if ($entries | is-empty) {
    print $"    (ansi dark_gray)\(empty\)(ansi reset)"
    return
  }
  for entry in $entries {
    let base = ($entry.name | path basename)
    let repo = ($repos | where name == $base | get 0?)
    let detail = if $repo != null {
      let ahead = (if ($repo.ahead | default 0) > 0 { $", ahead ($repo.ahead)" } else { "" })
      $" (ansi dark_gray)[($repo.branch)(ansi dark_gray), ($repo.status)($ahead)](ansi reset)"
    } else {
      ""
    }
    let size = ($usage | default [] | where path == $entry.name | get 0?.size)
    print $"    ($base)(size-suffix $size)($detail)"
  }
}

# An exact name or a unique substring resolves without a picker. A query that
# matches nothing opens the picker over everything.
#
# --list-contents assumes every selection is a workspace, so it cannot be used
# with --with-orphans.
export def select-workspaces [
  query?: string                        # Name or partial; omit to pick from all
  --multi (-m)                          # Allow selecting several; off → single
  --confirm                             # Require a yes/no gate after selection
  --list-contents                       # Print each selection's contents first
  --color-state                         # Color picker entries by their Zellij session state
  --with-orphans                        # Also offer orphan Zellij sessions as candidates
  --show-size                           # Show each workspace's size after its name
  --prompt (-p): string = "Workspace:"  # Picker title + confirm/contents header
]: nothing -> list<string> {
  let ws_names = (workspace-names)
  let sessions = (if $color_state or $with_orphans { zellij-sessions } else { [] })
  let orphans = (if $with_orphans { orphan-sessions --sessions $sessions } else { [] })
  let all = (($ws_names ++ ($orphans | get name)) | sort --ignore-case)
  if ($all | is-empty) {
    error make --unspanned {
      msg: "No workspaces found."
      code: "workspace::no_workspaces"
      help: "Create one with `workspace new <name> [<repo>...]`."
    }
  }

  let matches = if $query == null { $all } else { match-workspaces $query $all }
  let candidates = if ($matches | is-empty) { $all } else { $matches }
  let direct = ($query != null) and (($matches | length) == 1)

  let usage = if $show_size and (tool-installed "dua") {
    workspace-usage ($candidates | where $it in $ws_names)
  } else {
    {}
  }

  let selection = if $direct {
    $matches
  } else {
    let home = (workspace-home)
    let items = ($candidates | each {|n|
      let label = if not $color_state {
        $n
      } else if $n in $ws_names {
        let saved = (read-session-name (workspace-dir $n))
        let state = (if ($saved | is-not-empty) { session-state $saved $sessions })
        paint-state $n $state ($n == $home)
      } else {
        let state = ($orphans | where name == $n | get 0?.state)
        $"(paint-state $n $state false) (ansi dark_gray)\(orphan\)(ansi reset)"
      }
      { name: $n, label: $"($label)(size-suffix (usage-total ($usage | get --optional $n)))" }
    })
    let disp = {|it| $it.label }
    if $multi {
      $items | input list --multi --fuzzy --display $disp $prompt | each {|it| $it.name }
    } else {
      let one = ($items | input list --fuzzy --display $disp $prompt)
      if $one == null { [] } else { [$one.name] }
    }
  }

  if ($selection | is-empty) {
    return []
  }

  if $list_contents {
    print $prompt
    for name in $selection {
      print-workspace-contents $name ($usage | get --optional $name)
    }
  } else if $confirm {
    print $prompt
    for name in $selection {
      print $"  ($name)(size-suffix (usage-total ($usage | get --optional $name)))"
    }
  }

  if $confirm {
    if not (confirm-prompt "Confirm?") {
      print "Aborted."
      return []
    }
  }

  $selection
}

export def select-workspace [choose: bool]: nothing -> string {
  if $choose {
    let sel = (select-workspaces --prompt "Workspace:")
    if ($sel | is-empty) {
      error make --unspanned {
        msg: "Nothing selected."
        code: "workspace::nothing_selected"
      }
    }
    $sel | first
  } else {
    let inferred = (try-infer-workspace)
    if $inferred == null {
      error make --unspanned {
        msg: "Not inside a workspace."
        code: "workspace::not_in_workspace"
        help: "cd into one with `workspace enter`, or pass --choose to pick one."
      }
    }
    $inferred
  }
}

# `dir` and `workspace` are null for an orphan session.
export def select-zellij-target [choose: bool]: nothing -> record {
  if not $choose {
    let name = (select-workspace false)
    let dir = (workspace-dir $name)
    return {
      session: (read-session-name $dir | default $name)
      dir: $dir
      workspace: $name
    }
  }

  let sessions = (zellij-sessions)
  let home = (workspace-home)
  let ws_items = (workspace-names | each {|n|
    let saved = (read-session-name (workspace-dir $n))
    let state = (if ($saved | is-not-empty) { session-state $saved $sessions })
    {
      name: $n
      session: ($saved | default $n)
      dir: (workspace-dir $n)
      workspace: $n
      label: (paint-state $n $state ($n == $home))
    }
  })
  let orphan_items = (orphan-sessions --sessions $sessions | each {|s|
    {
      name: $s.name
      session: $s.name
      dir: null
      workspace: null
      label: $"(paint-state $s.name $s.state false) (ansi dark_gray)\(orphan\)(ansi reset)"
    }
  })

  let picked = ($ws_items ++ $orphan_items
    | sort-by --ignore-case name
    | input list --fuzzy --display {|it| $it.label } "Session:")
  if $picked == null {
    error make --unspanned {
      msg: "Nothing selected."
      code: "workspace::nothing_selected"
    }
  }
  {
    session: $picked.session
    dir: $picked.dir
    workspace: $picked.workspace
  }
}

# The git repo holding PWD, when PWD is outside every workspace.
export def loose-repo []: nothing -> oneof<path, nothing> {
  if (try-infer-workspace) != null { return null }
  let out = (^git -C $env.PWD rev-parse --show-toplevel | complete)
  if $out.exit_code != 0 { return null }
  $out.stdout | str trim
}

# Outside a workspace, falls back to the enclosing git repo, so a plain
# checkout such as nix-config works too.
export def target-repos [
  choose: bool
  only: oneof<string, nothing>
  verb: string   # What the command does, for the outside-a-workspace warning
]: nothing -> list<path> {
  let loose = (if $choose { null } else { loose-repo })
  if $loose != null {
    let name = ($loose | path basename)
    if $only != null and $only != $name {
      error make --unspanned {
        msg: $"No repo '($only)' here."
        code: "workspace::unknown_repo"
        help: $"Outside a workspace this acts on '($name)' alone."
      }
    }
    print $"(ansi yellow)Not in a workspace; ($verb) only ($name)(ansi reset)"
    return [$loose]
  }
  let all = (workspace-repos (select-workspace $choose))
  if ($all | is-empty) {
    error make --unspanned {
      msg: "No git repos found in this workspace."
      code: "workspace::no_repos"
      help: "Clone one with `workspace clone <repo>`."
    }
  }
  if $only == null { return $all }
  let hit = ($all | where {|r| ($r | path basename) == $only })
  if ($hit | is-empty) {
    let names = ($all | each {|r| $r | path basename } | str join ", ")
    error make --unspanned {
      msg: $"No repo '($only)' in this workspace."
      code: "workspace::unknown_repo"
      help: $"Available: ($names)."
    }
  }
  $hit
}
