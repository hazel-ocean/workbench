use in-each.nu *

# Run `git diff --color=always ...args` inside each repo of a workspace
#
#   workspace diff
#   workspace diff --cached
#   workspace diff HEAD~1 -- src/
export def --wrapped main [
  ...args: string   # Extra arguments forwarded to `git diff`
  --choose (-c)     # Pick a workspace interactively instead of using the current one
  --parallel (-p)   # Run repos concurrently
]: nothing -> table {
  # `--wrapped` forwards --help into $args.
  if ("--help" in $args) or ("-h" in $args) { print (help workspace diff); return }
  # The module's own `rename` command shadows the builtin.
  (in-each --choose=$choose --parallel=$parallel {|| ^git diff --color=always ...$args }
    | each {|row| { repo: $row.repo, diff: $row.result } })
}
