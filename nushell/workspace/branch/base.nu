const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

use shared.nu *

# Print, set, or repair the branch each repo's current branch is built on
#
# The report's `source` is where the base came from: `recorded` in git config,
# `pr` from the open PR, or `default` from the repo default branch.
#
# --repair rebuilds records from open PRs, as needed in a fresh clone. GitHub
# does not keep the base sha, so it seeds from the merge base, which is correct
# until a parent is rebased.
#
#   workspace branch base                        # what sync would use, and why
#   workspace branch base parent-branch          # record it, in every repo
#   workspace branch base main --repo api        # record it, in one repo
#   workspace branch base --repair               # rebuild from open PRs
export def main [
  ref?: string      # Branch to record as the base; omit to report instead
  --choose (-c)     # Pick a workspace interactively instead of using the current one
  --repo (-r): string   # Act on this repo only, by directory name
  --repair          # Rebuild missing records from open PRs
]: nothing -> table {
  if $ref != null and $repair {
    error make --unspanned {
      msg: "Pass a branch or --repair, not both."
      code: "workspace::conflicting_options"
      help: "A branch records that base; --repair rebuilds every record from open PRs."
    }
  }
  let repos = (target-repos $choose $repo "acting on")
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

def base-ref [repo: path, base: string]: nothing -> oneof<string, nothing> {
  if (local-branch-exists $repo $base) {
    $base
  } else if (remote-branch-exists $repo $base) {
    $"origin/($base)"
  }
}

def fork-sha [repo: path, branch: string, base: string]: nothing -> oneof<string, nothing> {
  let ref = (base-ref $repo $base)
  if $ref == null { return null }
  let out = (^git -C $repo merge-base $branch $ref | complete)
  if $out.exit_code != 0 { return null }
  $out.stdout | str trim
}

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

# A live record is kept: its sha survived rebases the merge base cannot see.
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
