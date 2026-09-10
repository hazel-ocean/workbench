const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Clone repos into a workspace via `gh` (defaults to the current workspace)
#
# Each repo is `[<org>/]<repo>[<ref>][=<dir>]`. A bare name is resolved against
# $env.WORKBENCH_DEFAULT_GITHUB_ORG; prefix `owner/` to override the org. An optional
# trailing ref checks out after cloning: `@<tag-or-branch>` or `#<pr-number>`.
# `=<dir>` names the directory to clone into, in place of the repo name.
#
# Clones are shallow and blobless by default: the last 90 days of history, and
# file contents only for what's checked out. Pass --full for a complete clone.
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
  }
}

# Parse a repo spec into a clone slug, an optional ref to check out, and an
# optional destination directory name.
#
# Accepted forms (org defaults to $env.WORKBENCH_DEFAULT_GITHUB_ORG when omitted):
#   <repo>                 <org>/<repo>
#   <repo>@<ref>           <org>/<repo>@<ref>    ref = tag or branch
#   <repo>#<pr>            <org>/<repo>#<pr>     pr  = PR number
#   <repo>=<dir>           clone into <dir> instead of the repo name
#
# `=<dir>` is cut from the last `=` in the spec, so a branch name may contain
# `=` but a destination name may not.
#
# The ref begins at the first `@` or `#` of what remains; everything before it
# is the `[<org>/]<repo>` name. Splitting there (rather than on `/`) keeps
# branch names that contain slashes intact.
#
# Returns { slug, ref: "@<ref>" | "#<pr>" | null, dir: string | null }.
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

# Cut a trailing `=<dir>` off a repo spec, returning { rest, dir }.
#
# The destination is a single directory name directly under the workspace:
# `workspace-repos` finds repos one level down, so a nested path would hide the
# clone from every command that walks the workspace.
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

# Check out a ref inside a freshly cloned repo. `@<name>` is a tag or branch
# (git checkout handles both, DWIM-tracking a remote branch); `#<num>` is a PR
# checked out via `gh pr checkout` from within the repo.
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

# Clone one repo, truncating history to the last $CLONE_HISTORY_WINDOW.
#
# `--filter=blob:none` skips file contents that only exist in history, so a
# large blob committed and later reverted is never downloaded. Blobs the
# checkout needs still come down during the clone, and anything else is fetched
# on demand, so reading old file contents offline is the one thing that breaks.
#
# `--no-single-branch` keeps every branch tip fetched so a later `@<ref>` or
# `#<pr>` checkout resolves. `--shallow-since` is a hard error when the remote
# has no commits in the window, so fall back to full history in that case.
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
