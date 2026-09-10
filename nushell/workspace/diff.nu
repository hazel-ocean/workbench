use in-each.nu *

# Run `git diff --color=always ...args` inside each repo of a workspace
#
# Returns a `repo`/`diff` table; `in-each`'s generic `result` column is renamed
# so `| get diff` reads naturally. Built by hand rather than with `rename`, which
# this module shadows with its own `rename` command.
#
# The def is `--wrapped`, so any unrecognized flags, revisions, and paths pass
# straight through to `git diff` (only --choose/--parallel are consumed here):
#   workspace diff
#   workspace diff --cached
#   workspace diff HEAD~1 -- src/
export def --wrapped main [
  ...args: string   # Extra arguments forwarded to `git diff`
  --choose (-c)     # Pick a workspace interactively instead of using the current one
  --parallel (-p)   # Run repos concurrently
]: nothing -> table {
  # `--wrapped` forwards --help into $args, so handle it ourselves.
  if ("--help" in $args) or ("-h" in $args) { print (help workspace diff); return }
  (in-each --choose=$choose --parallel=$parallel {|| ^git diff --color=always ...$args }
    | each {|row| { repo: $row.repo, diff: $row.result } })
}
