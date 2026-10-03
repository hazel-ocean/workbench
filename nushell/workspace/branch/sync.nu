const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

use shared.nu *

# So a pop only ever restores this command's own stash.
const STASH_MARK = "workspace-branch-sync"

# Fetch each repo's base and rebase onto it, following stacks
#
# `workspace branch base` shows which base each repo uses. The default branch
# is fast-forwarded instead.
#
# A conflict stops that repo and leaves the rebase for you to resolve. The
# other repos carry on.
#
#   workspace branch sync            # every repo in the workspace
#   workspace branch sync --dry-run  # what it would do, fetching nothing
#   workspace branch sync --onto main --repo api
export def main [
  --choose (-c)         # Pick a workspace interactively instead of using the current one
  --repo (-r): string   # Act on this repo only, by directory name
  --onto: string        # Force this root base instead of the resolved one
  --dry-run (-n)        # Report the plan; fetch nothing, rebase nothing
]: nothing -> table {
  target-repos $choose $repo "syncing" | par-each --keep-order {|r| sync-repo $r $onto $dry_run }
}

def rebase-in-progress [repo: path]: nothing -> bool {
  let dir = (^git -C $repo rev-parse --absolute-git-dir | str trim)
  ["rebase-merge" "rebase-apply"] | any {|d| ($dir | path join $d | path exists) }
}

# Untracked files survive a rebase, so they are not stashed.
def tracked-dirty [repo: path]: nothing -> bool {
  ^git -C $repo status --porcelain --untracked-files=no | str trim | is-not-empty
}

def stash-pop [repo: path]: nothing -> bool {
  let top = (^git -C $repo stash list -1 --format=%gs | complete)
  if $top.exit_code != 0 or (not ($top.stdout | str contains $STASH_MARK)) {
    return false
  }
  (^git -C $repo stash pop | complete).exit_code == 0
}

# So one malformed repo does not end a workspace-wide run.
def safe-chain [
  repo: path
  branch: string
  records: table
  prs: table
  default: oneof<string, nothing>
]: nothing -> record {
  try {
    { chain: (branch-chain $repo $branch $records $prs $default), error: null }
  } catch {|e|
    { chain: [], error: $e.msg }
  }
}

def rev [repo: path, ref: string]: nothing -> oneof<string, nothing> {
  let out = (^git -C $repo rev-parse --verify --quiet $ref | complete)
  if $out.exit_code != 0 { null } else { $out.stdout | str trim }
}

def contains-ref [repo: path, ancestor: string, ref: string]: nothing -> bool {
  (^git -C $repo merge-base --is-ancestor $ancestor $ref | complete).exit_code == 0
}

