package connector

import (
	"context"
	"encoding/json"
	"sort"
	"strings"

	"github.com/beeper/platform-imessage/pkg/imessage"
	"github.com/beeper/platform-imessage/pkg/imessageid"
	"github.com/rs/zerolog"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/bridgev2/simplevent"
	"maunium.net/go/mautrix/event"
)

func (c *Client) handleMessageStateSync(evt imessage.StateSyncEvent) error {
	switch evt.MutationType {
	case "upsert":
		var messages []imessage.Message
		if err := json.Unmarshal(evt.Entries, &messages); err != nil {
			return err
		}
		for _, message := range messages {
			if message.ThreadID == "" {
				message.ThreadID = evt.ObjectIDs.ThreadID
			}
			message := message
			c.UserLogin.QueueRemoteEvent(&simplevent.Message[imessage.Message]{
				EventMeta: c.eventMeta(message.ThreadID, message),
				ID:        imessageid.MakeMessageID(message.ID),
				Data:      message,
				ConvertMessageFunc: func(ctx context.Context, portal *bridgev2.Portal, intent bridgev2.MatrixAPI, data imessage.Message) (*bridgev2.ConvertedMessage, error) {
					return c.convertMessageFromIMessage(ctx, portal, intent, data)
				},
				HandleExistingFunc: func(ctx context.Context, portal *bridgev2.Portal, intent bridgev2.MatrixAPI, existing []*database.Message, data imessage.Message) (bridgev2.UpsertResult, error) {
					return bridgev2.UpsertResult{}, nil
				},
			})
		}
	case "update":
		var messages []imessage.Message
		if err := json.Unmarshal(evt.Entries, &messages); err != nil {
			return err
		}
		for _, message := range messages {
			if message.ThreadID == "" {
				message.ThreadID = evt.ObjectIDs.ThreadID
			}
			c.UserLogin.QueueRemoteEvent(&simplevent.Message[imessage.Message]{
				EventMeta:     c.eventMeta(message.ThreadID, message).WithType(bridgev2.RemoteEventEdit),
				ID:            imessageid.MakeMessageID(message.ID),
				TargetMessage: imessageid.MakeMessageID(message.ID),
				Data:          message,
				ConvertEditFunc: func(ctx context.Context, portal *bridgev2.Portal, intent bridgev2.MatrixAPI, existing []*database.Message, data imessage.Message) (*bridgev2.ConvertedEdit, error) {
					if len(existing) == 0 {
						return nil, bridgev2.ErrIgnoringRemoteEvent
					}
					return &bridgev2.ConvertedEdit{
						ModifiedParts: []*bridgev2.ConvertedEditPart{{
							Part:    existing[0],
							Type:    event.EventMessage,
							Content: messageTextContentFromIMessage(data),
						}},
					}, nil
				},
			})
		}
	case "delete":
		var ids []string
		if err := json.Unmarshal(evt.Entries, &ids); err != nil {
			return err
		}
		threadID := evt.ObjectIDs.ThreadID
		for _, id := range ids {
			c.UserLogin.QueueRemoteEvent(&simplevent.MessageRemove{
				EventMeta:     c.eventMeta(threadID, imessage.Message{ID: id, ThreadID: threadID}),
				TargetMessage: imessageid.MakeMessageID(id),
			})
		}
	}
	return nil
}

func (c *Client) handleReactionStateSync(evt imessage.StateSyncEvent) error {
	targetMessageID := imessageid.MakeMessageID(evt.ObjectIDs.MessageID)
	switch evt.MutationType {
	case "upsert":
		var reactions []imessage.Reaction
		if err := json.Unmarshal(evt.Entries, &reactions); err != nil {
			return err
		}
		for _, reaction := range reactions {
			c.UserLogin.QueueRemoteEvent(&simplevent.Reaction{
				EventMeta:     c.eventMeta(evt.ObjectIDs.ThreadID, imessage.Message{ThreadID: evt.ObjectIDs.ThreadID, SenderID: reaction.ParticipantID}),
				TargetMessage: targetMessageID,
				EmojiID:       networkid.EmojiID(reaction.ID),
				Emoji:         reaction.ReactionKey,
			})
		}
	case "delete":
		var ids []string
		if err := json.Unmarshal(evt.Entries, &ids); err != nil {
			return err
		}
		for _, id := range ids {
			c.UserLogin.QueueRemoteEvent(&simplevent.Reaction{
				EventMeta:     c.eventMeta(evt.ObjectIDs.ThreadID, imessage.Message{ThreadID: evt.ObjectIDs.ThreadID}),
				TargetMessage: targetMessageID,
				EmojiID:       networkid.EmojiID(id),
			})
		}
	}
	return nil
}

