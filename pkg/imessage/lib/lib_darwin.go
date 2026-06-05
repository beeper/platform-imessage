//go:build darwin && cgo

package lib

/*
#cgo darwin LDFLAGS: -lIMessageBridgeKit
#include <stdint.h>
#include <stdlib.h>

char *imessage_bridge_init(const char *data_dir, int32_t verbose, int32_t use_secondary_instance, int32_t coordinate_window);
char *imessage_bridge_dispose(void);
char *imessage_bridge_current_user(void);
char *imessage_bridge_authorization_status(void);
char *imessage_bridge_request_authorization(const char *target);
char *imessage_bridge_chats(const char *pagination_json);
char *imessage_bridge_chat(const char *thread_id);
char *imessage_bridge_messages(const char *thread_id, const char *pagination_json);
char *imessage_bridge_send_text(const char *thread_id, const char *text, const char *quoted_message_id);
char *imessage_bridge_send_file(const char *thread_id, const char *file_path, const char *quoted_message_id);
char *imessage_bridge_create_chat(const char *recipients_json, const char *message_text, const char *title);
char *imessage_bridge_edit(const char *thread_id, const char *message_id, const char *text);
char *imessage_bridge_delete_message(const char *thread_id, const char *message_id);
char *imessage_bridge_react(const char *thread_id, const char *message_id, const char *reaction_key, int32_t enabled);
char *imessage_bridge_mark_read(const char *thread_id);
char *imessage_bridge_mark_unread(const char *thread_id);
char *imessage_bridge_mute(const char *thread_id, int32_t muted);
char *imessage_bridge_delete_chat(const char *thread_id);
char *imessage_bridge_notify_anyway(const char *thread_id);
char *imessage_bridge_activity_status(const char *thread_id);
char *imessage_bridge_typing(const char *thread_id, int32_t enabled);
char *imessage_bridge_watch_chat(const char *thread_id);
char *imessage_bridge_search_messages(const char *query, const char *thread_id, const char *pagination_json, int32_t limit);
char *imessage_bridge_get_asset(const char *path_hex, const char *method_name);
char *imessage_bridge_load_attachment(const char *message_id);
char *imessage_bridge_start_events(void);
char *imessage_bridge_next_events(int32_t timeout_milliseconds);
void imessage_bridge_free(char *pointer);
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"unsafe"
)

type Response struct {
	OK      bool            `json:"ok"`
	Error   string          `json:"error,omitempty"`
	Payload json.RawMessage `json:"payload"`
}

func call(fn func() *C.char) (json.RawMessage, error) {
	ptr := fn()
	if ptr == nil {
		return nil, fmt.Errorf("swift bridge returned nil")
	}
	defer C.imessage_bridge_free(ptr)

	var resp Response
	if err := json.Unmarshal([]byte(C.GoString(ptr)), &resp); err != nil {
		return nil, fmt.Errorf("failed to decode swift bridge response: %w", err)
	}
	if !resp.OK {
		if resp.Error == "" {
			resp.Error = "unknown swift bridge error"
		}
		return nil, fmt.Errorf("%s", resp.Error)
	}
	return resp.Payload, nil
}

func cstr(input string) (*C.char, func()) {
	value := C.CString(input)
	return value, func() { C.free(unsafe.Pointer(value)) }
}

func optionalCStr(input string) (*C.char, func()) {
	if input == "" {
		return nil, func() {}
	}
	return cstr(input)
}

func Init(dataDir string, verbose, useSecondaryInstance, coordinateWindow bool) (json.RawMessage, error) {
	dataDirC, freeDataDir := cstr(dataDir)
	defer freeDataDir()
	return call(func() *C.char {
		return C.imessage_bridge_init(dataDirC, boolToCInt(verbose), boolToCInt(useSecondaryInstance), boolToCInt(coordinateWindow))
	})
}

func Dispose() (json.RawMessage, error) {
	return call(func() *C.char { return C.imessage_bridge_dispose() })
}

func CurrentUser() (json.RawMessage, error) {
	return call(func() *C.char { return C.imessage_bridge_current_user() })
}

func AuthorizationStatus() (json.RawMessage, error) {
	return call(func() *C.char { return C.imessage_bridge_authorization_status() })
}

func RequestAuthorization(target string) (json.RawMessage, error) {
	targetC, freeTarget := optionalCStr(target)
	defer freeTarget()
	return call(func() *C.char { return C.imessage_bridge_request_authorization(targetC) })
}

func Chats(paginationJSON string) (json.RawMessage, error) {
	paginationC, freePagination := optionalCStr(paginationJSON)
	defer freePagination()
	return call(func() *C.char { return C.imessage_bridge_chats(paginationC) })
}

func Chat(threadID string) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	return call(func() *C.char { return C.imessage_bridge_chat(threadIDC) })
}

func Messages(threadID, paginationJSON string) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	paginationC, freePagination := optionalCStr(paginationJSON)
	defer freePagination()
	return call(func() *C.char { return C.imessage_bridge_messages(threadIDC, paginationC) })
}

func SendText(threadID, text, quotedMessageID string) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	textC, freeText := cstr(text)
	defer freeText()
	quotedC, freeQuoted := optionalCStr(quotedMessageID)
	defer freeQuoted()
	return call(func() *C.char { return C.imessage_bridge_send_text(threadIDC, textC, quotedC) })
}

func SendFile(threadID, filePath, quotedMessageID string) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	filePathC, freeFilePath := cstr(filePath)
	defer freeFilePath()
	quotedC, freeQuoted := optionalCStr(quotedMessageID)
	defer freeQuoted()
	return call(func() *C.char { return C.imessage_bridge_send_file(threadIDC, filePathC, quotedC) })
}

func CreateChat(recipientsJSON, messageText, title string) (json.RawMessage, error) {
	recipientsC, freeRecipients := cstr(recipientsJSON)
	defer freeRecipients()
	messageC, freeMessage := cstr(messageText)
	defer freeMessage()
	titleC, freeTitle := optionalCStr(title)
	defer freeTitle()
	return call(func() *C.char { return C.imessage_bridge_create_chat(recipientsC, messageC, titleC) })
}

func Edit(threadID, messageID, text string) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	messageIDC, freeMessageID := cstr(messageID)
	defer freeMessageID()
	textC, freeText := cstr(text)
	defer freeText()
	return call(func() *C.char { return C.imessage_bridge_edit(threadIDC, messageIDC, textC) })
}

func DeleteMessage(threadID, messageID string) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	messageIDC, freeMessageID := cstr(messageID)
	defer freeMessageID()
	return call(func() *C.char { return C.imessage_bridge_delete_message(threadIDC, messageIDC) })
}

func React(threadID, messageID, reactionKey string, enabled bool) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	messageIDC, freeMessageID := cstr(messageID)
	defer freeMessageID()
	reactionC, freeReaction := cstr(reactionKey)
	defer freeReaction()
	return call(func() *C.char {
		return C.imessage_bridge_react(threadIDC, messageIDC, reactionC, boolToCInt(enabled))
	})
}

func MarkRead(threadID string) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	return call(func() *C.char { return C.imessage_bridge_mark_read(threadIDC) })
}

func MarkUnread(threadID string) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	return call(func() *C.char { return C.imessage_bridge_mark_unread(threadIDC) })
}

func Mute(threadID string, muted bool) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	return call(func() *C.char { return C.imessage_bridge_mute(threadIDC, boolToCInt(muted)) })
}

func DeleteChat(threadID string) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	return call(func() *C.char { return C.imessage_bridge_delete_chat(threadIDC) })
}

func NotifyAnyway(threadID string) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	return call(func() *C.char { return C.imessage_bridge_notify_anyway(threadIDC) })
}

func ActivityStatus(threadID string) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	return call(func() *C.char { return C.imessage_bridge_activity_status(threadIDC) })
}

func Typing(threadID string, enabled bool) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	return call(func() *C.char { return C.imessage_bridge_typing(threadIDC, boolToCInt(enabled)) })
}

func WatchChat(threadID string) (json.RawMessage, error) {
	threadIDC, freeThreadID := cstr(threadID)
	defer freeThreadID()
	return call(func() *C.char { return C.imessage_bridge_watch_chat(threadIDC) })
}

func SearchMessages(query, threadID, paginationJSON string, limit int) (json.RawMessage, error) {
	queryC, freeQuery := cstr(query)
	defer freeQuery()
	threadIDC, freeThreadID := optionalCStr(threadID)
	defer freeThreadID()
	paginationC, freePagination := optionalCStr(paginationJSON)
	defer freePagination()
	return call(func() *C.char {
		return C.imessage_bridge_search_messages(queryC, threadIDC, paginationC, C.int32_t(limit))
	})
}

func GetAsset(pathHex, methodName string) (json.RawMessage, error) {
	pathHexC, freePathHex := cstr(pathHex)
	defer freePathHex()
	methodC, freeMethod := optionalCStr(methodName)
	defer freeMethod()
	return call(func() *C.char { return C.imessage_bridge_get_asset(pathHexC, methodC) })
}

func LoadAttachment(messageID string) (json.RawMessage, error) {
	messageIDC, freeMessageID := cstr(messageID)
	defer freeMessageID()
	return call(func() *C.char { return C.imessage_bridge_load_attachment(messageIDC) })
}

func StartEvents() (json.RawMessage, error) {
	return call(func() *C.char { return C.imessage_bridge_start_events() })
}

func NextEvents(timeoutMilliseconds int) (json.RawMessage, error) {
	return call(func() *C.char { return C.imessage_bridge_next_events(C.int32_t(timeoutMilliseconds)) })
}

func boolToCInt(value bool) C.int32_t {
	if value {
		return 1
	}
	return 0
}
