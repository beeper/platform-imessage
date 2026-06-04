package connector

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/beeper/platform-imessage/pkg/imessage"
	"github.com/beeper/platform-imessage/pkg/imessageid"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/event"
)

var (
	_ bridgev2.EditHandlingNetworkAPI         = (*Client)(nil)
	_ bridgev2.ReactionHandlingNetworkAPI     = (*Client)(nil)
	_ bridgev2.RedactionHandlingNetworkAPI    = (*Client)(nil)
	_ bridgev2.ReadReceiptHandlingNetworkAPI  = (*Client)(nil)
	_ bridgev2.ChatViewingNetworkAPI          = (*Client)(nil)
	_ bridgev2.TypingHandlingNetworkAPI       = (*Client)(nil)
	_ bridgev2.MarkedUnreadHandlingNetworkAPI = (*Client)(nil)
	_ bridgev2.MuteHandlingNetworkAPI         = (*Client)(nil)
	_ bridgev2.DeleteChatHandlingNetworkAPI   = (*Client)(nil)
)

func (c *Client) HandleMatrixMessage(ctx context.Context, msg *bridgev2.MatrixMessage) (*bridgev2.MatrixMessageResponse, error) {
	var (
		sent []imessage.Message
		err  error
	)

	quotedMessageID := ""
	if msg.ReplyTo != nil {
		quotedMessageID = string(msg.ReplyTo.ID)
	}

	if msg.Content.MsgType.IsText() {
		sent, err = c.IM.SendText(string(msg.Portal.ID), msg.Content.Body, quotedMessageID)
		if err != nil && quotedMessageID == "" {
			sent, err = c.createChatFromSyntheticPortal(string(msg.Portal.ID), msg.Content.Body, msg.Portal.Name)
		}
	} else if msg.Content.MsgType.IsMedia() {
		var tempPath string
		tempPath, err = c.downloadMatrixMedia(ctx, msg)
		if err == nil {
			defer os.Remove(tempPath)
			sent, err = c.IM.SendFile(string(msg.Portal.ID), tempPath, quotedMessageID)
		}
	} else {
		return nil, matrixUnsupported("unsupported iMessage Matrix message type")
	}
	if err != nil {
		return nil, err
	}

	first, err := firstSentMessage(sent)
	if err != nil {
		return nil, err
	}

	return &bridgev2.MatrixMessageResponse{
		DB: &database.Message{
			ID:        imessageid.MakeMessageID(first.ID),
			SenderID:  c.GetUserID(),
			Timestamp: messageTimestamp(*first),
			Metadata: &imessageid.MessageMetadata{
				ThreadID: string(msg.Portal.ID),
			},
		},
	}, nil
}

func (c *Client) createChatFromSyntheticPortal(threadID, text, title string) ([]imessage.Message, error) {
	recipients := recipientsFromThreadID(threadID)
	if len(recipients) == 0 {
		return nil, errors.New("portal ID does not contain synthetic iMessage recipients")
	}
	thread, _, err := c.IM.CreateChat(recipients, text, title)
	if err != nil {
		return nil, err
	}
	if thread != nil && thread.PartialLastMessage != nil {
		thread.PartialLastMessage.ThreadID = thread.ID
		return []imessage.Message{*thread.PartialLastMessage}, nil
	}
	return c.findRecentlyCreatedMessage(threadID, text)
}

func (c *Client) findRecentlyCreatedMessage(oldThreadID, text string) ([]imessage.Message, error) {
	startedAt := time.Now().Add(-5 * time.Second)
	for attempt := 0; attempt < 20; attempt++ {
		page, err := c.IM.SearchMessages(text, "", nil, 20)
		if err != nil {
			return nil, err
		}
		for _, msg := range page.Items {
			if msg.Text != text || msg.ThreadID == "" || messageTimestamp(msg).Before(startedAt) {
				continue
			}
			if msg.IsSender != nil && !*msg.IsSender {
				continue
			}
			c.reIDPortal(context.Background(), oldThreadID, msg.ThreadID)
			return []imessage.Message{msg}, nil
		}
		time.Sleep(250 * time.Millisecond)
	}
	return nil, errors.New("created iMessage chat, but could not find the sent message")
}

func recipientsFromThreadID(threadID string) []string {
	parts := strings.Split(threadID, ";-;")
	if len(parts) < 2 {
		return nil
	}
	raw := parts[len(parts)-1]
	var recipients []string
	for _, participant := range strings.Split(raw, ",") {
		participant = strings.TrimSpace(participant)
		if participant != "" {
			recipients = append(recipients, participant)
		}
	}
	return recipients
}

func (c *Client) downloadMatrixMedia(ctx context.Context, msg *bridgev2.MatrixMessage) (string, error) {
	data, err := c.Main.Bridge.Bot.DownloadMedia(ctx, msg.Content.URL, msg.Content.File)
	if err != nil {
		return "", err
	}

	ext := filepath.Ext(msg.Content.FileName)
	file, err := os.CreateTemp("", "mautrix-imessage-*"+ext)
	if err != nil {
		return "", err
	}
	path := file.Name()
	if _, err = file.Write(data); err != nil {
		file.Close()
		os.Remove(path)
		return "", err
	}
	if err = file.Close(); err != nil {
		os.Remove(path)
		return "", err
	}
	return path, nil
}

