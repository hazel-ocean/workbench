# Workspace utility commands.
#
# `workspace/mod.nu` pulls these in with `use util.nu *`. Because that is a plain
# `use` (not `export use`), they stay internal to the workspace module and out
# of the public `workspace` overlay: the user-facing command surface lives in
# workspace/mod.nu.

# The meta workspace's name: the workbench repo root's basename.
export def workspace-home []: nothing -> string {
  $env.WORKBENCH_WORKSPACES_ROOT | path dirname | path basename
}

# Absolute dir for a workspace name; the meta home maps to the repo root.
export def workspace-dir [name: string]: nothing -> path {
  if $name == (workspace-home) {
    $env.WORKBENCH_WORKSPACES_ROOT | path dirname
  } else {
    $env.WORKBENCH_WORKSPACES_ROOT | path join $name
  }
}

# All workspace names, case-insensitive alphabetical, with the meta home folded
# in among the immediate subdirs (excluding "_"-prefixed) rather than pinned first.
#
# Git can't track the empty workspaces root, so a fresh clone has none until the
# first `workspace new`; a missing root means no workspaces, not an error.
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

# True when an external tool is on PATH.
#
# `complete` traps a non-zero exit but not a missing binary: nushell raises
# before the pipeline runs, so every call that shells out to zellij or gh has to
# ask this first.
export def tool-installed [tool: string]: nothing -> bool {
  which $tool | is-not-empty
}

# Stop with a named error when a tool the command cannot work without is missing.
export def assert-tool [tool: string, purpose: string]: nothing -> nothing {
  if not (tool-installed $tool) {
    error make --unspanned {
      msg: $"'($tool)' is not installed."
      code: "workspace::missing_tool"
      help: $"Install ($tool) to ($purpose)."
    }
  }
}

# Width of the on-screen ruler guide in the session-name prompt. Zellij enforces
# its own session-name rules; this only sizes the visual guide, never validates.
const ZELLIJ_RULER_WIDTH = 24

# Filename, at a workspace root, storing that workspace's Zellij session name so
# later runs reuse it without prompting.
const ZELLIJ_SESSION_FILE = ".zellij_session"

# Prompt for a Zellij session name, showing `message` and a width ruler as a
# guide. With --default, the value is prefilled so Enter accepts it; without it,
# empty input returns "" so the caller can treat that as cancel. Returns the
# entered name, trimmed.
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

# Yes/no confirmation defaulting to NO. Prints "<message> (y/N) > " and waits for
# a single keypress: only 'y'/'Y' confirms; Enter, Esc, any other key, or the
# timeout all decline. Modelled on the nix-config `system aliases` prompt.
export def confirm-prompt [message: string]: nothing -> bool {
  print --no-newline $"($message) \(y/N\) > "
  let key = ((input listen --timeout 20sec --types [key]).code? | default "")
  print $key  # echo the keypress, which `input listen` swallows
  ($key | str lowercase) == "y"
}

# Saved Zellij session name for a workspace dir, or null if none/empty.
export def read-session-name [dir: path]: nothing -> oneof<string, nothing> {
  let file = ($dir | path join $ZELLIJ_SESSION_FILE)
  if not ($file | path exists) { return null }
  let name = (open $file | str trim)
  if ($name | is-empty) { null } else { $name }
}

# Persist the chosen Zellij session name for a workspace dir.
export def save-session-name [dir: path, name: string]: nothing -> nothing {
  $name | save --force ($dir | path join $ZELLIJ_SESSION_FILE)
}

# Remove a workspace's saved Zellij session-name file, if present.
export def remove-session-name [dir: path]: nothing -> nothing {
  let file = ($dir | path join $ZELLIJ_SESSION_FILE)
  if ($file | path exists) { rm --force $file }
}

# Rewrite the Zellij session name in clawd-back's per-session state files after a
# rename, so notify/click keep resolving the right pane. Handles both the current
# nested schema (`multiplexer.session`) and the legacy flat `zellij_session_id`.
# Best-effort.
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

# Kill a running Zellij session, leaving it resurrectable. Best-effort.
export def zellij-kill-session [name: string]: nothing -> nothing {
  if not (tool-installed "zellij") { return }
  let result = (^zellij kill-session -- $name | complete)
  if $result.exit_code != 0 {
    print $"(ansi yellow)could not kill Zellij session '($name)': ($result.stderr | str trim)(ansi reset)"
  }
}

