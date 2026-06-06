package imessage

import (
	"encoding/json"
	"fmt"

	"github.com/beeper/platform-imessage/pkg/imessage/lib"
)

type Client struct{}

func Init(dataDir string, verbose, useSecondaryInstance, coordinateWindow bool) error {
	_, err := lib.Init(dataDir, verbose, useSecondaryInstance, coordinateWindow)
	return err
}

func Dispose() error {
	_, err := lib.Dispose()
	return err
}

func NewClient() *Client {
	return &Client{}
}

func decode[T any](raw json.RawMessage) (out T, err error) {
	if len(raw) == 0 || string(raw) == "null" {
		return out, nil
	}
	err = json.Unmarshal(raw, &out)
	return
}

func (c *Client) CurrentUser() (*CurrentUser, error) {
	raw, err := lib.CurrentUser()
	if err != nil {
		return nil, err
	}
	user, err := decode[CurrentUser](raw)
	if err != nil {
		return nil, fmt.Errorf("failed to decode current user: %w", err)
	}
	return &user, nil
}

func (c *Client) AuthorizationStatus() (*AuthorizationStatus, error) {
	raw, err := lib.AuthorizationStatus()
	if err != nil {
		return nil, err
	}
	status, err := decode[AuthorizationStatus](raw)
	if err != nil {
		return nil, fmt.Errorf("failed to decode authorization status: %w", err)
	}
	return &status, nil
}

func (c *Client) RequestAuthorization(target string) (*AuthorizationStatus, error) {
	raw, err := lib.RequestAuthorization(target)
	if err != nil {
		return nil, err
	}
	status, err := decode[AuthorizationStatus](raw)
	if err != nil {
		return nil, fmt.Errorf("failed to decode authorization status: %w", err)
	}
	return &status, nil
}

func (c *Client) Chats(pagination *Pagination) (*Page[Thread], error) {
	paginationJSON, err := pagination.JSON()
	if err != nil {
		return nil, err
	}
	raw, err := lib.Chats(paginationJSON)
	if err != nil {
		return nil, err
	}
	page, err := decode[Page[Thread]](raw)
	if err != nil {
		return nil, fmt.Errorf("failed to decode chats: %w", err)
	}
	return &page, nil
}

func (c *Client) Chat(threadID string) (*Thread, error) {
	raw, err := lib.Chat(threadID)
	if err != nil {
		return nil, err
	}
	if string(raw) == "null" {
		return nil, nil
	}
	thread, err := decode[Thread](raw)
	if err != nil {
		return nil, fmt.Errorf("failed to decode chat: %w", err)
	}
	return &thread, nil
}

func (c *Client) Messages(threadID string, pagination *Pagination) (*Page[Message], error) {
	paginationJSON, err := pagination.JSON()
	if err != nil {
		return nil, err
	}
	raw, err := lib.Messages(threadID, paginationJSON)
	if err != nil {
		return nil, err
	}
	page, err := decode[Page[Message]](raw)
	if err != nil {
		return nil, fmt.Errorf("failed to decode messages: %w", err)
	}
	return &page, nil
}

func (c *Client) SendText(threadID, text, quotedMessageID string) ([]Message, error) {
	raw, err := lib.SendText(threadID, text, quotedMessageID)
	if err != nil {
		return nil, err
	}
	return decodeSendResult(raw)
}

func (c *Client) SendFile(threadID, filePath, quotedMessageID string) ([]Message, error) {
	raw, err := lib.SendFile(threadID, filePath, quotedMessageID)
	if err != nil {
		return nil, err
	}
	return decodeSendResult(raw)
}

