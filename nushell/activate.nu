# Sourced by `mise run shell` to load the workspace overlay into an interactive
# Nushell session and define the `workspace use` reload shortcut.
#
#   nu --execute "source nushell/activate.nu"

const MOD = path self | path dirname | path dirname | path join "mod.nu"

overlay use $MOD as workspace

# Reload the overlay after editing any .nu file in this repo. Kept here (not in
# mod.nu) because `overlay use` needs the const $MOD path in the calling scope.
alias "workspace use" = overlay use --reload $MOD as workspace
