# Shared by `workspace secrets copy`, `workspace clone` and `workspace new`.

const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

const IGNORED_NAMES = [".DS_Store"]

export def secrets-root []: nothing -> path {
  (workbench-config).secrets-root | path expand
}

# The origin remote, not the directory, names the store's tree, so a clone into
# another directory still finds its files.
export def repo-slug [repo: path]: nothing -> oneof<record, nothing> {
  let out = (^git -C $repo remote get-url origin | complete)
  if $out.exit_code != 0 { return null }
  let hit = ($out.stdout
    | str trim
    | parse --regex '[:/](?<org>[^/:]+)/(?<repo>[^/]+?)(?:\.git)?/?$')
  if ($hit | is-empty) { null } else { $hit | first }
}

# Case-insensitive, as GitHub names are.
def child-dir [parent: path, name: string]: nothing -> oneof<path, nothing> {
  if not ($parent | path exists) { return null }
  let wanted = ($name | str lowercase)
  ls --all $parent
  | where type == dir
  | get name
  | where {|d| ($d | path basename | str lowercase) == $wanted }
  | get 0?
}

# Each row is a file to offer: `source` lands at `rel` under `root`, and the
# summary shows `source` relative to `store`.
export def store-files [store: path, root: path]: nothing -> table {
  glob --no-dir ($store | path join "**" "*")
  | where {|f| ($f | path basename) not-in $IGNORED_NAMES }
  | sort
  | each {|f| { root: $root, source: $f, rel: ($f | path relative-to $store), store: $store } }
}

export def secret-files [repo: path]: nothing -> table {
  let slug = (repo-slug $repo)
  if $slug == null { return [] }
  let org_dir = (child-dir (secrets-root) $slug.org)
  let tree = if $org_dir == null { null } else { child-dir $org_dir $slug.repo }
  if $tree == null { return [] }
  store-files $tree $repo
  | update store (secrets-root)
}

export def copy-secrets [
  files: table                                 # Rows from `store-files`
  --heading: string = "Secrets in the store:"
  --writable                                   # Passed to `offer-file`
]: nothing -> table {
  if ($files | is-empty) { return [] }
  print $"(ansi purple_bold)($heading)(ansi reset)"
  for root in ($files | get root | uniq) {
    print ($root | path basename)
    $files
    | where root == $root
    | each {|f| $f.rel | path split }
    | tree-lines ""
    | each {|line| print $line }
    | ignore
  }
  $files | each {|f| offer-file $f --writable=$writable }
}

# Each path is a list of segments. Order follows the input.
def tree-lines [prefix: string]: list<list<string>> -> list<string> {
  let paths = $in
  let names = ($paths | each {|p| $p | first } | uniq)
  let last = (($names | length) - 1)
  $names
  | enumerate
  | each {|e|
      let at_end = ($e.index == $last)
      let branch = if $at_end { "└── " } else { "├── " }
      let indent = if $at_end { "    " } else { "│   " }
      let children = ($paths
        | where {|p| ($p | first) == $e.item and ($p | length) > 1 }
        | each {|p| $p | skip 1 })
      let name = if ($children | is-empty) {
        $"(ansi cyan)($e.item)(ansi reset)"
      } else {
        $e.item
      }
      [$"($prefix)($branch)($name)"]
      | append ($children | tree-lines $"($prefix)($indent)")
    }
  | flatten
}

# Silent without a terminal, so a scripted clone never blocks.
export def offer-secrets [repo: path]: nothing -> nothing {
  if not (is-terminal --stdin) { return }
  let files = (secret-files $repo)
  if ($files | is-empty) { return }
  let rows = (copy-secrets $files)
  if ($rows | is-not-empty) { print ($rows | table) }
}

