package connector

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/beeper/platform-imessage/pkg/imessage"
	"github.com/beeper/platform-imessage/pkg/imessageid"
	"github.com/rs/zerolog"
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
	log := zerolog.Ctx(ctx).With().
		Str("imessage_portal_id", string(msg.Portal.ID)).
		Str("imessage_msgtype", string(msg.Content.MsgType)).
		Logger()

	if err := c.ensureAccessibilityForSending(); err != nil {
		return nil, err
	}
	log.Debug().Msg("iMessage outgoing permission preflight passed")

	quotedMessageID := ""
	if msg.ReplyTo != nil {
		quotedMessageID = platformMessageID(msg.ReplyTo)
	}

	if msg.Content.MsgType.IsText() {
		if shouldCreateChatForOutgoingText(string(msg.Portal.ID), quotedMessageID) {
			log.Debug().
				Strs("imessage_recipients", recipientsFromThreadID(string(msg.Portal.ID))).
				Msg("Starting synthetic iMessage chat from outgoing text")
			sent, err = c.createChatFromSyntheticPortal(ctx, string(msg.Portal.ID), msg.Content.Body, msg.Portal.Name)
		} else {
			log.Debug().Str("quoted_message_id", quotedMessageID).Msg("Sending iMessage text")
			sent, err = c.IM.SendText(string(msg.Portal.ID), msg.Content.Body, quotedMessageID)
		}
	} else if msg.Content.MsgType.IsMedia() {
		if quotedMessageID == "" && len(recipientsFromThreadID(string(msg.Portal.ID))) > 0 {
			return nil, matrixUnsupported("new iMessage chats must be started with a text message before sending attachments")
		}
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
		return nil, c.decorateAutomationError(err)
	}
	log.Debug().Int("sent_count", len(sent)).Msg("iMessage outgoing send returned")

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
				ThreadID: responseThreadID(string(msg.Portal.ID), *first),
			},
		},
	}, nil
}

func (c *Client) ensureAccessibilityForSending() error {
	if c.Main.Config.ShouldSkipPermissionValidation() {
		return nil
	}

	authStatus, err := c.IM.AuthorizationStatus()
	if err != nil {
		return err
	}
	for _, permission := range authStatus.Permissions {
		if permission.ID != "accessibility" || permission.Authorized {
			continue
		}
		if _, requestErr := c.IM.RequestAuthorization("accessibility"); requestErr != nil {
			return requestErr
		}
		return errors.New("Accessibility permission is required to send iMessages. Enable this bridge in System Settings > Privacy & Security > Accessibility, then retry sending")
	}
	return nil
}

func shouldCreateChatForOutgoingText(portalID, quotedMessageID string) bool {
	return quotedMessageID == "" && len(recipientsFromThreadID(portalID)) > 0
}

func (c *Client) createChatFromSyntheticPortal(ctx context.Context, threadID, text, title string) ([]imessage.Message, error) {
	recipients := recipientsFromThreadID(threadID)
	if len(recipients) == 0 {
		return nil, errors.New("portal ID does not contain synthetic iMessage recipients")
	}
	thread, _, err := c.IM.CreateChat(recipients, text, title)
	if err != nil {
		return nil, err
	}
	zerolog.Ctx(ctx).Debug().
		Strs("imessage_recipients", recipients).
		Bool("has_thread", thread != nil).
		Msg("iMessage CreateChat returned")
	if thread != nil && sentPartialLastMessageMatches(thread.PartialLastMessage, text) {
		if thread.ID != "" && thread.ID != threadID {
			c.reIDPortal(ctx, threadID, thread.ID)
		}
		thread.PartialLastMessage.ThreadID = thread.ID
		return []imessage.Message{*thread.PartialLastMessage}, nil
	}
	return c.findRecentlyCreatedMessage(threadID, text)
}

func sentPartialLastMessageMatches(message *imessage.Message, text string) bool {
	if message == nil || message.Text != text {
		return false
	}
	return message.IsSender == nil || *message.IsSender
}

func responseThreadID(portalID string, msg imessage.Message) string {
	if msg.ThreadID != "" {
		return msg.ThreadID
	}
	return portalID
}

func (c *Client) findRecentlyCreatedMessage(oldThreadID, text string) ([]imessage.Message, error) {
	startedAt := time.Now().Add(-5 * time.Second)
	expectedParticipants := canonicalParticipantSet(recipientsFromThreadID(oldThreadID))
	selfIdentifiers := c.currentUserIdentifiers()
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
			if len(expectedParticipants) > 0 {
				thread, err := c.IM.Chat(msg.ThreadID)
				if err != nil || thread == nil || !participantSetMatchesThread(expectedParticipants, *thread, selfIdentifiers) {
					continue
				}
			}
			c.reIDPortal(context.Background(), oldThreadID, msg.ThreadID)
			return []imessage.Message{msg}, nil
		}
		time.Sleep(250 * time.Millisecond)
	}
	return nil, errors.New("created iMessage chat, but could not find the sent message")
}

