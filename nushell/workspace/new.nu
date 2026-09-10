const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *
use clone.nu *

# Create a new workspace and cd into it, optionally cloning repos
export def --env main [
  name: string       # Workspace directory name
  ...repos: string   # Repos to clone immediately: [<org>/]<repo>[@<tag|branch> | #<pr>][=<dir>]
  --full             # Clone complete history and all blobs instead of a shallow blobless clone
]: nothing -> nothing {
  let dir = ($env.WORKBENCH_WORKSPACES_ROOT | path join $name)
  if ($dir | path exists) {
    print $"(ansi yellow)workspace ($name) already exists(ansi reset)"
  } else {
    mkdir $dir
    print $"(ansi green)created workspace ($name)(ansi reset)"
  }
  cd $dir
  if not ($repos | is-empty) {
    clone ...$repos --full=$full
  }
}
