const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Disk usage of every workspace, with a per-repo breakdown
#
#   workspace disk-usage | get 0.repos
export def main []: nothing -> table {
  assert-tool "dua" "measure workspace disk usage"
  let home = (workspace-home)
  workspace-names
  | par-each {|name|
    let entries = (entry-sizes $name ($name == $home))
    let repos = (workspace-repos $name)
    {
      workspace: $name
      size: ($entries | get size | math sum | default 0b)
      repos: (
        $entries
        | where path in $repos
        | each {|e| { repo: ($e.path | path basename) size: $e.size } }
        | sort-by --reverse size
      )
    }
  }
  | sort-by --reverse size
}

def entry-sizes [name: string, home: bool]: nothing -> table {
  let dir = (workspace-dir $name)
  # The home workspace is itself the repo, and it contains the workspaces root.
  let inputs = if $home { [$dir] } else { ls --all $dir | get name }
  let ignore = if $home {
    [--ignore-dirs $env.WORKBENCH_WORKSPACES_ROOT]
  } else {
    []
  }
  let rows = match ($inputs | length) {
    # `dua` with no inputs measures the cwd.
    0 => []
    _ => (dua-rows ...$ignore ...$inputs)
  }
  match ($inputs | length) {
    # `dua` lists the children of a lone directory input, not the input.
    1 => [{ path: $inputs.0 size: ($rows | get size | math sum | default 0b) }]
    _ => $rows
  }
}

def dua-rows [...args: string]: nothing -> table {
  ^dua aggregate --format bytes --no-total --no-sort ...$args
  | complete
  | get stdout
  | lines
  | parse --regex '^\s*(?<bytes>\d+) b (?<path>.+)$'
  | each {|row| { path: $row.path size: ($row.bytes | into filesize) } }
}
