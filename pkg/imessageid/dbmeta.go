package imessageid

type UserLoginMetadata struct {
	DisplayText string `json:"display_text,omitempty"`
	Email       string `json:"email,omitempty"`
	PhoneNumber string `json:"phone_number,omitempty"`
}

type PortalMetadata struct {
	ThreadType string `json:"thread_type,omitempty"`
}

type MessageMetadata struct {
	ThreadID       string   `json:"thread_id,omitempty"`
	Cursor         string   `json:"cursor,omitempty"`
	Attachment     bool     `json:"attachment,omitempty"`
	AttachmentIDs  []string `json:"attachment_ids,omitempty"`
	AttachmentURLs []string `json:"attachment_urls,omitempty"`
}

type ReactionMetadata struct {
	ReactionID  string `json:"reaction_id,omitempty"`
	ReactionKey string `json:"reaction_key,omitempty"`
}

type GhostMetadata struct {
	ContactID string `json:"contact_id,omitempty"`
}
