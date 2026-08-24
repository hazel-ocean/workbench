# `workspace branch`

Per-repo branch and stack management for a workspace.

## Problem

Keeping a workspace current means fetching the branch each repo is built on and
rebasing onto it. Today that is `workspace in-each {|| git fetch origin
main:main; git rebase main --autostash}`, which hard-codes `main` for every
repo. A repo whose branch targets an open PR's branch instead of `main` gets
rebased onto the wrong base, and the stack is silently flattened.

The base branch has to be resolved per repo, and per branch within a repo.

## Commands

A `workspace branch` namespace, mirroring the existing `workspace zellij` one.

|Command                        |Purpose                                            |
|-------------------------------|---------------------------------------------------|
|`workspace branch new <name>`  |Create the branch in each repo, record its base    |
|`workspace branch base [<ref>]`|Print the recorded base, or set it                 |
|`workspace branch sync`        |Fetch the root base, rebase the chain bottom-up    |
|`workspace branch status`      |Per repo: the chain, divergence, PR state          |
|`workspace sync`               |Top-level alias for `workspace branch sync`        |

All default to the current workspace. All take `--choose` (`-c`) to pick another
one, and run repos through `par-each --keep-order`.

## State

Three keys per branch, in each repo's `.git/config`:

```
branch.<name>.workbenchBase     the parent branch name
branch.<name>.workbenchBaseSha  the parent's tip when this branch last sat on it
```

Git owns the `branch.<name>` section, so a branch rename carries the keys and a
branch delete removes them. Verified on git 2.55. Git writes the key with the
casing you give it, but reports it lowercased through `--get-regexp`, so those
patterns must match `workbenchbase`. `--get` is case-insensitive.

Write with `git config set` (git 2.46+). Read with `git config --get-regexp
'^branch\.'` once per repo, which returns every branch's keys in one call.

A stack is a linked list. Each `workbenchBase` names another local branch:

```
branch.eng-234-fix.workbenchbase    = eng-123-fix
branch.eng-123-fix.workbenchbase    = parent-branch
branch.parent-branch.workbenchbase  = main
```

The state is local to the clone. It is never pushed, fetched, or merged, and a
fresh clone starts empty. `branch base --repair` rebuilds what it can; see
below.

## Resolving a base

For a branch `b`, in order:

1. `branch.<b>.workbenchBase`, when set and the named ref exists locally.
2. The `baseRefName` of `b`'s open PR.
3. The repo default branch, from `git symbolic-ref --short
   refs/remotes/origin/HEAD`, falling back to `gh repo view --json
   defaultBranchRef`.

Step 2 comes from one `gh pr list --author @me --json
number,headRefName,baseRefName,url --limit 100` per repo, read once and passed
down. The author scope matters: an unscoped list truncates at 100 in a busy repo
(`dashboard` hits the cap today), and dropping the edge you need is worse than
missing someone else's PR. A branch with no row falls back to a targeted
`gh pr list --head <branch>`, guarded by a check that the branch exists on
origin, since an unpushed branch cannot have a PR.

Building the chain from the current branch walks the resolution upward, and
stops at the default branch, at a base with no local branch of that name, or
after 10 links. A branch already seen is a cycle: stop and report it.

## `branch sync`

Per repo, for the current branch's chain:

1. Build the chain. Report and skip the repo on a detached HEAD.
2. `git fetch origin <root-base>` (no refspec). This updates
   `refs/remotes/origin/<root-base>` only, so it cannot fail on a diverged or
   currently-checked-out local branch.
3. Rebase each link bottom-up. The lowest link rebases onto
   `origin/<root-base>`; each higher link rebases onto its parent branch, which
   step 3 has already moved:

   ```
   git rebase --onto <parent> <recorded baseSha> <branch> --autostash
   ```

   `--onto` with the recorded sha replays exactly the commits in
   `<baseSha>..<branch>`, so a parent that was itself rebased does not cause the
   child to replay the parent's commits again. Without the recorded sha this
   falls back to `git rebase <parent> <branch>` and its patch-id dedupe.
4. Record each link's new `workbenchBaseSha` as its parent's post-rebase tip.
5. Fast-forward the local `<root-base>` branch to `origin/<root-base>` with
   `git update-ref`, when the branch exists, is not the current HEAD, and the
   move is a fast-forward. Otherwise leave it and note it in the result.
