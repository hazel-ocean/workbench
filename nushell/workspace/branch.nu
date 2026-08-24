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
  let all = (workspace-repos (select-workspace $choose))
  if ($all | is-empty) {
    error make { msg: "No git repos found in this workspace." }
  }
  let repos = if $repo == null {
    $all
  } else {
    let hit = ($all | where {|r| ($r | path basename) == $repo })
    if ($hit | is-empty) {
      let names = ($all | each {|r| $r | path basename } | str join ", ")
      error make { msg: $"No repo '($repo)' in this workspace. Available: ($names)." }
    }
    $hit
  }
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
