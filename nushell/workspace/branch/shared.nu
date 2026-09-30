# Formatting shared by the `workspace branch` subcommands.
#
# Imported with a plain `use`, so it stays out of the public `workspace` overlay.

const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Abbreviate a sha for display; the full value is what gets recorded.
export def short [sha: oneof<string, nothing>]: nothing -> oneof<string, nothing> {
  if $sha == null { null } else { $sha | str substring 0..<8 }
}