func recipientsFromThreadID(threadID string) []string {
	if !strings.HasPrefix(threadID, "any;-;") && !strings.HasPrefix(threadID, "group;-;") {
		return nil
	}
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
	return c.IM.Edit(string(msg.Portal.ID), platformMessageID(msg.EditTarget), msg.Content.Body)
}

func (c *Client) PreHandleMatrixReaction(ctx context.Context, msg *bridgev2.MatrixReaction) (bridgev2.MatrixReactionPreResponse, error) {
	emoji := matrixReactionKey(msg)
	platformKey, ok := platformReactionKeyFromBridge(emoji)
	if !ok {
		return bridgev2.MatrixReactionPreResponse{}, unsupportedIMessageReaction(emoji)
	}
	emojiID := c.makeOwnReactionID(platformKey)
	return bridgev2.MatrixReactionPreResponse{
		SenderID:     c.GetUserID(),
		EmojiID:      emojiID,
		Emoji:        emoji,
		MaxReactions: 1,
	}, nil
}

func (c *Client) HandleMatrixReaction(ctx context.Context, msg *bridgev2.MatrixReaction) (*database.Reaction, error) {
	emoji := matrixReactionKey(msg)
	platformKey, ok := platformReactionKeyFromBridge(emoji)
	if !ok {
		return nil, unsupportedIMessageReaction(emoji)
	}
	emojiID := c.makeOwnReactionID(platformKey)
	if err := c.removeSupersededIMessageReactions(ctx, msg, emojiID); err != nil {
		return nil, err
	}
	err := c.IM.React(string(msg.Portal.ID), platformMessageID(msg.TargetMessage), platformKey, true)
	if err != nil {
		return nil, err
	}
	return &database.Reaction{
		SenderID:  c.GetUserID(),
		EmojiID:   emojiID,
		Emoji:     emoji,
		Timestamp: time.Now(),
		Metadata: &imessageid.ReactionMetadata{
			ReactionID:  string(emojiID),
			ReactionKey: platformKey,
		},
	}, nil
}

func matrixReactionKey(msg *bridgev2.MatrixReaction) string {
	if msg == nil {
		return ""
	}
	if msg.Content != nil {
		if key := strings.TrimSpace(msg.Content.RelatesTo.Key); key != "" {
			return normalizeBridgeReactionKey(key)
		}
	}
	if msg.Event == nil {
		return ""
	}
	var raw struct {
		RelatesTo struct {
			Key string `json:"key"`
		} `json:"m.relates_to"`
	}
	if len(msg.Event.Content.VeryRaw) > 0 && json.Unmarshal(msg.Event.Content.VeryRaw, &raw) == nil {
		if key := strings.TrimSpace(raw.RelatesTo.Key); key != "" {
			return normalizeBridgeReactionKey(key)
		}
	}
	if relatesTo, ok := msg.Event.Content.Raw["m.relates_to"].(map[string]any); ok {
		if key, ok := relatesTo["key"].(string); ok {
			return normalizeBridgeReactionKey(key)
		}
	}
	return ""
}

func unsupportedIMessageReaction(reactionKey string) error {
	return matrixUnsupported(fmt.Sprintf("unsupported iMessage reaction %q (%x)", reactionKey, []byte(reactionKey)))
}

func (c *Client) removeSupersededIMessageReactions(ctx context.Context, msg *bridgev2.MatrixReaction, newEmojiID networkid.EmojiID) error {
	if c.Main == nil || c.Main.Bridge == nil || c.Main.Bridge.DB == nil || c.Main.Bridge.DB.Reaction == nil || msg == nil || msg.TargetMessage == nil {
		return nil
	}
	oldReactions, err := c.Main.Bridge.DB.Reaction.GetAllToMessageBySender(ctx, receiver(c.UserLogin), msg.TargetMessage.ID, c.GetUserID())
	if err != nil {
		return err
	}
	for _, oldReaction := range oldReactions {
		if !shouldRemoveSupersededReaction(oldReaction, msg.ExistingReactionsToKeep, newEmojiID) {
			continue
		}
		reactionKey := reactionKeyFromDBReaction(oldReaction)
		if reactionKey == "" {
			continue
		}
		if err := c.IM.React(string(msg.Portal.ID), platformReactionMessageID(oldReaction), reactionKey, false); err != nil {
			return err
		}
	}
	return nil
}

