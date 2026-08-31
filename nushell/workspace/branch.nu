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

# The git repo holding PWD, when PWD is outside every workspace. Null inside a
# workspace, and null when PWD is in no repo at all.
def loose-repo []: nothing -> oneof<path, nothing> {
  if (try-infer-workspace) != null { return null }
  let out = (^git -C $env.PWD rev-parse --show-toplevel | complete)
  if $out.exit_code != 0 { return null }
  $out.stdout | str trim
}

# The repos a command acts on: the whole workspace, or the one named by --repo.
#
# Outside a workspace it falls back to the enclosing git repo, so a plain
# checkout such as nix-config gets the same behaviour scoped to itself. --choose
# asks for a workspace by name, so it never takes the fallback.
def target-repos [
  choose: bool
  only: oneof<string, nothing>
]: nothing -> list<path> {
  let loose = (if $choose { null } else { loose-repo })
  if $loose != null {
    let name = ($loose | path basename)
    if $only != null and $only != $name {
      error make --unspanned {
        msg: $"No repo '($only)' here."
        code: "workspace::unknown_repo"
        help: $"Outside a workspace this acts on '($name)' alone."
      }
    }
    print $"(ansi yellow)not in a workspace; acting on ($name) alone(ansi reset)"
    return [$loose]
  }
  let all = (workspace-repos (select-workspace $choose))
  if ($all | is-empty) {
    error make --unspanned {
      msg: "No git repos found in this workspace."
      code: "workspace::no_repos"
      help: "Clone one with `workspace clone <repo>`."
    }
  }
  if $only == null { return $all }
  let hit = ($all | where {|r| ($r | path basename) == $only })
  if ($hit | is-empty) {
    let names = ($all | each {|r| $r | path basename } | str join ", ")
    error make --unspanned {
      msg: $"No repo '($only)' in this workspace."
      code: "workspace::unknown_repo"
      help: $"Available: ($names)."
    }
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
    error make --unspanned {
      msg: "Pass a branch or --repair, not both."
      code: "workspace::conflicting_options"
      help: "A branch records that base; --repair rebuilds every record from open PRs."
    }
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
    error make --unspanned {
      msg: $"'($name)' is not a valid branch name."
      code: "workspace::invalid_branch_name"
      help: "Git rejects spaces, a leading dash, and `..`. See `git help check-ref-format`."
    }
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
export def "branch sync" [
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
