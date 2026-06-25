# Workspace management commands.
#
# A "Workspace" is a direct subdirectory of the workspaces root. Inside a
# workspace you clone the repos needed for a given task (e.g. a Linear ticket)
# and operate on all of them at once.
#
# Typical flow:
#   workspace new ENG-123 web-app api-service          # create + clone
#   workspace in-each {|| git fetch origin main:main; git rebase main --autostash}
#   workspace in-each {|| git checkout -b eng-123-fix}
#   workspace list
#
# Reload after editing these files:
#   workspace use

# Print the absolute path of the workspaces root
export def root []: nothing -> path {
  $env.WORKSPACES_ROOT
}

# List all workspaces with each repo's branch and working-tree status
export def list []: nothing -> table {
  ls $env.WORKSPACES_ROOT
  | where type == dir
  | get name
  | where {|p| not ($p | path basename | str starts-with "_") }
  | sort
  | each {|p|
    {
      workspace: ($p | path basename)
      repos: (_workspace_repos ($p | path basename) | each {|r| _repo_summary $r })
    }
  }
}

# Branch + porcelain status for a single repo path.
def _repo_summary [repo: path]: nothing -> record {
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

# Create a new workspace and cd into it, optionally cloning repos
export def --env new [
  name: string       # Workspace directory name
  ...repos: string   # Repos to clone immediately (name or owner/name)
]: nothing -> nothing {
  let dir = ($env.WORKSPACES_ROOT | path join $name)
  if ($dir | path exists) {
    print $"(ansi yellow)workspace ($name) already exists(ansi reset)"
  } else {
    mkdir $dir
    print $"(ansi green)created workspace ($name)(ansi reset)"
  }
  cd $dir
  if not ($repos | is-empty) {
    clone ...$repos
  }
}

# Attach to (or create) a Zellij session named after the workspace
#
# Session names are clipped to 24 chars to satisfy Zellij's limit.
export def zellij [
  --choose (-c)             # Pick a workspace interactively instead of using the current one
]: nothing -> nothing {
  let name = (_select_workspace $choose)
  let dir = ($env.WORKSPACES_ROOT | path join $name)
  let session = ($name | str substring 0..23)
  do { cd $dir; ^zellij attach --create $session }
}

# cd into an existing workspace
export def --env switch [
  name: string  # Workspace directory name
]: nothing -> nothing {
  let dir = ($env.WORKSPACES_ROOT | path join $name)
  if not ($dir | path exists) {
    error make { msg: $"Workspace '($name)' does not exist." }
  }
  cd $dir
}

# Permanently delete one or more workspaces and everything inside them
#
# Pass explicit workspace names, or omit them to pick interactively
# (multi-select). The confirmation flags workspaces with uncommitted work;
# pass --force to skip it. This is irreversible — use `workspace trash` instead
# to keep the directories recoverable.
#
#   workspace delete ENG-123
#   workspace delete ENG-123 ENG-456
#   workspace delete                  # multi-select picker
#   workspace delete --force ENG-123  # no confirmation
export def --env delete [
  ...names: string   # Workspace(s) to delete; omit to choose interactively
  --force (-f)       # Skip the confirmation prompt
]: nothing -> nothing {
  _remove_workspaces $names $force false
}

# Move one or more workspaces to the system trash (recoverable)
#
# Like `workspace delete`, but routes through the OS trash so the directories
# can be restored later. Pass explicit workspace names, or omit them to pick
# interactively (multi-select); the confirmation flags workspaces with
# uncommitted work, and --force skips it.
#
#   workspace trash ENG-123
#   workspace trash ENG-123 ENG-456
#   workspace trash                   # multi-select picker
#   workspace trash --force ENG-123   # no confirmation
export def --env trash [
  ...names: string   # Workspace(s) to trash; omit to choose interactively
  --force (-f)       # Skip the confirmation prompt
]: nothing -> nothing {
  _remove_workspaces $names $force true
}

# Shared implementation for `delete` / `trash`.
#
# Resolves targets (explicit names or a multi-select picker), confirms unless
# forced (flagging dirty repos), steps out of any target the shell is sitting
# in, then removes each directory — via the system trash when `trash` is set.
def --env _remove_workspaces [
  names: list<string>   # Explicit workspace names, or empty to pick interactively
  force: bool           # Skip the confirmation prompt
  trash: bool           # Move to the system trash instead of deleting permanently
]: nothing -> nothing {
  let verb = if $trash { "trash" } else { "delete" }
  let targets = if ($names | is-empty) {
    let all = (_workspace_names)
    if ($all | is-empty) {
      error make { msg: "No workspaces found." }
    }
    $all | input list --multi $"Workspaces to ($verb):"
  } else {
    $names
  }

  if ($targets | is-empty) {
    print "Nothing selected."
    return
  }

  for name in $targets {
    let dir = ($env.WORKSPACES_ROOT | path join $name)
    if not ($dir | path exists) {
      error make { msg: $"Workspace '($name)' does not exist." }
    }
  }

  if not $force {
    print $"About to ($verb):"
    for name in $targets {
      let dirty = (_workspace_repos $name
        | each {|r| _repo_summary $r }
        | where status == "dirty"
        | length)
      let note = if $dirty > 0 {
        $" (ansi red)[($dirty) dirty repo\(s\)](ansi reset)"
      } else {
        ""
      }
      print $"  ($name)($note)"
    }
    let answer = (["no" "yes"] | input list "Confirm?")
    if $answer != "yes" {
      print "Aborted."
      return
    }
  }

  # If the shell is sitting inside one of the targets, step back to the root so
  # we don't strand the session in a deleted directory.
  let current = (_try_infer_workspace)
  if $current != null and ($current in $targets) {
    cd $env.WORKSPACES_ROOT
  }

  for name in $targets {
    let dir = ($env.WORKSPACES_ROOT | path join $name)
    if $trash {
      rm --recursive --trash $dir
      print $"(ansi yellow)trashed ($name)(ansi reset)"
    } else {
      rm --recursive --force $dir
      print $"(ansi red)deleted ($name)(ansi reset)"
    }
  }
}

# Clone repos into a workspace via `gh` (defaults to the current workspace)
#
# Bare names are resolved against $env.WORKSPACES_GH_ORG; pass owner/name to
# override the org for a single repo.
export def clone [
  ...repos: string  # Repos to clone (name or owner/name)
  --choose (-c)     # Pick a target workspace interactively instead of using the current one
]: nothing -> nothing {
  let name = (_select_workspace $choose)
  let dir = ($env.WORKSPACES_ROOT | path join $name)
  if not ($dir | path exists) {
    error make {
      msg: $"Workspace '($name)' does not exist. Create it with `workspace new`."
    }
  }
  if ($repos | is-empty) {
    error make { msg: "No repos given. Usage: workspace clone <repo>..." }
  }
  for repo in $repos {
    let slug = if ($repo | str contains "/") {
      $repo
    } else {
      $"($env.WORKSPACES_GH_ORG)/($repo)"
    }
    let target = ($dir | path join ($slug | path basename))
    if ($target | path exists) {
      print $"(ansi yellow)skip ($slug) \(already cloned\)(ansi reset)"
      continue
    }
    print $"(ansi green)clone ($slug)(ansi reset)"
    ^gh repo clone $slug $target
  }
}

# Run `git diff --color=always ...args` inside each repo of a workspace
#
# The def is `--wrapped`, so any unrecognized flags, revisions, and paths pass
# straight through to `git diff` (only --choose/--parallel are consumed here):
#   workspace diff
#   workspace diff --cached
#   workspace diff HEAD~1 -- src/
export def --wrapped diff [
  ...args: string   # Extra arguments forwarded to `git diff`
  --choose (-c)     # Pick a workspace interactively instead of using the current one
  --parallel (-p)   # Run repos concurrently
]: nothing -> table {
  # `--wrapped` forwards --help into $args, so handle it ourselves.
  if ("--help" in $args) or ("-h" in $args) { print (help workspace diff); return }
  in-each --choose=$choose --parallel=$parallel {|| ^git diff --color=always ...$args }
}

# Run a closure inside each repo of a workspace
#
# The closure runs with the repo directory as the working directory, so git
# and other tools operate on that repo. Defaults to the current workspace.
#
#   workspace in-each {|| git fetch origin main:main; git rebase main --autostash}
#   workspace in-each --parallel {|| ^git status --short}
export def "in-each" [
  action: closure   # Closure run inside each repo (cwd = repo)
  --choose (-c)     # Pick a workspace interactively instead of using the current one
  --parallel (-p)   # Run repos concurrently
]: nothing -> table {
  let name = (_select_workspace $choose)
  let repos = (_workspace_repos $name)
  if ($repos | is-empty) {
    error make { msg: $"No git repos found in workspace '($name)'." }
  }
  let runner = {|repo|
    let name = ($repo | path basename)
    let result = do { cd $repo; do $action }
    { repo: $name result: $result }
  }
  if $parallel {
    $repos | par-each $runner
  } else {
    $repos | each $runner
  }
}

# Infer the current workspace name from $env.PWD, or null if not inside one.
def _try_infer_workspace []: nothing -> string {
  let root = ($env.WORKSPACES_ROOT | path expand)
  let pwd = ($env.PWD | path expand)
  if $pwd == $root or not ($pwd | str starts-with ($root | path join "")) {
    return null
  }
  $pwd | path relative-to $root | path split | first
}

# All workspace names (immediate subdirs, excluding "_"-prefixed), sorted.
def _workspace_names []: nothing -> list<string> {
  ls $env.WORKSPACES_ROOT
  | where type == dir
  | get name
  | each { $in | path basename }
  | where {|n| not ($n | str starts-with "_") }
  | sort
}

# Resolve which workspace a user-facing command should target — either via an
# interactive picker (--choose) or by inferring from $env.PWD.
def _select_workspace [choose: bool]: nothing -> string {
  if $choose {
    let names = (_workspace_names)
    if ($names | is-empty) {
      error make { msg: "No workspaces found." }
    }
    $names | input list "Workspace:"
  } else {
    let inferred = (_try_infer_workspace)
    if $inferred == null {
      error make { msg: "Not inside a workspace. Pass --choose or cd into one." }
    }
    $inferred
  }
}

# List the git repos (immediate subdirectories containing .git) in a workspace.
def _workspace_repos [name: string]: nothing -> list<path> {
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