func shouldRemoveSupersededReaction(reaction *database.Reaction, keep []*database.Reaction, newEmojiID networkid.EmojiID) bool {
	if reaction == nil || reaction.EmojiID == newEmojiID {
		return false
	}
	for _, kept := range keep {
		if kept == nil {
			continue
		}
		if kept.MessageID == reaction.MessageID &&
			kept.MessagePartID == reaction.MessagePartID &&
			kept.SenderID == reaction.SenderID &&
			kept.EmojiID == reaction.EmojiID {
			return false
		}
	}
	return true
}

func (c *Client) HandleMatrixReactionRemove(ctx context.Context, msg *bridgev2.MatrixReactionRemove) error {
	return c.IM.React(
		string(msg.Portal.ID),
		platformReactionMessageID(msg.TargetReaction),
		reactionKeyFromDBReaction(msg.TargetReaction),
		false,
	)
}

func (c *Client) HandleMatrixMessageRemove(ctx context.Context, msg *bridgev2.MatrixMessageRemove) error {
	return c.IM.DeleteMessage(string(msg.Portal.ID), platformMessageID(msg.TargetMessage))
}

func (c *Client) HandleMatrixReadReceipt(ctx context.Context, msg *bridgev2.MatrixReadReceipt) error {
	if msg.Portal == nil {
		return nil
	}
	err := c.IM.MarkRead(string(msg.Portal.ID))
	if shouldIgnoreBestEffortAutomationError(err) {
		zerolog.Ctx(ctx).Warn().Err(err).Str("imessage_portal_id", string(msg.Portal.ID)).Msg("Ignoring best-effort iMessage read receipt failure")
		return nil
	}
	return err
}

func (c *Client) HandleMatrixViewingChat(ctx context.Context, msg *bridgev2.MatrixViewingChat) error {
	if msg.Portal == nil {
		return nil
	}
	if err := c.IM.MarkRead(string(msg.Portal.ID)); err != nil {
		if shouldIgnoreBestEffortAutomationError(err) {
			zerolog.Ctx(ctx).Warn().Err(err).Str("imessage_portal_id", string(msg.Portal.ID)).Msg("Ignoring best-effort iMessage viewing-chat read failure")
			return c.IM.WatchChat(string(msg.Portal.ID))
		}
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

func shouldIgnoreBestEffortAutomationError(err error) bool {
	if err == nil {
		return false
	}
	errText := err.Error()
	return strings.Contains(errText, "Could not get main Messages window") ||
		strings.Contains(errText, "Initialized MessagesController in an invalid state")
}

func (c *Client) decorateAutomationError(err error) error {
	if err == nil || !shouldIgnoreBestEffortAutomationError(err) {
		return err
	}
	authStatus, statusErr := c.IM.AuthorizationStatus()
	if statusErr != nil || authStatus == nil || authStatus.Automation.Message == "" {
		return err
	}
	if state := bridgeStateForAutomationStatus(authStatus.Automation); state != nil {
		c.UserLogin.BridgeState.Send(*state)
	}
	return fmt.Errorf("%s: %w", authStatus.Automation.Message, err)
}

func (c *Client) makeOwnReactionID(reactionKey string) networkid.EmojiID {
	return networkid.EmojiID(string(c.GetUserID()) + reactionKey)
}

func reactionKeyFromDBReaction(reaction *database.Reaction) string {
	if reaction == nil {
		return ""
	}
	if meta, ok := reaction.Metadata.(*imessageid.ReactionMetadata); ok && meta.ReactionKey != "" {
		return meta.ReactionKey
	}
	if reaction.Emoji != "" {
		if platformKey, ok := platformReactionKeyFromBridge(reaction.Emoji); ok {
			return platformKey
		}
		return reaction.Emoji
	}
	_, reactionKey := splitStandardIMessageReactionID(string(reaction.EmojiID))
	return reactionKey
}

func platformMessageID(message *database.Message) string {
	if message == nil {
		return ""
	}
	return platformMessageIDParts(message.ID, message.PartID)
}

func platformReactionMessageID(reaction *database.Reaction) string {
	if reaction == nil {
		return ""
	}
	return platformMessageIDParts(reaction.MessageID, reaction.MessagePartID)
}

func platformMessageIDParts(messageID networkid.MessageID, partID networkid.PartID) string {
	if messageID == "" {
		return ""
	}
	if platformMessageIDHasPart(string(messageID)) {
		return string(messageID)
	}
	if partID == "" {
		return string(messageID)
	}
	return string(messageID) + "_" + string(partID)
}

func platformMessageIDHasPart(messageID string) bool {
	_, part, ok := strings.Cut(messageID, "_")
	if !ok || part == "" {
		return false
	}
	for _, char := range part {
		if char < '0' || char > '9' {
			return false
		}
	}
	return true
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
