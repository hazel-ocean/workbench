# Workspace management commands.
#
# A workspace is a directory under the workspaces root holding the repos for
# one task, operated on together.
#
#   workspace new ENG-123 web-app api-service   # create + clone
#   workspace branch new eng-123-fix
#   workspace branch sync
#   workspace list

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
export use secrets
