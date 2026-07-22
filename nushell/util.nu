# Workspace utility commands.
#
# `workspace.nu` pulls these in with `use util.nu *`. Because that is a plain
# `use` (not `export use`), they stay internal to the workspace module and out
# of the public `workspace` overlay — the user-facing command surface lives in
# workspace.nu.

# All workspace names (immediate subdirs, excluding "_"-prefixed), sorted.
export def workspace-names []: nothing -> list<string> {
  ls $env.WORKSPACES_ROOT
  | where type == dir
  | get name
  | each { $in | path basename }
  | where {|n| not ($n | str starts-with "_") }
  | sort
}

# Width of the on-screen ruler guide in the session-name prompt. Zellij enforces
# its own session-name rules; this only sizes the visual guide, never validates.
const ZELLIJ_RULER_WIDTH = 24

# Prompt for a Zellij session name, showing `message`, the current name (red),
# and a width ruler as a guide. Returns the entered name, trimmed ("" if empty).
def prompt-session-name [current: string, message: string]: nothing -> string {
  let bar = (0..<($ZELLIJ_RULER_WIDTH - 1) | each {|| "-" } | str join)
  print ([
    ""
    $"(ansi light_blue)($message)(ansi reset)"
    ""
    $"(ansi red)($current)(ansi reset)"
    $"(ansi light_blue)($bar)|(ansi reset) <- Limit"
  ] | str join (char newline))
  let entered = (input $"(ansi light_blue)" | str trim)
  print (ansi reset)  # clear color, and separate this attempt from the next
  $entered
}

# True if a Zellij session with this exact name currently exists.
def zellij-session-exists [name: string]: nothing -> bool {
  ^zellij list-sessions --no-formatting --short
  | complete
  | get stdout
  | lines
  | any {|s| ($s | str trim) == $name }
}

# Attach to (or create) a Zellij session in `dir`, re-prompting on a bad name.
#
# The name is created detached first (`--create-background | complete`) so an
# invalid name comes back as captured stderr rather than a half-torn-down
# terminal — keeping the re-prompt in a clean terminal. Steps:
#   1. With --rename, prompt for a name up front (cancel on empty input).
#   2. If we're already in that session, there's nothing to do.
#   3. If the session already exists, attach to it.
#   4. Otherwise create it detached; on success, attach.
#   5. On failure, print the literal stderr + exit code (red), prompt for a
#      different name, and go to 2. Empty input cancels.
export def zellij-attach [
  dir: path        # Workspace directory to launch from
  session: string  # Initial session name (usually the workspace name)
  --rename         # Prompt for a custom name before the first attempt
]: nothing -> nothing {
  cd $dir
  mut session = $session
  if $rename {
    let named = (prompt-session-name $session "Name the Zellij session:")
    if ($named | is-empty) { print "Cancelled."; return }
    $session = $named
  }
  loop {
    if $session == ($env.ZELLIJ_SESSION_NAME? | default "") {
      print $"Already in Zellij session '($session)'."
      return
    }
    if (zellij-session-exists $session) { break }
    # `--` so a name beginning with `-` is taken as the session, not a flag.
    let result = (^zellij attach --create-background -- $session | complete)
    if $result.exit_code == 0 { break }
    print $"(ansi red)($result.stderr)(ansi reset)"
    print $"(ansi red)exit code: ($result.exit_code)(ansi reset)"
    let next = (prompt-session-name $session "Zellij couldn't create that session. Enter a different name:")
    if ($next | is-empty) { print "Cancelled."; return }
    $session = $next
  }
  ^zellij attach -- $session
}

# Infer the current workspace name from $env.PWD, or null if not inside one.
export def try-infer-workspace []: nothing -> string {
  let root = ($env.WORKSPACES_ROOT | path expand)
  let pwd = ($env.PWD | path expand)
  if $pwd == $root or not ($pwd | str starts-with ($root | path join "")) {
    return null
  }
  $pwd | path relative-to $root | path split | first
}

