//go:build !darwin || !cgo

package lib

import (
	"encoding/json"
	"fmt"
)

func unsupported() (json.RawMessage, error) {
	return nil, fmt.Errorf("platform-imessage bridge is only supported on macOS with cgo")
}

func Init(dataDir string, verbose, useSecondaryInstance, coordinateWindow bool) (json.RawMessage, error) {
	return unsupported()
}

func Dispose() (json.RawMessage, error) {
	return unsupported()
}

func CurrentUser() (json.RawMessage, error) {
	return unsupported()
}

func AuthorizationStatus() (json.RawMessage, error) {
	return unsupported()
}

func RequestAuthorization(target string) (json.RawMessage, error) {
	return unsupported()
}

func Chats(paginationJSON string) (json.RawMessage, error) {
	return unsupported()
}

func Chat(threadID string) (json.RawMessage, error) {
	return unsupported()
}

func Messages(threadID, paginationJSON string) (json.RawMessage, error) {
	return unsupported()
}

func SendText(threadID, text, quotedMessageID string) (json.RawMessage, error) {
	return unsupported()
}

func SendFile(threadID, filePath, quotedMessageID string) (json.RawMessage, error) {
	return unsupported()
}

func CreateChat(recipientsJSON, messageText, title string) (json.RawMessage, error) {
	return unsupported()
}

func Edit(threadID, messageID, text string) (json.RawMessage, error) {
	return unsupported()
}

func DeleteMessage(threadID, messageID string) (json.RawMessage, error) {
	return unsupported()
}

func React(threadID, messageID, reactionKey string, enabled bool) (json.RawMessage, error) {
	return unsupported()
}

func MarkRead(threadID string) (json.RawMessage, error) {
	return unsupported()
}

func MarkUnread(threadID string) (json.RawMessage, error) {
	return unsupported()
}

func Mute(threadID string, muted bool) (json.RawMessage, error) {
	return unsupported()
}

func DeleteChat(threadID string) (json.RawMessage, error) {
	return unsupported()
}

func NotifyAnyway(threadID string) (json.RawMessage, error) {
	return unsupported()
}

func ActivityStatus(threadID string) (json.RawMessage, error) {
	return unsupported()
}

func Typing(threadID string, enabled bool) (json.RawMessage, error) {
	return unsupported()
}

func WatchChat(threadID string) (json.RawMessage, error) {
	return unsupported()
}

func SearchMessages(query, threadID, paginationJSON string, limit int) (json.RawMessage, error) {
	return unsupported()
}

func GetAsset(pathHex, methodName string) (json.RawMessage, error) {
	return unsupported()
}

func LoadAttachment(messageID string) (json.RawMessage, error) {
	return unsupported()
}

func StartEvents() (json.RawMessage, error) {
	return unsupported()
}

func NextEvents(timeoutMilliseconds int) (json.RawMessage, error) {
	return unsupported()
}
