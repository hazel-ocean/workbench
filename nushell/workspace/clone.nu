const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *
use secrets/shared.nu *

# Clone repos into a workspace via `gh`
#
# A bare repo name uses the config's default-github-org. Clones are shallow
# (90 days) and blobless unless --full is given. When the secrets store holds
# files for a repo, a picker offers to copy them in.
#
#   workspace clone web-app
#   workspace clone other-org/web-app
#   workspace clone web-app@v1.2.3        # tag or branch
#   workspace clone web-app#1234          # PR number
#   workspace clone other-org/web-app@my-branch
#   workspace clone web-app=dashboard     # clone into `dashboard`
#   workspace clone web-app --full        # complete history
export def main [
  ...repos: string  # Repos to clone: [<org>/]<repo>[@<tag|branch> | #<pr>][=<dir>]
  --choose (-c)     # Pick a target workspace interactively instead of using the current one
  --full            # Clone complete history and all blobs instead of a shallow blobless clone
]: nothing -> nothing {
  let name = (select-workspace $choose)
  if $name == (workspace-home) {
    error make --unspanned {
      msg: "Cannot clone into the meta workspace."
      code: "workspace::meta_workspace"
      help: "Pass --choose to pick a real workspace, or cd into one first."
    }
  }
  let dir = (workspace-dir $name)
  if not ($dir | path exists) {
    error make --unspanned {
      msg: $"Workspace '($name)' does not exist."
      code: "workspace::unknown_workspace"
      help: "Create it with `workspace new <name>`."
    }
  }
  if ($repos | is-empty) {
    error make --unspanned {
      msg: "No repos given."
      code: "workspace::missing_argument"
      help: "Usage: workspace clone [<org>/]<repo>[@<tag|branch> | #<pr>][=<dir>]..."
    }
  }
  assert-tool "gh" "clone a repo"
  for repo in $repos {
    let parsed = (parse-repo-spec $repo)
    let slug = $parsed.slug
    let dest = ($parsed.dir | default ($slug | path basename))
    let target = ($dir | path join $dest)
    if ($target | path exists) {
      print $"(ansi yellow)skip ($slug) \(($dest) already exists\)(ansi reset)"
      continue
    }
    let suffix = if $parsed.ref != null { $" ($parsed.ref)" } else { "" }
    let into = if $parsed.dir != null { $" into ($dest)" } else { "" }
    print $"(ansi green)clone ($slug)($suffix)($into)(ansi reset)"
    clone-repo $slug $target $full
    if $parsed.ref != null {
      checkout-ref $target $parsed.ref
    }
    offer-secrets $target
  }
}

def checkout-ref [repo: path, ref: string]: nothing -> nothing {
  let value = ($ref | str substring 1..)
  if ($ref | str starts-with "#") {
    print $"(ansi green)checkout PR #($value)(ansi reset)"
    do { cd $repo; ^gh pr checkout $value }
  } else {
    print $"(ansi green)checkout ($value)(ansi reset)"
    ^git -C $repo checkout $value
  }
}

const CLONE_HISTORY_WINDOW = 90day

# A blobless clone fetches old file contents on demand, so reading them offline
# fails.
#
# `--no-single-branch` lets a later `@<ref>` or `#<pr>` checkout resolve.
# `--shallow-since` fails when the window has no commits, hence the fallback.
def clone-repo [slug: string, target: path, full: bool]: nothing -> nothing {
  if $full {
    ^gh repo clone $slug $target
    return
  }
  let since = ((date now) - $CLONE_HISTORY_WINDOW | format date "%Y-%m-%d")
  try {
    (^gh repo clone $slug $target --
      $"--shallow-since=($since)"
      --no-single-branch
      --filter=blob:none)
  } catch {
    if ($target | path exists) { rm -rf $target }
    print $"(ansi yellow)no history since ($since); cloning full history(ansi reset)"
    ^gh repo clone $slug $target -- --filter=blob:none
  }
}
