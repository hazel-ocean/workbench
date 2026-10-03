const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *
use secrets/shared.nu *

# Clone repos into a workspace via `gh`
#
# A bare repo name uses $env.WORKBENCH_DEFAULT_GITHUB_ORG. Clones are shallow
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

# The ref starts at the first `@` or `#`, so a branch name may contain slashes.
def parse-repo-spec [spec: string]: nothing -> record {
  let split = (split-dest $spec)
  let rest = $split.rest
  let sigils = ([($rest | str index-of "@") ($rest | str index-of "#")]
    | where {|i| $i >= 0 })
  let cut = if ($sigils | is-empty) { null } else { $sigils | math min }
  let name = if $cut == null { $rest } else { $rest | str substring 0..<$cut }
  let ref = if $cut == null { null } else { $rest | str substring $cut.. }
  let slug = if ($name | str contains "/") {
    $name
  } else {
    let org = $env.WORKBENCH_DEFAULT_GITHUB_ORG?
    if ($org | is-empty) {
      error make --unspanned {
        msg: $"No default org for bare repo '($name)'."
        code: "workspace::no_default_org"
        help: $"Set WORKBENCH_DEFAULT_GITHUB_ORG in .env \(or the environment\), or qualify the repo as <org>/($name)."
      }
    }
    $"($org)/($name)"
  }
  { slug: $slug, ref: $ref, dir: $split.dir }
}

# Cut at the last `=`, so a branch name may contain one. The destination must
# be one level down, where `workspace-repos` looks.
def split-dest [spec: string]: nothing -> record {
  let cut = ($spec | str index-of --end "=")
  if $cut < 0 { return { rest: $spec, dir: null } }
  let rest = ($spec | str substring 0..<$cut)
  let dir = ($spec | str substring ($cut + 1)..)
  if ($rest | is-empty) {
    error make --unspanned {
      msg: $"No repo before '=' in '($spec)'."
      code: "workspace::malformed_repo_spec"
      help: "Usage: [<org>/]<repo>[@<tag|branch> | #<pr>][=<dir>]"
    }
  }
  if ($dir | is-empty) {
    error make --unspanned {
      msg: $"Empty destination in '($spec)'."
      code: "workspace::empty_destination"
      help: $"Name the directory, as in '($rest)=my-dir', or drop the '='."
    }
  }
  if ($dir | str contains "/") or ($dir in [".", ".."]) {
    error make --unspanned {
      msg: $"Destination '($dir)' is not a plain directory name."
      code: "workspace::nested_destination"
      help: "A clone lands one level under the workspace root, so the destination cannot be a path."
    }
  }
  { rest: $rest, dir: $dir }
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