# Delete a Zellij session entirely: kill it if running, then drop its
# resurrectable state. Best-effort.
export def zellij-delete-session [name: string]: nothing -> nothing {
  if not (tool-installed "zellij") { return }
  let result = (^zellij delete-session --force -- $name | complete)
  if $result.exit_code != 0 {
    print $"(ansi yellow)could not delete Zellij session '($name)': ($result.stderr | str trim)(ansi reset)"
  }
}

# Rename a live Zellij session. Best-effort; returns true on success. Only works
# while the session's server is running (an EXITED/resurrectable session has no
# server to act on), so callers should not persist the new name on a false.
export def zellij-rename-session [from: string, to: string]: nothing -> bool {
  if not (tool-installed "zellij") { return false }
  let result = (^zellij --session $from action rename-session -- $to | complete)
  if $result.exit_code != 0 {
    print $"(ansi yellow)could not rename Zellij session '($from)' -> '($to)': ($result.stderr | str trim)(ansi reset)"
    return false
  }
  true
}

# True if a Zellij session with this exact name currently exists.
export def zellij-session-exists [name: string]: nothing -> bool {
  if not (tool-installed "zellij") { return false }
  ^zellij list-sessions --no-formatting --short
  | complete
  | get stdout
  | lines
  | any {|s| ($s | str trim) == $name }
}

# All Zellij sessions as {name, state} rows sorted case-insensitively by name,
# where state is "active" for a running session or "exited" for a resurrectable
# one. `--short` is avoided
# because it drops the EXITED marker we classify on. Best-effort: any failure
# (or no sessions) yields []. Real session lines always carry a "[Created ...]"
# stamp, which also filters out the "No active zellij sessions" notice.
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
        # Split on " [Created" (not " ") so multi-word session names survive.
        name: ($line | split row " [Created" | first | str trim)
        state: (if ($line | str contains "EXITED") { "exited" } else { "active" })
      }
    }
  | sort-by --ignore-case name
}

# Session names claimed by some workspace's saved `.zellij_session`. The set a
# live session must fall outside of to count as an orphan.
export def claimed-sessions []: nothing -> list<string> {
  workspace-names
  | each {|n| read-session-name (workspace-dir $n) }
  | compact
}

# Live Zellij sessions owned by no workspace: started outside the workspace
# tooling (other repos, ad-hoc). Rows are {name, state} as from `zellij-sessions`.
# Pass --sessions to reuse an already-computed session table.
export def orphan-sessions [
  --sessions: table   # Precomputed `zellij-sessions`; omit to fetch fresh
]: nothing -> table {
  let all = ($sessions | default (zellij-sessions))
  let claimed = (claimed-sessions)
  $all | where name not-in $claimed
}

# The live name of the pane's own Zellij session, or null when not inside Zellij
# (or on any failure). `zellij list-sessions` marks the attached session with a
# trailing "(current)"; that marker stays correct after a Zellij-UI rename, while
# $env.ZELLIJ_SESSION_NAME goes stale (captured at pane spawn). Split on
# " [Created" rather than " " so multi-word session names survive.
export def zellij-current-session []: nothing -> oneof<string, nothing> {
  if not (tool-installed "zellij") { return null }
  let result = (^zellij list-sessions --no-formatting | complete)
  if $result.exit_code != 0 { return null }
  let line = ($result.stdout | lines | where {|l| $l | str contains "(current)" } | get 0?)
  if $line == null { return null }
  let name = ($line | str trim | split row " [Created" | first | str trim)
  if ($name | is-empty) { null } else { $name }
}

# The focused Ghostty window's current title, or null if it can't be read (not
# Ghostty, no osascript, no window). Reading the `name` works even though setting
# it does not. Best-effort.
export def ghostty-title []: nothing -> oneof<string, nothing> {
  let result = (^osascript -e 'tell application "Ghostty" to get name of front window' | complete)
  if $result.exit_code != 0 { return null }
  let title = ($result.stdout | str trim)
  if ($title | is-empty) { null } else { $title }
}

