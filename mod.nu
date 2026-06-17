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
  $env.WORKSPACES_ROOT = $DIR_SELF | path join "workspaces"
  let org_file = $DIR_SELF | path join ".github" "default-org"
  $env.WORKSPACES_GH_ORG = $env.WORKSPACES_GH_ORG? | default (
    if ($org_file | path exists) { open $org_file | str trim } else { null }
  )
}

export module nushell/workspace.nu
