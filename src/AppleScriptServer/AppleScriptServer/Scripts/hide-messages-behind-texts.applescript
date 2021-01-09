tell application "System Events"
tell application process "${0}" to set {textsSize, textsPos} to {size, position} of window 0
tell application process "Messages" to tell window 0 to set {size, position} to {textsSize, textsPos}
end tell