# Pin the focused Ghostty tab's title to `title` via the "Change Tab Title..."
# action (see the AppleScript for why UI automation is the only durable path).
# Best-effort: needs Accessibility permission and the target tab focused, so a
# failure is noted, not fatal.
export def ghostty-set-title [title: string]: nothing -> nothing {
  const script = (path self | path dirname | path dirname
    | path join "applescript" "ghostty-set-title.applescript")
  let result = (^osascript $script $title | complete)
  if $result.exit_code != 0 {
    print $"(ansi yellow)could not set Ghostty title to '($title)': ($result.stderr | str trim)(ansi reset)"
  }
}

# State of a saved session name against the session table:
#   name is active  → "active"   (running)
#   name is exited  → "exited"   (resurrectable via attach)
#   name not listed → "offline"  (saved name matches no Zellij session)
#
# Callers guard for "no session saved" (a null name) themselves before calling.
export def session-state [
  saved: string    # A workspace's saved session name
  sessions: table  # Rows from `zellij-sessions`
]: nothing -> string {
  let match = ($sessions | where name == $saved)
  if ($match | is-empty) { "offline" } else { $match | first | get state }
}

# Paint `text` by a session state: an active meta workbench is purple, an active
# workspace is blue, a dormant saved session is red (both "exited", still
# resurrectable, and "offline", the saved name is gone from Zellij entirely).
# When there is no saved session at all (null state), `text` is returned as-is.
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

# Attach to (or create) a Zellij session in `dir`, re-prompting on a bad name.
#
# The name is created detached first (`--create-background | complete`) so an
# invalid name comes back as captured stderr rather than a half-torn-down
# terminal, keeping the re-prompt in a clean terminal. The settled name is
# saved to the workspace so later runs can reuse it. Steps:
#   1. With --prompt, prompt for a name up front, prefilled with `session`
#      (Enter accepts it).
#   2. If we're already in that session, there's nothing to do.
#   3. If the session already exists, attach to it.
#   4. Otherwise create it detached; on success, attach.
#   5. On failure, print the literal stderr + exit code (red), prompt for a
#      different name (no prefill), and go to 2. Empty input cancels.
#
# Final step uses `switch-session` when already in a session (a plain attach
# stalls when nested), else `attach`.
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
  loop {
    if $session == ($env.ZELLIJ_SESSION_NAME? | default "") {
      print $"Already in Zellij session '($session)'."
      save-session-name $dir $session
      return
    }
    if (zellij-session-exists $session) { break }
    # `--` so a name beginning with `-` is taken as the session, not a flag.
    let result = (^zellij attach --create-background -- $session | complete)
    if $result.exit_code == 0 { break }
    print $"(ansi red)($result.stderr)(ansi reset)"
    print $"(ansi red)exit code: ($result.exit_code)(ansi reset)"
    let next = (prompt-session-name "Zellij couldn't create that session. Enter a different name:")
    if ($next | is-empty) { print "Cancelled."; return }
    $session = $next
  }
  save-session-name $dir $session
  # Nested `attach` stalls; switch instead when already in a session.
  if ($env.ZELLIJ_SESSION_NAME? | default "" | is-not-empty) {
    ^zellij action switch-session -- $session
  } else {
    ^zellij attach -- $session
  }
}

# Attach to (or switch to, when already nested) an existing Zellij session by
# name. For orphan sessions owned by no workspace: there's no dir to launch from
# and no `.zellij_session` to persist, so this skips the create/prompt/save path
# of `zellij-attach`. Assumes the session already exists (active or exited).
export def zellij-attach-existing [session: string]: nothing -> nothing {
  assert-tool "zellij" "attach to a session"
  if $session == ($env.ZELLIJ_SESSION_NAME? | default "") {
    print $"Already in Zellij session '($session)'."
    return
  }
  # Nested `attach` stalls; switch instead when already in a session.
  if ($env.ZELLIJ_SESSION_NAME? | default "" | is-not-empty) {
    ^zellij action switch-session -- $session
  } else {
    ^zellij attach -- $session
  }
}

# Infer the current workspace name from $env.PWD, or null if not inside one.
#
# A path under workspaces/<name>/… resolves to that workspace; anywhere else
# inside the workbench repo (including the root and workspaces/ itself) resolves
# to the meta home workspace.
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

# List the git repos in a workspace. Normal workspaces contain a repo per
# immediate subdirectory; the meta home workspace's only repo is the root itself.
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