# List the git repos (immediate subdirectories containing .git) in a workspace.
export def workspace-repos [name: string]: nothing -> list<path> {
  let dir = ($env.WORKSPACES_ROOT | path join $name)
  if not ($dir | path exists) {
    error make { msg: $"Workspace '($name)' does not exist." }
  }
  ls $dir
  | where type == dir
  | get name
  | where {|p| ($p | path join ".git" | path exists) }
  | sort
}

# Branch + porcelain status for a single repo path.
export def repo-summary [repo: path]: nothing -> record {
  let current = (^git -C $repo branch --show-current | str trim)
  let branch = if ($current | is-empty) {
    let sha = (^git -C $repo rev-parse --short HEAD | str trim)
    $"detached@($sha)"
  } else {
    $current
  }
  let porcelain = (^git -C $repo status --porcelain)
  let status = if ($porcelain | str trim | is-empty) { "clean" } else { "dirty" }
  { name: ($repo | path basename), status: $status, branch: $branch }
}

# Names matching a query: an exact name wins outright, otherwise every name that
# contains the substring (case-insensitive).
def match-workspaces [query: string]: nothing -> list<string> {
  let all = (workspace-names)
  if $query in $all {
    [$query]
  } else {
    $all | where {|n| $n | str contains --ignore-case $query }
  }
}

# Print a workspace's name (flagging dirty repos) followed by its full contents,
# including hidden files, so the user sees exactly what a delete/trash removes.
def print-workspace-contents [name: string]: nothing -> nothing {
  let dir = ($env.WORKSPACES_ROOT | path join $name)
  let repos = (workspace-repos $name | each {|r| repo-summary $r })
  let dirty = ($repos | where status == "dirty" | length)
  let note = if $dirty > 0 {
    $" (ansi red)[($dirty) dirty repo\(s\)](ansi reset)"
  } else {
    ""
  }
  print $"  (ansi cyan)($name)(ansi reset)($note)"
  let entries = (ls --all $dir | sort-by name)
  if ($entries | is-empty) {
    print $"    (ansi dark_gray)\(empty\)(ansi reset)"
    return
  }
  for entry in $entries {
    let base = ($entry.name | path basename)
    let repo = ($repos | where name == $base | get 0?)
    let detail = if $repo != null {
      $" (ansi dark_gray)[($repo.branch), ($repo.status)](ansi reset)"
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
# chosen names — empty when the picker is cancelled or --confirm is declined.
export def select-workspaces [
  query?: string                        # Name or partial; omit to pick from all
  --multi (-m)                          # Allow selecting several; off → single
  --confirm                             # Require a yes/no gate after selection
  --list-contents                       # Print each selection's contents first
  --prompt (-p): string = "Workspace:"  # Picker title + confirm/contents header
]: nothing -> list<string> {
  let all = (workspace-names)
  if ($all | is-empty) {
    error make { msg: "No workspaces found." }
  }

  # A non-null query resolves to its matches; empty matches (and a null query)
  # fall back to every workspace. A lone match is taken directly, no picker.
  let matches = if $query == null { $all } else { match-workspaces $query }
  let candidates = if ($matches | is-empty) { $all } else { $matches }
  let direct = ($query != null) and (($matches | length) == 1)

  let selection = if $direct {
    $matches
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
    let answer = (["no" "yes"] | input list "Confirm?")
    if $answer != "yes" {
      print "Aborted."
      return []
    }
  }

  $selection
}

# Resolve which workspace a user-facing command should target — either via an
# interactive picker (--choose) or by inferring from $env.PWD.
export def select-workspace [choose: bool]: nothing -> string {
  if $choose {
    let sel = (select-workspaces --prompt "Workspace:")
    if ($sel | is-empty) {
      error make { msg: "Nothing selected." }
    }
    $sel | first
  } else {
    let inferred = (try-infer-workspace)
    if $inferred == null {
      error make { msg: "Not inside a workspace. Pass --choose or cd into one." }
    }
    $inferred
  }
}
