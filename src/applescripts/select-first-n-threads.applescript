activate application "Messages"
tell application "System Events" to keystroke "1" using command down
delay 0.01
repeat ${0} times
	tell application "System Events" to keystroke "]" using command down
	delay 0.01
end repeat
