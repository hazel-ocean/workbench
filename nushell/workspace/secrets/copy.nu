const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

use shared.nu *

# Copy gitignored files from the secrets store into the workspace's repos
#
# The store is $env.WORKBENCH_SECRETS_ROOT. A file at `<org>/<repo>/<path>`
# lands at `<path>` in that repo. Each pick can be renamed, as when
# `.env.staging` should land as `.env`. A tracked file is never replaced.
#
#   workspace secrets copy              # every repo in the workspace
#   workspace secrets copy --repo api   # one repo
export def main [
  --choose (-c)         # Pick a workspace interactively instead of using the current one
  --repo (-r): string   # Copy into this repo only, by directory name
]: nothing -> table {
  let repos = (target-repos $choose $repo "copying into")
  let files = ($repos | each {|r| secret-files $r } | flatten)
  if ($files | is-empty) {
    let looked = ($repos | each {|r|
      let slug = (repo-slug $r)
      if $slug == null {
        $"($r | path basename) \(no origin\)"
      } else {
        $"($slug.org)/($slug.repo)"
      }
    } | str join ", ")
    error make --unspanned {
      msg: "No secrets for these repos."
      code: "workspace::no_secrets"
      help: $"Looked in (secrets-root) for: ($looked)."
    }
  }
  copy-secrets $files
}
