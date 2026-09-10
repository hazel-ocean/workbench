# Repo selection and formatting shared by the `workspace branch` subcommands.
#
# Imported with a plain `use`, so it stays out of the public `workspace` overlay.

const UTIL = path self | path dirname | path dirname | path dirname | path join "util.nu"
use $UTIL *

# Abbreviate a sha for display; the full value is what gets recorded.
export def short [sha: oneof<string, nothing>]: nothing -> oneof<string, nothing> {
  if $sha == null { null } else { $sha | str substring 0..<8 }
}

# The git repo holding PWD, when PWD is outside every workspace. Null inside a
# workspace, and null when PWD is in no repo at all.
export def loose-repo []: nothing -> oneof<path, nothing> {
  if (try-infer-workspace) != null { return null }
  let out = (^git -C $env.PWD rev-parse --show-toplevel | complete)
  if $out.exit_code != 0 { return null }
  $out.stdout | str trim
}

# The repos a command acts on: the whole workspace, or the one named by --repo.
#
# Outside a workspace it falls back to the enclosing git repo, so a plain
# checkout such as nix-config gets the same behaviour scoped to itself. --choose
# asks for a workspace by name, so it never takes the fallback.
export def target-repos [
  choose: bool
  only: oneof<string, nothing>
]: nothing -> list<path> {
  let loose = (if $choose { null } else { loose-repo })
  if $loose != null {
    let name = ($loose | path basename)
    if $only != null and $only != $name {
      error make --unspanned {
        msg: $"No repo '($only)' here."
        code: "workspace::unknown_repo"
        help: $"Outside a workspace this acts on '($name)' alone."
      }
    }
    print $"(ansi yellow)Not in a workspace; syncing only ($name)(ansi reset)"
    return [$loose]
  }
  let all = (workspace-repos (select-workspace $choose))
  if ($all | is-empty) {
    error make --unspanned {
      msg: "No git repos found in this workspace."
      code: "workspace::no_repos"
      help: "Clone one with `workspace clone <repo>`."
    }
  }
  if $only == null { return $all }
  let hit = ($all | where {|r| ($r | path basename) == $only })
  if ($hit | is-empty) {
    let names = ($all | each {|r| $r | path basename } | str join ", ")
    error make --unspanned {
      msg: $"No repo '($only)' in this workspace."
      code: "workspace::unknown_repo"
      help: $"Available: ($names)."
    }
  }
  $hit
}