func (c *Client) CreateChat(recipients []string, messageText, title string) (*Thread, bool, error) {
	recipientsJSON, err := json.Marshal(recipients)
	if err != nil {
		return nil, false, err
	}
	raw, err := lib.CreateChat(string(recipientsJSON), messageText, title)
	if err != nil {
		return nil, false, err
	}
	if len(raw) == 0 || string(raw) == "true" {
		return nil, true, nil
	}
	if string(raw) == "false" || string(raw) == "null" {
		return nil, false, nil
	}
	thread, err := decode[Thread](raw)
	if err != nil {
		return nil, false, fmt.Errorf("failed to decode create chat response: %w", err)
	}
	return &thread, true, nil
}

func (c *Client) Edit(threadID, messageID, text string) error {
	_, err := lib.Edit(threadID, messageID, text)
	return err
}

func (c *Client) DeleteMessage(threadID, messageID string) error {
	_, err := lib.DeleteMessage(threadID, messageID)
	return err
}

func (c *Client) React(threadID, messageID, reactionKey string, enabled bool) error {
	_, err := lib.React(threadID, messageID, reactionKey, enabled)
	return err
}

func (c *Client) MarkRead(threadID string) error {
	_, err := lib.MarkRead(threadID)
	return err
}

func (c *Client) MarkUnread(threadID string) error {
	_, err := lib.MarkUnread(threadID)
	return err
}

func (c *Client) Mute(threadID string, muted bool) error {
	_, err := lib.Mute(threadID, muted)
	return err
}

func (c *Client) DeleteChat(threadID string) error {
	_, err := lib.DeleteChat(threadID)
	return err
}

func (c *Client) NotifyAnyway(threadID string) error {
	_, err := lib.NotifyAnyway(threadID)
	return err
}

func (c *Client) ActivityStatus(threadID string) (*ActivityStatus, error) {
	raw, err := lib.ActivityStatus(threadID)
	if err != nil {
		return nil, err
	}
	status, err := decode[ActivityStatus](raw)
	if err != nil {
		return nil, fmt.Errorf("failed to decode activity status: %w", err)
	}
	return &status, nil
}

func (c *Client) Typing(threadID string, enabled bool) error {
	_, err := lib.Typing(threadID, enabled)
	return err
}

func (c *Client) WatchChat(threadID string) error {
	_, err := lib.WatchChat(threadID)
	return err
}

func (c *Client) SearchMessages(query, threadID string, pagination *Pagination, limit int) (*Page[Message], error) {
	paginationJSON, err := pagination.JSON()
	if err != nil {
		return nil, err
	}
	raw, err := lib.SearchMessages(query, threadID, paginationJSON, limit)
	if err != nil {
		return nil, err
	}
	page, err := decode[Page[Message]](raw)
	if err != nil {
		return nil, fmt.Errorf("failed to decode message search: %w", err)
	}
	return &page, nil
}

func (c *Client) GetAsset(pathHex, methodName string) (*Asset, error) {
	raw, err := lib.GetAsset(pathHex, methodName)
	if err != nil {
		return nil, err
	}
	asset, err := decode[Asset](raw)
	if err != nil {
		return nil, fmt.Errorf("failed to decode asset: %w", err)
	}
	return &asset, nil
}

func (c *Client) LoadAttachment(messageID string) error {
	_, err := lib.LoadAttachment(messageID)
	return err
}

func (c *Client) StartEvents() error {
	_, err := lib.StartEvents()
	return err
}

func (c *Client) NextEvents(timeoutMilliseconds int) ([]StateSyncEvent, error) {
	raw, err := lib.NextEvents(timeoutMilliseconds)
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	var events []StateSyncEvent
	if err := json.Unmarshal(raw, &events); err != nil {
		return nil, fmt.Errorf("failed to decode events: %w", err)
	}
	return events, nil
}

func decodeSendResult(raw json.RawMessage) ([]Message, error) {
	if len(raw) == 0 || string(raw) == "true" || string(raw) == "null" {
		return nil, nil
	}
	if string(raw) == "false" {
		return nil, fmt.Errorf("swift send returned false")
	}
	messages, err := decode[[]Message](raw)
	if err != nil {
		return nil, fmt.Errorf("failed to decode send response: %w", err)
	}
	return messages, nil
}
