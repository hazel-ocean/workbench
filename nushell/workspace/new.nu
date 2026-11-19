const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *
use clone.nu *
use secrets/shared.nu *

# Create a new workspace and cd into it, optionally cloning repos
#
# A workspace under the root also gets the config's `new.template` files,
# each offered with a prompt, and its `new.clone` repos. Both skip what is
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
  # The named repos go first, so a ref given for a `new.clone` repo wins.
  # `clone` skips the second copy.
  let all = if $under_root { $repos ++ $config.new.clone } else { $repos }
  if not ($all | is-empty) {
    clone ...$all --full=$full
  }
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
  let rows = (store-files $template $dir | each {|f| offer-file $f --writable })
  if ($rows | is-not-empty) { print ($rows | table) }
}
