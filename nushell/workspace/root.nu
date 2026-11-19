const UTIL = path self | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Print the absolute path of the workspaces root
export def main []: nothing -> path {
  (workbench-config).workspaces-root
}