func (c *Client) HandleMatrixEdit(ctx context.Context, msg *bridgev2.MatrixEdit) error {
	return c.IM.Edit(string(msg.Portal.ID), string(msg.EditTarget.ID), msg.Content.Body)
}

func (c *Client) PreHandleMatrixReaction(ctx context.Context, msg *bridgev2.MatrixReaction) (bridgev2.MatrixReactionPreResponse, error) {
	emoji := msg.Content.RelatesTo.Key
	emojiID := c.makeOwnReactionID(emoji)
	return bridgev2.MatrixReactionPreResponse{
		SenderID:     c.GetUserID(),
		EmojiID:      emojiID,
		Emoji:        emoji,
		MaxReactions: 1,
	}, nil
}

func (c *Client) HandleMatrixReaction(ctx context.Context, msg *bridgev2.MatrixReaction) (*database.Reaction, error) {
	emoji := msg.Content.RelatesTo.Key
	err := c.IM.React(string(msg.Portal.ID), string(msg.TargetMessage.ID), emoji, true)
	if err != nil {
		return nil, err
	}
	return &database.Reaction{
		SenderID:  c.GetUserID(),
		EmojiID:   c.makeOwnReactionID(emoji),
		Emoji:     emoji,
		Timestamp: time.Now(),
		Metadata: &imessageid.ReactionMetadata{
			ReactionID:  string(c.makeOwnReactionID(emoji)),
			ReactionKey: emoji,
		},
	}, nil
}

func (c *Client) HandleMatrixReactionRemove(ctx context.Context, msg *bridgev2.MatrixReactionRemove) error {
	return c.IM.React(
		string(msg.Portal.ID),
		string(msg.TargetReaction.MessageID),
		msg.TargetReaction.Emoji,
		false,
	)
}

func (c *Client) HandleMatrixMessageRemove(ctx context.Context, msg *bridgev2.MatrixMessageRemove) error {
	return c.IM.DeleteMessage(string(msg.Portal.ID), string(msg.TargetMessage.ID))
}

func (c *Client) HandleMatrixReadReceipt(ctx context.Context, msg *bridgev2.MatrixReadReceipt) error {
	return c.IM.MarkRead(string(msg.Portal.ID))
}

func (c *Client) HandleMatrixViewingChat(ctx context.Context, msg *bridgev2.MatrixViewingChat) error {
	if msg.Portal == nil {
		return nil
	}
	if err := c.IM.MarkRead(string(msg.Portal.ID)); err != nil {
		return err
	}
	return c.IM.WatchChat(string(msg.Portal.ID))
}

func (c *Client) HandleMatrixTyping(ctx context.Context, msg *bridgev2.MatrixTyping) error {
	return c.IM.Typing(string(msg.Portal.ID), msg.IsTyping)
}

func (c *Client) HandleMarkedUnread(ctx context.Context, msg *bridgev2.MatrixMarkedUnread) error {
	if msg.Content.Unread {
		return c.IM.MarkUnread(string(msg.Portal.ID))
	}
	return c.IM.MarkRead(string(msg.Portal.ID))
}

func (c *Client) HandleMute(ctx context.Context, msg *bridgev2.MatrixMute) error {
	return c.IM.Mute(string(msg.Portal.ID), msg.Content.IsMuted())
}

func (c *Client) HandleMatrixDeleteChat(ctx context.Context, msg *bridgev2.MatrixDeleteChat) error {
	if msg.Content.DeleteForEveryone {
		return matrixUnsupported("iMessage cannot delete chats for everyone")
	}
	return c.IM.DeleteChat(string(msg.Portal.ID))
}

func (c *Client) makeOwnReactionID(reactionKey string) networkid.EmojiID {
	return networkid.EmojiID(string(c.GetUserID()) + reactionKey)
}

func messageTextContentFromIMessage(msg imessage.Message) *event.MessageEventContent {
	body := msg.Text
	if body == "" && len(msg.Attachments) > 0 {
		body = msg.Attachments[0].FileName
	}
	if body == "" {
		body = "Unsupported iMessage event"
	}
	return &event.MessageEventContent{
		MsgType: event.MsgText,
		Body:    body,
	}
}

func (c *Client) messageTextContentFromIMessage(ctx context.Context, msg imessage.Message) *event.MessageEventContent {
	content := messageTextContentFromIMessage(msg)
	content.Mentions = c.mentionsFromIMessage(ctx, msg)
	content.BeeperLinkPreviews = linkPreviewsFromIMessage(msg)
	return content
}

func linkPreviewsFromIMessage(msg imessage.Message) []*event.BeeperLinkPreview {
	if len(msg.Links) == 0 {
		return nil
	}
	previews := make([]*event.BeeperLinkPreview, 0, len(msg.Links))
	for _, link := range msg.Links {
		if link.URL == "" && link.OriginalURL == "" {
			continue
		}
		matched := link.OriginalURL
		if matched == "" {
			matched = link.URL
		}
		previews = append(previews, &event.BeeperLinkPreview{
			MatchedURL: matched,
			LinkPreview: event.LinkPreview{
				CanonicalURL: link.URL,
				Title:        link.Title,
				Description:  link.Summary,
			},
		})
	}
	return previews
}
