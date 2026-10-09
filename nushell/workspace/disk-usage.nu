const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Disk usage of every workspace, with a per-repo breakdown
#
#   workspace disk-usage | get 0.repos
export def main []: nothing -> table {
  assert-tool "dua" "measure workspace disk usage"
  workspace-names
  | par-each {|name|
    let entries = (workspace-entry-sizes $name)
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
