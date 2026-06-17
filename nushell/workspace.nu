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
# Extra arguments are forwarded to `git diff`, so flags, revisions, and paths
# pass straight through:
#   workspace diff
#   workspace diff --cached
#   workspace diff HEAD~1 -- src/
export def diff [
  ...args: string   # Extra arguments forwarded to `git diff`
  --choose (-c)     # Pick a workspace interactively instead of using the current one
  --parallel (-p)   # Run repos concurrently
]: nothing -> table {
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

# Resolve which workspace a user-facing command should target — either via an
# interactive picker (--choose) or by inferring from $env.PWD.
def _select_workspace [choose: bool]: nothing -> string {
  if $choose {
    let names = (ls $env.WORKSPACES_ROOT
      | where type == dir
      | get name
      | each { $in | path basename }
      | where {|n| not ($n | str starts-with "_") }
      | sort)
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
