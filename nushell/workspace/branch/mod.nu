# Branch and stack management for workspaces.
#
# Each repo's branch is built on some other branch: `main`, or, when PRs are
# stacked, another branch with a PR of its own. That base is recorded per branch
# in the repo's own git config, so a rename carries it and a delete removes it.

export use base.nu *
export use new.nu *
export use sync.nu *
