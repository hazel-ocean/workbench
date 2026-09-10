# Print the absolute path of the workspaces root
export def main []: nothing -> path {
  $env.WORKBENCH_WORKSPACES_ROOT
}
