# `workspace branch sync` and branches owned by two clones

A stack split across two clones of the same upstream repo desynchronises. Each
clone replays its own copy of the shared branch, so the two copies hold the same
tree under different shas.

## Problem

`workspace clone` can name its destination, so one upstream repo can appear in a
workspace more than once. A workspace holding `infra_staging` and
`infra_production`, both cloned from `OneSignal/infra`, is the case that broke.

The stack was `hazel/sms-1580-production` on top of `hazel/sms-1580-staging`.
`infra_staging` held the lower branch, `infra_production` held both.

After a sync, the two clones disagreed:

|Clone            |Sha of `hazel/sms-1580-staging`|
|-----------------|-------------------------------|
|`infra_staging`  |`6503850d`, pushed to origin   |
|`infra_production`|`5acb8c0b`, parent of the production branch|

`git range-diff` reports the two as `=`. The trees match; only the shas differ.

The damage lands on GitHub, which has no content equality. The merge base of the
production branch and `origin/hazel/sms-1580-staging` fell back to a commit older
than the staging change, so the production PR's diff absorbed
`terraform/staging/persistence/valkey/memorystore/main.tf`. That is an
environment mix, which `infra/AGENTS.md` tells reviewers to reject.

## Cause

Two properties combine.

**A chain link is never reconciled with its remote.** `sync-repo` fetches the
root of the chain and nothing else:

```nu
# branch.nu:432
let fetched = (^git -C $repo fetch origin $root | complete)
```

`rebase-chain` then rebases each link's local branch, taking the remote only for
the bottom link:

```nu
# branch.nu:500
let parent = if $i == 0 { $remote } else { $link.base }
```

`$link.base` is a local branch name. For a stack inside one clone that is right,
because the loop moved that parent moments earlier. Nothing compares a link
against `origin/<link>`, so a link that another clone has already rebased and
pushed is replayed again rather than adopted.

**Two clones are two repos.** `target-repos` keys on directory basename
(`branch.nu:36-40`), so `infra_staging` and `infra_production` are unrelated, and
`par-each` runs them at once (`branch.nu:320`). Neither can see the other's work,
and there is no ordering between them.

The result is one replay per clone, and two shas for one branch.

This is not a missing fetch of the base. The base is fetched. The gap is that a
link with an authoritative remote is treated as local.

## Why it appears now

`branch sync` assumes one directory per upstream repo. `9bc43fa Let workspace
clone name its destination` removed that guarantee.

## Options

1. **Reconcile every link against its remote.** Fetch each branch in the chain,
   not just the root. Before rebasing a link, if `origin/<link>` exists and holds
   the same tree as the local branch, reset to the remote instead of replaying.
   The pushed sha wins, which is what a branch with an open PR needs.
2. **Guard against a shared branch.** Detect two repo dirs with the same `origin`
   url and refuse to sync a branch present in both, or sync them as one unit.
3. **Fetch links, and skip a link whose remote has moved ahead.** Cheaper than 1,
   but leaves the operator to resolve it by hand.

Option 1 is the fix. Option 2 is a cheap guard worth having regardless, because
concurrent `par-each` over two clones of one repo is surprising in other ways
too.

## Notes for whoever picks this up

- Content equality is the test, not sha equality. `git range-diff A~1..A B~1..B`
  reporting `=` is the signal that a replay was redundant.
- Reset to remote is safe only when the local branch adds nothing the remote
  lacks. Check `merge-base --is-ancestor` both ways before discarding a local sha.
- `rebase-chain` already records the parent sha per link
  (`set-branch-base`, `branch.nu:504`). That record is the natural place to notice
  a parent moved under a different sha.
- Reproduce with two clones of one repo in a workspace, a two-branch stack, the
  lower branch present in both, and a `main` that has moved.

## Unverified

`branch-chain` was not read. Whether `infra_production` resolved its root to
`main` with two links, or to `hazel/sms-1580-staging` with one, is inferred from
the duplicate shas rather than traced. The reconciliation gap holds either way,
but the fix in option 1 needs the chain shape confirmed first.