# Git config keys recording which branch a branch was built on, and that
# branch's tip at the time. Git owns the `branch.<name>` section, so a branch
# rename carries these keys and a branch delete removes them. Git lowercases the
# key when it stores it, so `--get-regexp` patterns must match the lowered form.
const BASE_KEY = "workbenchBase"
const BASE_SHA_KEY = "workbenchBaseSha"

# Longest base chain `branch-chain` will walk before calling it malformed.
const CHAIN_DEPTH_LIMIT = 10

# The current branch of a repo, or null when HEAD is detached.
export def current-branch [repo: path]: nothing -> oneof<string, nothing> {
  let name = (^git -C $repo branch --show-current | str trim)
  if ($name | is-empty) { null } else { $name }
}

export def local-branch-exists [repo: path, branch: string]: nothing -> bool {
  let out = (^git -C $repo rev-parse --verify --quiet $"refs/heads/($branch)" | complete)
  $out.exit_code == 0
}

# The single value of `key` among a branch's parsed config rows, or null.
def config-value [rows: table, key: string]: nothing -> oneof<string, nothing> {
  let hits = ($rows | where key == $key | get value)
  if ($hits | is-empty) { null } else { $hits | first }
}

# Every branch's recorded base and base sha, as a `branch`/`base`/`sha` table.
#
# One `git config` call returns the whole repo, so a caller iterating branches
# reads once and filters. A branch name may contain dots and slashes, so the
# name is parsed as everything between the `branch.` prefix and the trailing
# key rather than by splitting on dots.
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

# Record the branch a branch is built on, and that branch's current tip.
export def set-branch-base [
  repo: path
  branch: string
  base: string
  sha: string
]: nothing -> nothing {
  ^git -C $repo config set $"branch.($branch).($BASE_KEY)" $base
  ^git -C $repo config set $"branch.($branch).($BASE_SHA_KEY)" $sha
}

# Drop a branch's recorded base. Unsetting a missing key is not an error here.
export def clear-branch-base [repo: path, branch: string]: nothing -> nothing {
  ^git -C $repo config unset $"branch.($branch).($BASE_KEY)" | complete | ignore
  ^git -C $repo config unset $"branch.($branch).($BASE_SHA_KEY)" | complete | ignore
}

# The repo's default branch, or null when neither source answers.
#
# `gh repo clone` sets `refs/remotes/origin/HEAD`, so the local read almost
# always wins; the `gh` call covers a clone made some other way, at the cost of
# a network round trip.
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

# True when origin has a branch of this name, i.e. the branch has been pushed.
export def remote-branch-exists [repo: path, branch: string]: nothing -> bool {
  let out = (^git -C $repo rev-parse --verify --quiet $"refs/remotes/origin/($branch)" | complete)
  $out.exit_code == 0
}

const PR_LIST_LIMIT = 100

# Your open PRs in a repo. Each row's head and base are one edge of a branch
# stack, so a single call resolves every link of a stack you own.
#
# Scoped to `--author @me` because an unscoped list truncates at
# $PR_LIST_LIMIT in a busy repo, and silently dropping the edge you need is
# worse than missing someone else's PR. `pr-for-branch` covers the remainder.
export def repo-prs [repo: path]: nothing -> table {
  if not (tool-installed "gh") { return [] }
  let out = (do {
    cd $repo
    ^gh pr list --author @me --json number,headRefName,baseRefName,url --limit $PR_LIST_LIMIT
  } | complete)
  if $out.exit_code != 0 { return [] }
  $out.stdout | from json
}

# The open PR whose head is `branch`, or null. One network call, so callers
# reach for it only when the bulk `repo-prs` table has no row for the branch.
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

# Which branch `branch` is built on: `{ base, sha, source }`.
#
# `source` is how the base was found, in the order tried:
#   recorded  the git config record, when the branch it names still exists
#   pr        the base of the branch's open PR
#   default   the repo default branch
#
# A recorded base whose branch is gone is the merged-parent case: it falls
# through to the PR, which GitHub retargets on merge. All three are null when
# nothing resolves, which is the root of a chain.
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
    # Not one of yours, or older than the bulk window. An unpushed branch has no
    # PR to find, so the remote check keeps the extra call off the common path.
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

