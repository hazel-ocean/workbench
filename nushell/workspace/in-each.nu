const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Run a closure inside each repo of a workspace
#
# The closure runs with the repo directory as the working directory, so git
# and other tools operate on that repo. Defaults to the current workspace.
#
#   workspace in-each {|| git fetch origin main:main; git rebase main --autostash}
#   workspace in-each --parallel {|| ^git status --short}
export def main [
  action: closure   # Closure run inside each repo (cwd = repo)
  --choose (-c)     # Pick a workspace interactively instead of using the current one
  --parallel (-p)   # Run repos concurrently
]: nothing -> table {
  let name = (select-workspace $choose)
  let repos = (workspace-repos $name)
  if ($repos | is-empty) {
    error make --unspanned {
      msg: $"No git repos found in workspace '($name)'."
      code: "workspace::no_repos"
      help: "Clone one with `workspace clone <repo>`."
    }
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
