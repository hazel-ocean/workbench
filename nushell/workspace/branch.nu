# Branch and stack management for workspaces.
#
# Each repo's branch is built on some other branch: `main`, or, when PRs are
# stacked, another branch with a PR of its own. That base is recorded per branch
# in the repo's own git config, so a rename carries it and a delete removes it.

const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Abbreviate a sha for display; the full value is what gets recorded.
def short [sha: oneof<string, nothing>]: nothing -> oneof<string, nothing> {
  if $sha == null { null } else { $sha | str substring 0..<8 }
}

# A ref naming `base` in this repo: the local branch, else the remote-tracking
# one, else null.
def base-ref [repo: path, base: string]: nothing -> oneof<string, nothing> {
  if (local-branch-exists $repo $base) {
    $base
  } else if (remote-branch-exists $repo $base) {
    $"origin/($base)"
  }
}

# Where `branch` and `base` last agreed, as a full sha, or null when they share
# no history.
def fork-sha [repo: path, branch: string, base: string]: nothing -> oneof<string, nothing> {
  let ref = (base-ref $repo $base)
  if $ref == null { return null }
  let out = (^git -C $repo merge-base $branch $ref | complete)
  if $out.exit_code != 0 { return null }
  $out.stdout | str trim
}

# The repos a command acts on: the whole workspace, or the one named by --repo.
def target-repos [
  choose: bool
  only: oneof<string, nothing>
]: nothing -> list<path> {
  let all = (workspace-repos (select-workspace $choose))
  if ($all | is-empty) {
    error make { msg: "No git repos found in this workspace." }
  }
  if $only == null { return $all }
  let hit = ($all | where {|r| ($r | path basename) == $only })
  if ($hit | is-empty) {
    let names = ($all | each {|r| $r | path basename } | str join ", ")
    error make { msg: $"No repo '($only)' in this workspace. Available: ($names)." }
  }
  $hit
}

# Print, set, or repair the branch each repo's current branch is built on
#
# With no argument, reports what `workspace branch sync` would rebase onto, and
# how it worked that out: `recorded` from git config, `pr` from the branch's
# open PR, or `default` from the repo's default branch.
#
# With a branch name, records it as the base of each repo's current branch. The
# branch must exist locally, since a base that cannot be checked out cannot be
# rebased onto.
#
# With --repair, rebuilds records from open PRs, whose head and base pairs are
# the edges of your stacks. Use it in a fresh clone, which starts with no
# records. The base sha cannot be recovered from GitHub, so it seeds from the
# merge base, which is correct until a parent is rebased.
#
# Every mode covers the whole workspace. Pass --repo to act on one, which is
# what a workspace holding one stacked repo among several plain ones needs.
#
#   workspace branch base                        # what sync would use, and why
#   workspace branch base parent-branch          # record it, in every repo
#   workspace branch base main --repo api        # record it, in one repo
#   workspace branch base --repair               # rebuild from open PRs
export def "branch base" [
  ref?: string      # Branch to record as the base; omit to report instead
  --choose (-c)     # Pick a workspace interactively instead of using the current one
  --repo (-r): string   # Act on this repo only, by directory name
  --repair          # Rebuild missing records from open PRs
]: nothing -> table {
  if $ref != null and $repair {
    error make { msg: "Pass a branch or --repair, not both." }
  }
  let repos = (target-repos $choose $repo)
  $repos | par-each --keep-order {|repo|
    if $repair {
      repair-repo $repo
    } else if $ref != null {
      record-repo $repo $ref
    } else {
      report-repo $repo
    }
  } | flatten
}

# One row per repo: the base its current branch resolves to, and the source.
def report-repo [repo: path]: nothing -> record {
  let name = ($repo | path basename)
  let branch = (current-branch $repo)
  if $branch == null {
    return { repo: $name, branch: "detached", base: null, sha: null, source: null }
  }
  let resolved = (resolve-base
    $repo
    $branch
    (branch-records $repo)
    (repo-prs $repo)
    (default-branch $repo))
  {
    repo: $name
    branch: $branch
    base: $resolved.base
    sha: (short $resolved.sha)
    source: $resolved.source
  }
}