# The stack `branch` sits in, tip first, one row per link.
#
# Each row is `{ branch, base, sha, source }`. Walking stops at the default
# branch, at a base with no local branch of that name, or when nothing
# resolves; the last row's base is the root, and is the only one to fetch from
# origin. A rebase consumes the rows in reverse, lowest link first.
#
# A cycle or a chain past $CHAIN_DEPTH_LIMIT raises. Callers running across
# repos should wrap this in `try` so one malformed repo does not end the run.
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

# Commits on HEAD that the upstream branch lacks, and the reverse. A branch can
# be both at once, so they are separate counts, not one signed number.
#
# Both are null when there is no upstream: never pushed, or a detached HEAD.
def upstream-divergence [repo: path]: nothing -> record {
  let counts = (^git -C $repo rev-list --count --left-right "@{upstream}...HEAD" | complete)
  if $counts.exit_code != 0 {
    return { ahead: null, behind: null }
  }
  let pair = ($counts.stdout | str trim | split row --regex '\s+')
  { ahead: ($pair | get 1 | into int), behind: ($pair | get 0 | into int) }
}

# The PR for a repo's current branch as `{ number, url, state, isDraft }`, or
# null when there is no PR. A draft reports state OPEN, so its own field has to
# come along. Skipped without an upstream: an unpushed branch cannot have a PR,
# and `gh` costs a network round trip per repo.
def branch-pr [repo: path, upstream: bool]: nothing -> oneof<record, nothing> {
  if (not $upstream) or (not (tool-installed "gh")) {
    return null
  }
  let out = (do { cd $repo; ^gh pr view --json number,url,state,isDraft } | complete)
  if $out.exit_code != 0 {
    return null
  }
  $out.stdout | from json
}

# A PR as a clickable `#<number>`: blue when open, yellow while a draft, struck
# through once it is no longer open.
def pr-link [pr: oneof<record, nothing>]: nothing -> any {
  if $pr == null { return null }
  let paint = match $pr.state {
    "MERGED" => $"(ansi attr_strike)(ansi purple)"
    "CLOSED" => $"(ansi attr_strike)(ansi red)"
    _ => (if $pr.isDraft { (ansi yellow) } else { (ansi blue) })
  }
  $pr.url | ansi link --text $"($paint)#($pr.number)(ansi reset)"
}

# The branch name, marked by the fate of its PR: a check once merged, struck
# through once closed unmerged. An open PR, or no PR, leaves the name plain.
def mark-branch [branch: string, pr: oneof<record, nothing>]: nothing -> string {
  if $pr == null { return $branch }
  match $pr.state {
    "MERGED" => $"($branch) (ansi green)✓(ansi reset)"
    "CLOSED" => $"(ansi attr_strike)($branch)(ansi reset)"
    _ => $branch
  }
}

# Branch, working-tree state, upstream divergence, and PR for a single repo path.
#
# `status` is the working-tree state: `clean` or `dirty`. Detachment shows up in
# `branch`, so a detached HEAD still reports whether it is dirty.
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
    branch: (mark-branch $branch $pr)
    status: (if ($porcelain | str trim | is-empty) { "clean" } else { "dirty" })
    ...$divergence
    pr: (pr-link $pr)
  }
}

export def repo-summaries [name: string]: nothing -> table {
  workspace-repos $name | par-each --keep-order {|r| repo-summary $r }
}

# Names from `pool` matching a query: an exact name wins outright, otherwise
# every name that contains the substring (case-insensitive).
def match-workspaces [query: string, pool: list<string>]: nothing -> list<string> {
  if $query in $pool {
    [$query]
  } else {
    $pool | where {|n| $n | str contains --ignore-case $query }
  }
}

# Print a workspace's name (flagging dirty repos) followed by its full contents,
# including hidden files, so the user sees exactly what a delete/trash removes.
def print-workspace-contents [name: string]: nothing -> nothing {
  let dir = (workspace-dir $name)
  # The meta workspace's repo is never removed, so don't list it as deletable
  # contents; just flag the session that will go.
  if $name == (workspace-home) {
    print $"  (ansi cyan)($name)(ansi reset) (ansi yellow)[meta: repo preserved; only the Zellij session is removed](ansi reset)"
    let saved = (read-session-name $dir)
    if $saved != null {
      print $"    (ansi magenta)Zellij session: ($saved)(ansi reset)"
    }
    return
  }
  let repos = (repo-summaries $name)
  # Unpushed commits die with the workspace just as uncommitted changes do, so
  # both are flagged before a delete or trash.
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
  print $"  (ansi cyan)($name)(ansi reset)($note)"
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
    print $"    ($base)($detail)"
  }
}

