const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

use shared.nu *

# Message on the stash `branch sync` takes, so a pop only ever restores its own.
const STASH_MARK = "workspace-branch-sync"

# Fetch each repo's base and rebase onto it, following stacks
#
# The base comes from the record, the branch's open PR, or the repo default, in
# that order; `workspace branch base` reports which. On the default branch there
# is nothing to rebase, so the branch is fast-forwarded instead, which is the
# common case for the repos in a workspace that are not stacked.
#
# A stack is rebased bottom-up, each branch onto the parent that was just moved,
# using the recorded base sha so a parent that was itself rebased does not make
# its children replay its commits.
#
# Local changes are stashed once per repo and restored at the end. A conflict
# stops that repo, leaves the rebase for you to resolve, and says so; the other
# repos carry on.
#
# Outside a workspace it acts on the git repo you are in, and warns that it did.
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
  target-repos $choose $repo | par-each --keep-order {|r| sync-repo $r $onto $dry_run }
}

# True while a rebase is stopped part-way in this repo.
def rebase-in-progress [repo: path]: nothing -> bool {
  let dir = (^git -C $repo rev-parse --absolute-git-dir | str trim)
  ["rebase-merge" "rebase-apply"] | any {|d| ($dir | path join $d | path exists) }
}

# Uncommitted changes to tracked files. Untracked files survive a rebase, so
# they are not worth stashing.
def tracked-dirty [repo: path]: nothing -> bool {
  ^git -C $repo status --porcelain --untracked-files=no | str trim | is-not-empty
}

# Restore this command's own stash, identified by its message. Returns false
# when the top of the stash is something else, which leaves it untouched.
def stash-pop [repo: path]: nothing -> bool {
  let top = (^git -C $repo stash list -1 --format=%gs | complete)
  if $top.exit_code != 0 or (not ($top.stdout | str contains $STASH_MARK)) {
    return false
  }
  (^git -C $repo stash pop | complete).exit_code == 0
}

# `branch-chain`, with a cycle or an over-deep chain returned rather than raised,
# so one malformed repo does not end a workspace-wide run.
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

# True when `ancestor` is already contained in `ref`, i.e. there is nothing to
# rebase or fast-forward.
def contains-ref [repo: path, ancestor: string, ref: string]: nothing -> bool {
  (^git -C $repo merge-base --is-ancestor $ancestor $ref | complete).exit_code == 0
}

# Sync one repo: resolve the chain, fetch its root, rebase bottom-up.
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
  # A stopped rebase also detaches HEAD, so it has to be reported before the
  # detached-HEAD case or it comes back as the wrong reason.
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

  # An empty chain means the branch has no base: either it is the default
  # branch, which is fetched and fast-forwarded, or nothing resolved at all.
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
  # A conflict leaves the rebase in place to resolve, so the stash stays put
  # too: popping it onto a half-applied tree would tangle the two.
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

# Turn a failed fetch into something readable, keeping git's last line.
def fetch-reason [root: string, stderr: string]: nothing -> string {
  let last = ($stderr | str trim | lines | where {|l| ($l | str trim) != "" } | last)
  $"could not fetch '($root)': ($last)"
}

# On the default branch there is nothing to rebase; move it up to origin.
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

# Rebase every link of a stack, lowest first, each onto the parent just moved.
def rebase-chain [
  repo: path
  chain: table
  root: string
  remote: string
]: nothing -> record {
  # `chain` runs tip first; a rebase has to start from the bottom so each parent
  # has already moved by the time its child replays onto it.
  let links = ($chain | reverse)
  mut moved = 0
  for i in 0..<($links | length) {
    let link = ($links | get $i)
    # Only the lowest link rebases onto the remote; the rest follow the local
    # branch this loop has already rebased.
    let parent = if $i == 0 { $remote } else { $link.base }
    # The name recorded has to be the branch the sha came from. Under --onto
    # that is the forced root, not what the chain used to say, or the record
    # would pair one branch's name with another branch's tip.
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

# Move the local root branch up to origin, so `main` is not left behind after
# its stack has been rebased onto the fetched tip. Only ever a fast-forward,
# and never the branch currently checked out.
def fast-forward-root [repo: path, root: string, remote: string]: nothing -> nothing {
  if not (local-branch-exists $repo $root) { return }
  if (current-branch $repo) == $root { return }
  if not (contains-ref $repo $root $remote) { return }
  ^git -C $repo update-ref $"refs/heads/($root)" $"refs/remotes/origin/($root)"
}
