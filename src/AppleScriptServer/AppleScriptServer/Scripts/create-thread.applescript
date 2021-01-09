tell application "Messages" to set imsgService to 1st service whose service type = iMessage
tell application "Messages" to set thread to make new text chat with properties {participants:{${1}}}
get thread