6. Return to the starting branch.

Flags:

- `--all` syncs every recorded chain in the repo, not just the current branch's.
- `--dry-run` prints the resolution table and performs no fetch or rebase.
- `--onto <ref>` forces the root base for every repo.

Result: one row per repo with `repo`, `branch`, `base`, `source`
(`recorded` / `pr` / `default`), and `action` (`up-to-date`, `rebased`,
`conflict`, `skipped`), plus a `reason` when skipped.

### Failure handling

- **Conflict.** Stop at that link, leave the repo mid-rebase, skip the rest of
  that repo's chain. Other repos continue. Never auto-abort: the conflicted
  state is what you resolve.
- **Merged parent.** The recorded base no longer exists on origin. GitHub
  retargets the child PR on merge, so read the PR's current `baseRefName`,
  rewrite the record, and continue.
- **Dirty tree.** `--autostash` handles it.

## `branch new`

`workspace branch new <name>`, in each repo:

1. Resolve the current branch's base and record it as the new branch's base.
   The current branch is the parent, so the recorded base is the current branch
   itself, and `workbenchBaseSha` is its tip.
2. `git checkout -b <name>`.
3. Write both keys.

Branch creation is the only moment the base is known for certain, which is the
point of the command.

Skip a repo whose branch already exists, and say so.

## `branch base`

- `workspace branch base` prints the recorded base and sha per repo.
- `workspace branch base <ref>` sets them for the current branch, seeding
  `workbenchBaseSha` from `git rev-parse <ref>`.
- `workspace branch base --repair` rebuilds records from `gh pr list`. The head
  and base pairs of the open PRs are the chain's edges, so the topology comes
  back. `workbenchBaseSha` is not recorded anywhere on GitHub, so it seeds from
  `git merge-base <branch> <base>`, which is correct until a parent is rebased.

## `branch status`

Extend `repo-summary` in `util.nu` with `base` and `behind-base`, so
`workspace list` gains the base column at no extra network cost beyond the
`gh pr list` already made for `pr-link`.

`branch status` is the deep view: each repo's chain as a tree, per link showing
behind-base count, ahead-of-upstream count, the PR link, and PR review state.

New-comment detection is deferred. GitHub exposes no read state for PR comments,
so "new since" needs a locally stored watermark. Show total comment and review
counts first. If counts prove insufficient, `branch.<name>.workbenchSeenAt`
slots in beside the other two keys with no restructuring.

## Files

|File                          |Change                                        |
|------------------------------|----------------------------------------------|
|`nushell/workspace/branch.nu` |New. The four subcommands and their `main`.   |
|`nushell/workspace/mod.nu`    |`export use branch.nu *`; `sync` alias.       |
|`nushell/util.nu`             |State read/write, base resolution, chain build, `repo-summary` columns.|
|`README.md`                   |Command list and the state description.       |

## Phases

1. `util.nu` helpers: read and write the two keys, resolve a base, build a
   chain, cached `gh pr list` per repo.
2. `branch base`, including `--repair`. Smallest surface, exercises every
   helper.
3. `branch new`.
4. `branch sync`, starting with `--dry-run` so the resolution table can be
   checked against real workspaces before anything rebases.
5. `branch status`, and the `repo-summary` columns.
6. README, and the `workspace sync` alias.

## Unverified

- Whether `gh pr list --json` accepts a comment-count field. If not, `status`
  needs one `gh pr view` per PR for counts. Settled in phase 5.

## Done

Phase 1, in `nushell/util.nu`:

`current-branch`, `local-branch-exists`, `remote-branch-exists`,
`branch-records`, `set-branch-base`, `clear-branch-base`, `default-branch`,
`repo-prs`, `pr-for-branch`, `resolve-base`, `branch-chain`.

Exercised against a scratch repo with a three-link stack and against three live
workspace repos. Covered: a branch name holding both a slash and a dot
(`eng-123/fix.v2`), all three resolution sources, a deleted parent retargeting
through its PR, chain termination at the default branch, cycle detection, the
depth cap, and a clone with no `refs/remotes/origin/HEAD`.

`refs/remotes/origin/HEAD` is set in all 12 repos across the current
workspaces, so `default-branch` takes the local path and makes no network call
in practice. It returns null rather than guessing when neither source answers.
