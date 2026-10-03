const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

export def short [sha: oneof<string, nothing>]: nothing -> oneof<string, nothing> {
  if $sha == null { null } else { $sha | str substring 0..<8 }
}
