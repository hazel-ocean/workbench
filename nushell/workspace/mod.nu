# Workspace management commands.
#
# A "Workspace" is a direct subdirectory of the workspaces root. Inside a
# workspace you clone the repos needed for a given task (e.g. a Linear ticket)
# and operate on all of them at once.
#
# Typical flow:
#   workspace new ENG-123 web-app api-service          # create + clone
#   workspace in-each {|| git fetch origin main:main; git rebase main --autostash}
#   workspace in-each {|| git checkout -b eng-123-fix}
#   workspace list
#
# Reload after editing these files:
#   workspace use

# One command per file, re-exported here. A file's `main` takes the file's own
# name, so `info.nu` is `workspace info`; a directory of commands nests, so
# `zellij/attach.nu` is `workspace zellij attach`.
export use root.nu *
export use list.nu *
export use info.nu *
export use metadata.nu *
export use new.nu *
export use clone.nu *
export use attach.nu *
export use enter.nu *
export use rename.nu *
export use delete.nu *
export use trash.nu *
export use diff.nu *
export use in-each.nu *
export use zellij
export use branch