func (c *Client) handleThreadStateSync(evt imessage.StateSyncEvent) error {
	if evt.MutationType == "delete" {
		var ids []string
		if err := json.Unmarshal(evt.Entries, &ids); err != nil {
			return err
		}
		for _, threadID := range ids {
			c.UserLogin.QueueRemoteEvent(&simplevent.ChatDelete{
				EventMeta: c.baseEventMeta(threadID).WithType(bridgev2.RemoteEventChatDelete),
				OnlyForMe: true,
			})
		}
		return nil
	}

	var threads []imessage.Thread
	if err := json.Unmarshal(evt.Entries, &threads); err != nil {
		return err
	}
	for _, thread := range threads {
		thread := thread
		c.reIDKnownSyntheticPortals(context.Background(), thread)
		c.UserLogin.QueueRemoteEvent(&simplevent.ChatResync{
			EventMeta: c.baseEventMeta(thread.ID).WithType(bridgev2.RemoteEventChatResync),
			ChatInfo:  c.chatInfoFromThread(thread),
		})
	}
	return nil
}

func (c *Client) reIDKnownSyntheticPortals(ctx context.Context, thread imessage.Thread) {
	for _, sourceID := range syntheticPortalIDsForThread(thread) {
		c.reIDPortal(ctx, sourceID, thread.ID)
	}
}

func (c *Client) reIDPortal(ctx context.Context, sourceID, targetID string) {
	if sourceID == "" || targetID == "" || sourceID == targetID {
		return
	}
	_, _, err := c.Main.Bridge.ReIDPortal(ctx, portalKey(sourceID, c.UserLogin.ID), portalKey(targetID, c.UserLogin.ID))
	if err != nil {
		c.UserLogin.Log.Warn().
			Err(err).
			Str("source_thread_id", sourceID).
			Str("target_thread_id", targetID).
			Msg("Failed to re-ID provisional iMessage portal")
	}
}

func syntheticPortalIDsForThread(thread imessage.Thread) []string {
	participants := make([]string, 0, len(thread.Participants.Items))
	for _, participant := range thread.Participants.Items {
		if participant.ID != "" {
			participants = append(participants, participant.ID)
		}
	}
	if len(participants) == 0 {
		return nil
	}
	sort.Strings(participants)
	joined := strings.Join(participants, ",")
	if len(participants) == 1 {
		return []string{
			"any;-;" + joined,
			"iMessage;-;" + joined,
			"SMS;-;" + joined,
		}
	}
	return []string{"group;-;" + joined}
}

func (c *Client) eventMeta(threadID string, message imessage.Message) simplevent.EventMeta {
	meta := c.baseEventMeta(threadID)
	meta.Type = bridgev2.RemoteEventMessage
	meta.Timestamp = messageTimestamp(message)
	meta.Sender = c.sender(message)
	meta.LogContext = func(zctx zerolog.Context) zerolog.Context {
		return zctx.Str("thread_id", threadID).Str("message_id", message.ID)
	}
	return meta
}

func (c *Client) baseEventMeta(threadID string) simplevent.EventMeta {
	return simplevent.EventMeta{
		PortalKey:    portalKey(threadID, c.UserLogin.ID),
		CreatePortal: true,
		Sender: bridgev2.EventSender{
			IsFromMe:    true,
			SenderLogin: c.UserLogin.ID,
			Sender:      c.GetUserID(),
		},
		LogContext: func(zctx zerolog.Context) zerolog.Context {
			return zctx.Str("thread_id", threadID)
		},
	}
}

func (c *Client) sender(message imessage.Message) bridgev2.EventSender {
	if message.IsSender != nil && *message.IsSender {
		return bridgev2.EventSender{
			IsFromMe:    true,
			SenderLogin: c.UserLogin.ID,
			Sender:      c.GetUserID(),
		}
	}
	if message.SenderID != "" {
		return bridgev2.EventSender{Sender: imessageid.MakeUserID(message.SenderID)}
	}
	return bridgev2.EventSender{
		IsFromMe:    true,
		SenderLogin: c.UserLogin.ID,
		Sender:      c.GetUserID(),
	}
}

func replyTarget(message imessage.Message) *networkid.MessageOptionalPartID {
	if message.LinkedMessageID == "" {
		return nil
	}
	return &networkid.MessageOptionalPartID{
		MessageID: imessageid.MakeMessageID(message.LinkedMessageID),
	}
}
