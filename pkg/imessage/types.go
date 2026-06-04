package imessage

import "encoding/json"

type CurrentUser struct {
	ID          string `json:"id"`
	DisplayText string `json:"displayText,omitempty"`
	Email       string `json:"email,omitempty"`
	PhoneNumber string `json:"phoneNumber,omitempty"`
}

type Page[T any] struct {
	Items        []T    `json:"items"`
	HasMore      bool   `json:"hasMore"`
	OldestCursor string `json:"oldestCursor,omitempty"`
	NewestCursor string `json:"newestCursor,omitempty"`
}

type Pagination struct {
	Cursor    string `json:"cursor"`
	Direction string `json:"direction"`
}

func (p *Pagination) JSON() (string, error) {
	if p == nil || p.Cursor == "" || p.Direction == "" {
		return "", nil
	}
	data, err := json.Marshal(p)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

type ThreadType string

const (
	ThreadTypeSingle ThreadType = "single"
	ThreadTypeGroup  ThreadType = "group"
)

type Thread struct {
	ID                   string     `json:"id"`
	Title                string     `json:"title,omitempty"`
	Type                 ThreadType `json:"type"`
	Timestamp            int64      `json:"timestamp,omitempty"`
	ImgURL               string     `json:"imgURL,omitempty"`
	IsReadOnly           bool       `json:"isReadOnly"`
	Participants         Page[User] `json:"participants"`
	PartialLastMessage   *Message   `json:"partialLastMessage,omitempty"`
	MessageExpirySeconds *int       `json:"messageExpirySeconds,omitempty"`
	Extra                any        `json:"extra,omitempty"`
}

type User struct {
	ID          string `json:"id"`
	Username    string `json:"username,omitempty"`
	PhoneNumber string `json:"phoneNumber,omitempty"`
	Email       string `json:"email,omitempty"`
	FullName    string `json:"fullName,omitempty"`
	Nickname    string `json:"nickname,omitempty"`
	ImgURL      string `json:"imgURL,omitempty"`
	IsSelf      *bool  `json:"isSelf,omitempty"`
}

type Message struct {
	ID                    string       `json:"id"`
	Timestamp             int64        `json:"timestamp"`
	EditedTimestamp       int64        `json:"editedTimestamp,omitempty"`
	SenderID              string       `json:"senderID"`
	Text                  string       `json:"text,omitempty"`
	Attachments           []Attachment `json:"attachments,omitempty"`
	Reactions             []Reaction   `json:"reactions,omitempty"`
	IsSender              *bool        `json:"isSender,omitempty"`
	IsAction              *bool        `json:"isAction,omitempty"`
	IsDeleted             *bool        `json:"isDeleted,omitempty"`
	IsErrored             *bool        `json:"isErrored,omitempty"`
	LinkedMessageThreadID string       `json:"linkedMessageThreadID,omitempty"`
	LinkedMessageID       string       `json:"linkedMessageID,omitempty"`
	ThreadID              string       `json:"threadID,omitempty"`
	Cursor                string       `json:"cursor,omitempty"`
	Extra                 any          `json:"extra,omitempty"`
}

type Attachment struct {
	ID          string `json:"id"`
	Type        string `json:"type"`
	MimeType    string `json:"mimeType,omitempty"`
	FileName    string `json:"fileName,omitempty"`
	FileSize    int64  `json:"fileSize,omitempty"`
	SrcURL      string `json:"srcURL,omitempty"`
	IsGif       bool   `json:"isGif,omitempty"`
	IsSticker   bool   `json:"isSticker,omitempty"`
	IsVoiceNote bool   `json:"isVoiceNote,omitempty"`
}

type Asset struct {
	URL        string `json:"url,omitempty"`
	DataBase64 string `json:"dataBase64,omitempty"`
}

type Reaction struct {
	ID            string `json:"id"`
	ReactionKey   string `json:"reactionKey"`
	ParticipantID string `json:"participantID"`
}

type StateSyncEvent struct {
	Type         string          `json:"type"`
	ObjectName   string          `json:"objectName"`
	MutationType string          `json:"mutationType"`
	ObjectIDs    StateSyncIDs    `json:"objectIDs"`
	Entries      json.RawMessage `json:"entries"`
}

type StateSyncIDs struct {
	ThreadID  string `json:"threadID,omitempty"`
	MessageID string `json:"messageID,omitempty"`
}
