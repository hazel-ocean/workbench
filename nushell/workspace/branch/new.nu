const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

use shared.nu *

# Create a branch in each repo, recording the branch it was cut from
#
# Creation is the only moment the base is known for certain. Later, it has to
# be inferred.
#
# Nothing is created unless every repo can take the branch. --partial creates
# it where possible.
#
#   workspace branch new abc-123-fix              # cut from main, in every repo
#   workspace branch new abc-234-fix              # now cut from abc-123-fix
#   workspace branch new abc-234-fix --repo api   # in one repo only
export def main [
  name: string          # Branch to create in each repo
  --choose (-c)         # Pick a workspace interactively instead of using the current one
  --repo (-r): string   # Act on this repo only, by directory name
  --partial             # Create it in the repos that can take it, skipping the rest
]: nothing -> table {
  let check = (^git check-ref-format --branch $name | complete)
  if $check.exit_code != 0 {
    error make --unspanned {
      msg: $"'($name)' is not a valid branch name."
      code: "workspace::invalid_branch_name"
      help: "Git rejects spaces, a leading dash, and `..`. See `git help check-ref-format`."
    }
  }
  let checked = (target-repos $choose $repo "branching" | par-each --keep-order {|r|
    {
      repo: $r
      name: ($r | path basename)
      parent: (current-branch $r)
      blocker: (creation-blocker $r $name)
    }
  })
  let blocked = ($checked | where blocker != null)
  if ($blocked | is-not-empty) and (not $partial) {
    let detail = ($blocked | each {|b| $"  ($b.name): ($b.blocker)" } | str join (char newline))
    error make --unspanned {
      msg: ([$"Cannot create '($name)' in every repo:" $detail] | str join (char newline))
      code: "workspace::branch_blocked"
      help: "Nothing was created. Pass --partial to create it in the repos that can take it."
    }
  }
  $checked | par-each --keep-order {|c|
    if $c.blocker != null {
      { repo: $c.name, branch: $name, base: $c.parent, sha: null, action: "skipped", reason: $c.blocker }
    } else {
      create-repo $c.repo $name
    }
  }
}

def creation-blocker [repo: path, name: string]: nothing -> oneof<string, nothing> {
  if (current-branch $repo) == null { return "detached HEAD" }
  if (local-branch-exists $repo $name) { return $"'($name)' already exists" }
  null
}

def create-repo [repo: path, name: string]: nothing -> record {
  let repo_name = ($repo | path basename)
  let parent = (current-branch $repo)
  let row = { repo: $repo_name, branch: $name, base: $parent, sha: null, action: "skipped" }
  let sha = (^git -C $repo rev-parse HEAD | str trim)
  let out = (^git -C $repo checkout -b $name | complete)
  if $out.exit_code != 0 {
    return ($row | merge { reason: ($out.stderr | str trim | lines | last) })
  }
  set-branch-base $repo $name $parent $sha
  {
    repo: $repo_name
    branch: $name
    base: $parent
    sha: (short $sha)
    action: "created"
    reason: null
  }
}