def sync-repo [
  repo: path
  onto: oneof<string, nothing>
  dry: bool
]: nothing -> record {
  let name = ($repo | path basename)
  let base_row = {
    repo: $name
    branch: null
    base: null
    source: null
    links: 0
    action: null
    reason: null
  }
  # A stopped rebase also detaches HEAD, so check it first.
  if (rebase-in-progress $repo) {
    return ($base_row | merge { branch: "rebasing", reason: "a rebase is already in progress" })
  }
  let branch = (current-branch $repo)
  if $branch == null {
    return ($base_row | merge { branch: "detached", reason: "detached HEAD" })
  }
  let row = ($base_row | merge { branch: $branch })

  let default = (default-branch $repo)
  let resolved = (safe-chain $repo $branch (branch-records $repo) (repo-prs $repo) $default)
  if $resolved.error != null {
    return ($row | merge { reason: $resolved.error })
  }
  let chain = $resolved.chain

  # An empty chain is the default branch, or a branch where nothing resolved.
  let root = if $onto != null {
    $onto
  } else if ($chain | is-empty) {
    $branch
  } else {
    $chain | last | get base
  }
  if ($chain | is-empty) and $onto == null and $branch != $default {
    return ($row | merge { reason: "no base resolved" })
  }
  let source = if $onto != null {
    "onto"
  } else if ($chain | is-empty) {
    "default"
  } else {
    $chain | first | get source
  }
  let row = ($row | merge { base: $root, source: $source, links: ($chain | length) })

  if $dry {
    let verb = if ($chain | is-empty) { "fast-forward" } else { "rebase" }
    return ($row | merge { action: $"would ($verb)" })
  }

  let fetched = (^git -C $repo fetch origin $root | complete)
  if $fetched.exit_code != 0 {
    return ($row | merge { reason: (fetch-reason $root $fetched.stderr) })
  }
  let remote = $"origin/($root)"
  if (rev $repo $remote) == null {
    return ($row | merge { reason: $"origin has no branch '($root)'" })
  }

  let stashed = if (tracked-dirty $repo) {
    (^git -C $repo stash push --message $STASH_MARK | complete).exit_code == 0
  } else {
    false
  }
  let outcome = if ($chain | is-empty) {
    fast-forward-current $repo $branch $remote
  } else {
    rebase-chain $repo $chain $root $remote
  }
  # Popping onto a half-applied rebase would tangle the two.
  let restored = if $stashed and $outcome.action != "conflict" {
    stash-pop $repo
  } else {
    false
  }
  let note = if $stashed and (not $restored) {
    $"local changes left stashed as '($STASH_MARK)'"
  }
  $row | merge {
    action: $outcome.action
    reason: ([$outcome.reason $note] | compact | str join "; " | default null)
  }
}

def fetch-reason [root: string, stderr: string]: nothing -> string {
  let last = ($stderr | str trim | lines | where {|l| ($l | str trim) != "" } | last)
  $"could not fetch '($root)': ($last)"
}

def fast-forward-current [repo: path, branch: string, remote: string]: nothing -> record {
  if (contains-ref $repo $remote $branch) {
    return { action: "up-to-date", reason: null }
  }
  let out = (^git -C $repo merge --ff-only $remote | complete)
  if $out.exit_code != 0 {
    return { action: null, reason: $"'($branch)' has diverged from ($remote)" }
  }
  { action: "fast-forwarded", reason: null }
}

# Lowest link first, so each parent has moved before its child replays onto it.
# The recorded base sha keeps a child from replaying a rebased parent's commits.
def rebase-chain [
  repo: path
  chain: table
  root: string
  remote: string
]: nothing -> record {
  let links = ($chain | reverse)
  mut moved = 0
  for i in 0..<($links | length) {
    let link = ($links | get $i)
    let parent = if $i == 0 { $remote } else { $link.base }
    # Under --onto, the sha comes from the forced root, so record that name.
    let recorded = if $i == 0 { $root } else { $link.base }
    let tip = (rev $repo $parent)
    if $tip == null {
      return { action: null, reason: $"no ref '($parent)'" }
    }
    if (contains-ref $repo $tip $link.branch) {
      set-branch-base $repo $link.branch $recorded $tip
      continue
    }
    let args = if $link.sha != null {
      ["--onto" $parent $link.sha $link.branch]
    } else {
      [$parent $link.branch]
    }
    let out = (^git -C $repo rebase ...$args | complete)
    if $out.exit_code != 0 {
      return {
        action: "conflict"
        reason: $"rebasing '($link.branch)' onto '($parent)'"
      }
    }
    set-branch-base $repo $link.branch $recorded $tip
    $moved = $moved + 1
  }
  fast-forward-root $repo $root $remote
  if $moved == 0 {
    { action: "up-to-date", reason: null }
  } else {
    { action: "rebased", reason: null }
  }
}

# So `main` is not left behind the stack rebased onto its fetched tip.
def fast-forward-root [repo: path, root: string, remote: string]: nothing -> nothing {
  if not (local-branch-exists $repo $root) { return }
  if (current-branch $repo) == $root { return }
  if not (contains-ref $repo $root $remote) { return }
  ^git -C $repo update-ref $"refs/heads/($root)" $"refs/remotes/origin/($root)"
}
