# The secrets store and the copy flow, shared by `workspace secrets copy` and
# the offer `workspace clone` makes after each clone.
#
# Imported with a plain `use`, so it stays out of the public `workspace` overlay.

const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Finder litter that is never a secret.
const IGNORED_NAMES = [".DS_Store"]

export def secrets-root []: nothing -> path {
  $env.WORKBENCH_SECRETS_ROOT | path expand
}

# A repo's `{org, repo}` from its origin URL, or null when it has no origin in
# that shape. Both `git@host:org/repo.git` and `https://host/org/repo` parse.
#
# The remote names the store's tree, not the directory, so a clone made with
# `workspace clone web-app=alt` still finds `<org>/web-app`.
export def repo-slug [repo: path]: nothing -> oneof<record, nothing> {
  let out = (^git -C $repo remote get-url origin | complete)
  if $out.exit_code != 0 { return null }
  let hit = ($out.stdout
    | str trim
    | parse --regex '[:/](?<org>[^/:]+)/(?<repo>[^/]+?)(?:\.git)?/?$')
  if ($hit | is-empty) { null } else { $hit | first }
}

# The subdirectory of `parent` named `name`, ignoring case as GitHub does.
def child-dir [parent: path, name: string]: nothing -> oneof<path, nothing> {
  if not ($parent | path exists) { return null }
  let wanted = ($name | str lowercase)
  ls --all $parent
  | where type == dir
  | get name
  | where {|d| ($d | path basename | str lowercase) == $wanted }
  | get 0?
}

# Every file in a repo's tree in the store, as `{repo, source, rel}` rows, where
# `rel` is both the path under the tree and the destination under the repo.
# Empty when the store has no tree for the repo.
export def secret-files [repo: path]: nothing -> table {
  let slug = (repo-slug $repo)
  if $slug == null { return [] }
  let org_dir = (child-dir (secrets-root) $slug.org)
  let tree = if $org_dir == null { null } else { child-dir $org_dir $slug.repo }
  if $tree == null { return [] }
  glob --no-dir ($tree | path join "**" "*")
  | where {|f| ($f | path basename) not-in $IGNORED_NAMES }
  | sort
  | each {|f| { repo: $repo, source: $f, rel: ($f | path relative-to $tree) } }
}

# Pick files from `files`, name each, and copy it in. One row per pick, with
# `action` one of copied, overwritten, unchanged or skipped. An empty pick
# copies nothing and returns no rows.
export def copy-secrets [files: table]: nothing -> table {
  let picked = ($files
    | input list --multi --fuzzy --display {|f| $"($f.repo | path basename)/($f.rel)" } "Secrets to copy:")
  if ($picked | is-empty) { return [] }
  $picked | each {|f| copy-one $f }
}

# The copy offer made after a clone: silent when the store holds nothing for the
# repo, and when stdin is no terminal, so a scripted clone never blocks on it.
export def offer-secrets [repo: path]: nothing -> nothing {
  if not (is-terminal --stdin) { return }
  let files = (secret-files $repo)
  if ($files | is-empty) { return }
  let rows = (copy-secrets $files)
  if ($rows | is-not-empty) { print ($rows | table) }
}

def copy-one [file: record]: nothing -> record {
  let repo_name = ($file.repo | path basename)
  let dir = ($file.rel | path dirname)
  let into = if ($dir | is-empty) { $repo_name } else { $repo_name | path join $dir }
  let name = (prompt-file-name $file.source $into ($file.rel | path basename))
  let rel = if ($dir | is-empty) { $name } else { $dir | path join $name }
  let dest = ($file.repo | path join $rel)
  let row = {
    repo: $repo_name
    source: ($file.source | path relative-to (secrets-root))
    dest: $rel
    action: "skipped"
    reason: null
  }
  # A tracked file is the repo's own; replacing it would show up as a change.
  if (tracked $file.repo $rel) {
    return ($row | update reason "tracked by git")
  }
  if not (ignored $file.repo $rel) {
    print $"(ansi yellow)($repo_name)/($rel) is not gitignored, so git would offer to commit it.(ansi reset)"
    if not (confirm-prompt "Copy anyway?") {
      return ($row | update reason "not gitignored")
    }
  }
  let exists = ($dest | path exists)
  if $exists {
    if (open --raw $dest) == (open --raw $file.source) {
      return ($row | update action "unchanged")
    }
    if not (confirm-prompt $"($repo_name)/($rel) exists and differs. Overwrite?") {
      return ($row | update reason "kept the existing file")
    }
  }
  mkdir ($dest | path dirname)
  cp --preserve [mode] $file.source $dest
  $row | update action (if $exists { "overwritten" } else { "copied" })
}

# Ask for the name a file lands under. The directory is fixed by the file's
# place in the store, so only the name is asked for; Enter keeps `default`.
def prompt-file-name [
  source: path
  into: string   # Destination directory, relative to the workspace
  default: string
]: nothing -> string {
  print ""
  print $"(ansi dark_gray)($source)(ansi reset)"
  print $"into (ansi cyan)($into)/(ansi reset)"
  mut name = $default
  loop {
    $name = (input --default $default "name > " | str trim)
    if ($name | is-empty) { $name = $default }
    if not (($name | str contains "/") or ($name in [".", ".."])) { break }
    print $"(ansi yellow)Type a file name only. The directory comes from the store.(ansi reset)"
  }
  $name
}

def tracked [repo: path, rel: string]: nothing -> bool {
  (^git -C $repo ls-files --error-unmatch -- $rel | complete).exit_code == 0
}

def ignored [repo: path, rel: string]: nothing -> bool {
  (^git -C $repo check-ignore --quiet -- $rel | complete).exit_code == 0
}
