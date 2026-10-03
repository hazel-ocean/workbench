# Sourced by `mise run shell`.

const MOD = path self | path dirname | path dirname | path join "mod.nu"

overlay use $MOD as workspace

# Not in mod.nu: `overlay use` needs the const $MOD in the calling scope.
alias "workspace use" = overlay use --reload $MOD as workspace