# Record `base` for the repo's current branch, or explain why it was not.
def record-repo [repo: path, base: string]: nothing -> record {
  let name = ($repo | path basename)
  let branch = (current-branch $repo)
  let row = { repo: $name, branch: $branch, base: $base, sha: null, action: "skipped" }
  if $branch == null {
    return ($row | merge { branch: "detached", reason: "detached HEAD" })
  }
  if $base == $branch {
    return ($row | merge { reason: "a branch cannot be its own base" })
  }
  if not (local-branch-exists $repo $base) {
    let hint = if (remote-branch-exists $repo $base) {
      $"'($base)' is on origin but not checked out locally"
    } else {
      $"no branch '($base)'"
    }
    return ($row | merge { reason: $hint })
  }
  # Replacing a different base rewrites a stack's shape, so say so rather than
  # reporting it the same as a first-time record.
  let held = (branch-records $repo | where branch == $branch)
  let previous = if ($held | is-empty) { null } else { $held | first | get base }
  let sha = (^git -C $repo rev-parse $base | str trim)
  set-branch-base $repo $branch $base $sha
  let replaced = $previous != null and $previous != $base
  {
    repo: $name
    branch: $branch
    base: $base
    sha: (short $sha)
    action: (if $replaced { "replaced" } else { "recorded" })
    reason: (if $replaced { $"was '($previous)'" })
  }
}

# Rebuild every branch's record in a repo from its open PRs.
#
# A branch whose record already points at a live local branch is left alone: it
# is more precise than anything rebuildable, because its sha survived the
# rebases the merge base cannot see.
def repair-repo [repo: path]: nothing -> table {
  let name = ($repo | path basename)
  let records = (branch-records $repo)
  let prs = (repo-prs $repo)
  let local = $prs | where {|pr| local-branch-exists $repo $pr.headRefName }
  if ($local | is-empty) {
    return [{ repo: $name, branch: null, base: null, sha: null, action: "skipped", reason: "no open PRs on local branches" }]
  }
  $local | each {|pr|
    let branch = $pr.headRefName
    let base = $pr.baseRefName
    let held = ($records | where branch == $branch)
    let kept = (if ($held | is-not-empty) {
      let r = ($held | first)
      $r.base != null and (local-branch-exists $repo $r.base)
    } else {
      false
    })
    let row = { repo: $name, branch: $branch, base: $base }
    if $kept {
      let r = ($held | first)
      $row | merge { base: $r.base, sha: (short $r.sha), action: "kept", reason: "already recorded" }
    } else if not (local-branch-exists $repo $base) {
      $row | merge { sha: null, action: "skipped", reason: $"base '($base)' not checked out locally" }
    } else {
      let sha = (fork-sha $repo $branch $base)
      if $sha == null {
        $row | merge { sha: null, action: "skipped", reason: $"no common history with '($base)'" }
      } else {
        set-branch-base $repo $branch $base $sha
        $row | merge { sha: (short $sha), action: "repaired", reason: null }
      }
    }
  }
}


# Create a branch in each repo, recording the branch it was cut from
#
# The branch you are on becomes the new branch's base, and its tip becomes the
# recorded base sha. Creation is the only moment the base is known for certain,
# which is the point of using this over `git checkout -b`: everything later has
# to infer it.
#
# Stack a branch by cutting it from the one below:
#
# Nothing is created unless every target repo can take the branch, so a
# workspace never ends up half-branched. --partial creates it where possible.
#
#   workspace branch new eng-123-fix              # cut from main, in every repo
#   workspace branch new eng-234-fix              # now cut from eng-123-fix
#   workspace branch new eng-234-fix --repo api   # in one repo only
export def "branch new" [
  name: string          # Branch to create in each repo
  --choose (-c)         # Pick a workspace interactively instead of using the current one
  --repo (-r): string   # Act on this repo only, by directory name
  --partial             # Create it in the repos that can take it, skipping the rest
]: nothing -> table {
  # Reject a malformed name before any repo is touched, so a typo cannot leave
  # the workspace half-branched.
  let check = (^git check-ref-format --branch $name | complete)
  if $check.exit_code != 0 {
    error make { msg: $"'($name)' is not a valid branch name." }
  }
  let checked = (target-repos $choose $repo | par-each --keep-order {|r|
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
    error make {
      msg: ([
        $"Cannot create '($name)' in every repo:"
        $detail
        "Nothing was created. Pass --partial to create it where possible."
      ] | str join (char newline))
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

# Why `name` cannot be created in this repo, or null when it can.
def creation-blocker [repo: path, name: string]: nothing -> oneof<string, nothing> {
  if (current-branch $repo) == null { return "detached HEAD" }
  if (local-branch-exists $repo $name) { return $"'($name)' already exists" }
  null
}

# Create `name` in one repo and record the branch it was cut from.
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
