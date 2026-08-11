# Workspaces overlay entry point.
#
# Load directly:
#   overlay use mod.nu as workspace
#   overlay use --reload mod.nu as workspace   # after editing a .nu file
#
# Or drop into a preconfigured Nushell via mise:
#   mise run shell
#
# See `help workspace` (and `workspace <tab>`) for available commands.

const DIR_SELF = path self | path dirname

export-env {
  let dotenv = $DIR_SELF | path join ".env"
  let vars = if ($dotenv | path exists) {
    open --raw $dotenv
    | lines
    | each {|line| $line | str trim }
    | where {|line| $line != "" and not ($line | str starts-with "#") }
    | each {|line| $line | split row --number 2 "=" }
    | where {|pair| ($pair | length) == 2 }
    | reduce --fold {} {|pair, acc|
        let key = $pair.0 | str trim | str replace -r '^export\s+' ''
        let value = $pair.1 | str trim | str trim --char '"' | str trim --char "'"
        $acc | insert $key $value
      }
  } else { {} }

  # Real environment wins so a one-off `FOO=x nu ...` overrides .env.
  for entry in ($vars | transpose key value) {
    if ($env | get --optional $entry.key | is-empty) {
      load-env { $entry.key: $entry.value }
    }
  }

  $env.WORKBENCH_WORKSPACES_ROOT = $env.WORKBENCH_WORKSPACES_ROOT? | default (
    $DIR_SELF | path join "workspaces"
  )
  $env.WORKBENCH_DEFAULT_GITHUB_ORG = $env.WORKBENCH_DEFAULT_GITHUB_ORG? | default null
}

export module nushell/workspace
