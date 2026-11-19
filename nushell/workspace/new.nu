const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *
use clone.nu *
use secrets/shared.nu *

# Create a new workspace and cd into it, optionally cloning repos
#
# A workspace under the root is also offered the config's `new.template`
# files and `new.clone` repos, each with a prompt. Neither offers what is
# already there, so running this on an existing workspace backfills it.
export def --env main [
  name: string       # Workspace directory name
  ...repos: string   # Repos to clone immediately: [<org>/]<repo>[@<tag|branch> | #<pr>][=<dir>]
  --full             # Clone complete history and all blobs instead of a shallow blobless clone
]: nothing -> nothing {
  if $name == (workspace-home) {
    error make --unspanned {
      msg: "Cannot create the meta workspace."
      code: "workspace::meta_workspace"
      help: "Pick another name."
    }
  }
  let config = (workbench-config)
  let dir = (workspace-dir $name)
  if ($dir | path exists) {
    print $"(ansi yellow)workspace ($name) already exists(ansi reset)"
  } else {
    mkdir $dir
    print $"(ansi green)created workspace ($name)(ansi reset)"
  }
  cd $dir
  # An extra workspace is a directory you already manage, so it gets only
  # the repos you name.
  let under_root = (($dir | path dirname) == $config.workspaces-root)
  if $under_root {
    offer-template $dir $config.new.template
  }
  let named_dests = ($repos | each {|spec| repo-dest $spec })
  let offered = if $under_root {
    $config.new.clone
    | where {|spec|
        let dest = (repo-dest $spec)
        not ($dest in $named_dests or ($dir | path join $dest | path exists))
      }
    | where {|spec| offer-clone $spec }
  } else {
    []
  }
  let all = ($repos ++ $offered)
  if not ($all | is-empty) {
    clone ...$all --full=$full
  }
}

def repo-dest [spec: string]: nothing -> string {
  let parsed = (parse-repo-spec $spec)
  $parsed.dir | default ($parsed.slug | path basename)
}

def offer-clone [spec: string]: nothing -> bool {
  if not (is-terminal --stdin) {
    print $"(ansi yellow)skip clone ($spec) \(no terminal to ask\)(ansi reset)"
    return false
  }
  confirm-prompt --default-yes $"Clone ($spec)?"
}

def offer-template [dir: path, template: oneof<path, nothing>]: nothing -> nothing {
  if $template == null { return }
  if not ($template | path exists) {
    error make --unspanned {
      msg: $"Template directory '($template)' does not exist."
      code: "workspace::missing_template"
      help: $"Fix or remove new.template in ((workbench-config-file))."
    }
  }
  if not (is-terminal --stdin) {
    print $"(ansi yellow)skip template \(no terminal to ask\)(ansi reset)"
    return
  }
  # A template from the Nix store is read-only.
  let rows = (copy-secrets (store-files $template $dir) --heading "Template files:" --writable)
  if ($rows | is-not-empty) { print ($rows | table) }
}