# Select one or more workspaces from an optional query.
#
# Resolution ladder:
#   null / empty query   → picker over all workspaces
#   exact name match     → that workspace, no picker
#   unique substring     → that workspace, no picker
#   ambiguous substring  → fuzzy picker narrowed to the matches
#   no substring match   → fuzzy picker over ALL workspaces (fall back)
#
# Matching is case-insensitive; an exact name always wins outright. Returns the
# chosen names; empty when the picker is cancelled or --confirm is declined.
#
# With --with-orphans the candidate pool also includes orphan Zellij sessions
# (live sessions owned by no workspace); a returned name that isn't a workspace
# is such a session. Only meaningful alongside --color-state, and incompatible
# with --list-contents (which assumes every selection is a real workspace dir).
export def select-workspaces [
  query?: string                        # Name or partial; omit to pick from all
  --multi (-m)                          # Allow selecting several; off → single
  --confirm                             # Require a yes/no gate after selection
  --list-contents                       # Print each selection's contents first
  --color-state                         # Color picker entries by their Zellij session state
  --with-orphans                        # Also offer orphan Zellij sessions as candidates
  --prompt (-p): string = "Workspace:"  # Picker title + confirm/contents header
]: nothing -> list<string> {
  let ws_names = (workspace-names)
  # Fetch the session table once when anything below needs it, not per entry.
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

  # A non-null query resolves to its matches; empty matches (and a null query)
  # fall back to every candidate. A lone match is taken directly, no picker.
  let matches = if $query == null { $all } else { match-workspaces $query $all }
  let candidates = if ($matches | is-empty) { $all } else { $matches }
  let direct = ($query != null) and (($matches | length) == 1)

  let selection = if $direct {
    $matches
  } else if $color_state {
    # Show each entry colored by session state. `--display` colors the label but
    # `input list` still returns the original record, so we map back to names.
    let home = (workspace-home)
    let items = ($candidates | each {|n|
      if $n in $ws_names {
        let saved = (read-session-name (workspace-dir $n))
        let state = (if ($saved | is-not-empty) { session-state $saved $sessions })
        { name: $n, label: (paint-state $n $state ($n == $home)) }
      } else {
        let state = ($orphans | where name == $n | get 0?.state)
        { name: $n, label: $"(paint-state $n $state false) (ansi dark_gray)\(orphan\)(ansi reset)" }
      }
    })
    let disp = {|it| $it.label }
    if $multi {
      $items | input list --multi --fuzzy --display $disp $prompt | each {|it| $it.name }
    } else {
      let one = ($items | input list --fuzzy --display $disp $prompt)
      if $one == null { [] } else { [$one.name] }
    }
  } else if $multi {
    $candidates | input list --multi --fuzzy $prompt
  } else {
    let one = ($candidates | input list --fuzzy $prompt)
    if $one == null { [] } else { [$one] }
  }

  if ($selection | is-empty) {
    return []
  }

  if $list_contents {
    print $prompt
    for name in $selection { print-workspace-contents $name }
  } else if $confirm {
    print $prompt
    for name in $selection { print $"  ($name)" }
  }

  if $confirm {
    if not (confirm-prompt "Confirm?") {
      print "Aborted."
      return []
    }
  }

  $selection
}

# Resolve which workspace a user-facing command should target: either via an
# interactive picker (--choose) or by inferring from $env.PWD.
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

# Resolve which Zellij session a `workspace zellij` verb should act on.
#
# Without $choose: the current workspace (inferred from PWD) and its session, the
# saved `.zellij_session` name or, failing that, the workspace name.
#
# With $choose: a picker over every workspace PLUS every orphan live session (one
# owned by no workspace). Picking a workspace resolves as above; picking an
# orphan targets that live session directly.
#
# Returns { session: string, dir: path|null, workspace: string|null }; `dir` and
# `workspace` are null only for an orphan pick, signalling callers to skip any
# `.zellij_session` bookkeeping.
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
