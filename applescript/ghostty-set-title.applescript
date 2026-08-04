-- Set the focused Ghostty tab's title to a persistent manual override.
--
-- Ghostty's window `name` is read-only via AppleScript (-10006), and OSC-2
-- titles get overwritten every prompt by the shell's osc2 integration. The only
-- durable path is the "Change Tab Title..." action (View menu / cmd+shift+p),
-- which pins a manual override that stops tracking cwd/OSC. There is no Ghostty
-- CLI/IPC for it, so we drive the menu item and type into its dialog.
--
-- Requires Accessibility permission for whatever runs this (System Events).
on run argv
  set newTitle to item 1 of argv
  tell application "Ghostty" to activate
  delay 0.2
  tell application "System Events"
    tell process "Ghostty"
      click menu item "Change Tab Title..." of menu 1 of menu bar item "View" of menu bar 1
    end tell
    delay 0.25
    keystroke "a" using command down
    keystroke newTitle
    key code 36
  end tell
end run