# Asks what to do with one file, then copies it. A file already in place
# with the same content, or one git tracks, is settled without a prompt.
export def offer-file [
  file: record    # A row from `store-files`
  --writable      # Add the owner's write bit, as a Nix store source is read-only
]: nothing -> record {
  let into = ($file.root | path basename)
  let row = {
    into: $into
    source: ($file.source | path relative-to $file.store)
    dest: $file.rel
    action: "skipped"
    reason: null
  }
  let settled = (settled-row $row $file)
  if $settled != null { return $settled }

  print ""
  print $"(ansi dark_gray)($file.source)(ansi reset)"
  mut rel = $file.rel
  loop {
    match (prompt-action $"($into)/($rel)") {
      "copy" => { break }
      "print" => { show-file $file.source }
      "rename" => {
        $rel = (rename-rel $rel)
        break
      }
      _ => { return ($row | update reason "declined") }
    }
  }

  let renamed = ($rel != $file.rel)
  let row = ($row | update dest $rel)
  let file = ($file | update rel $rel)
  if $renamed {
    let settled = (settled-row $row $file)
    if $settled != null { return $settled }
  }
  if (is-repo $file.root) and not (ignored $file.root $rel) {
    print $"(ansi yellow)($into)/($rel) is not gitignored, so git would offer to commit it.(ansi reset)"
    if not (confirm-prompt "Copy anyway?") {
      return ($row | update reason "not gitignored")
    }
  }
  let dest = ($file.root | path join $rel)
  let exists = ($dest | path exists)
  if $exists and not (confirm-prompt $"($into)/($rel) exists and differs. Overwrite?") {
    return ($row | update reason "kept the existing file")
  }
  mkdir ($dest | path dirname)
  cp --preserve [mode] $file.source $dest
  if $writable { ^chmod u+w $dest }
  $row | update action (if $exists { "overwritten" } else { "copied" })
}

def settled-row [row: record, file: record]: nothing -> oneof<record, nothing> {
  if (is-repo $file.root) and (tracked $file.root $file.rel) {
    return ($row | update reason "tracked by git")
  }
  let dest = ($file.root | path join $file.rel)
  if ($dest | path exists) and ((open --raw $dest) == (open --raw $file.source)) {
    return ($row | update action "unchanged")
  }
  null
}

# One key, no Enter needed. Enter alone copies.
def prompt-action [label: string]: nothing -> string {
  mut action = ""
  while $action == "" {
    print --no-newline $"Copy ($label)? \(Y/p/r/n\) > "
    let key = ((input listen --types [key]).code? | default "" | str lowercase)
    print $key  # `input listen` does not echo
    $action = match $key {
      "enter" | "y" => "copy"
      "p" => "print"
      "r" => "rename"
      "n" | "esc" => "skip"
      _ => {
        print $"(ansi yellow)Press Enter or y to copy, p to print, r to rename, n to skip.(ansi reset)"
        ""
      }
    }
  }
  $action
}

def show-file [source: path]: nothing -> nothing {
  let content = (open --raw $source)
  if ($content | describe) == "binary" {
    print $"(ansi dark_gray)binary file, ($content | bytes length) bytes(ansi reset)"
  } else {
    print $content
  }
}

# The directory comes from the store, so only the file name changes.
def rename-rel [rel: string]: nothing -> string {
  let dir = ($rel | path dirname)
  let default = ($rel | path basename)
  mut name = ""
  while $name == "" {
    let typed = (input --default $default "name > " | str trim)
    $name = if ($typed | is-empty) { $default } else { $typed }
    if ($name | str contains "/") or ($name in [".", ".."]) {
      print $"(ansi yellow)Type a file name only. The directory stays the same.(ansi reset)"
      $name = ""
    }
  }
  if ($dir | is-empty) { $name } else { $dir | path join $name }
}

def is-repo [dir: path]: nothing -> bool {
  $dir | path join ".git" | path exists
}

def tracked [repo: path, rel: string]: nothing -> bool {
  (^git -C $repo ls-files --error-unmatch -- $rel | complete).exit_code == 0
}

def ignored [repo: path, rel: string]: nothing -> bool {
  (^git -C $repo check-ignore --quiet -- $rel | complete).exit_code == 0
}
