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
			c.queueMessageActionChange(context.Background(), message)
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
					converted, err := c.convertMessageFromIMessage(ctx, portal, intent, data)
					if err != nil {
						return nil, err
					}
					return editFromUpdatedMessage(existing, converted)
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

func editFromUpdatedMessage(existing []*database.Message, converted *bridgev2.ConvertedMessage) (*bridgev2.ConvertedEdit, error) {
	if len(existing) == 0 || converted == nil || len(converted.Parts) == 0 {
		return nil, bridgev2.ErrIgnoringRemoteEvent
	}
	edit := &bridgev2.ConvertedEdit{}
	modifiedCount := len(converted.Parts)
	if len(existing) < modifiedCount {
		modifiedCount = len(existing)
	}
	for i := 0; i < modifiedCount; i++ {
		editPart := converted.Parts[i].ToEditPart(existing[i])
		if editPart != nil {
			edit.ModifiedParts = append(edit.ModifiedParts, editPart)
		}
	}
	if len(converted.Parts) > len(existing) {
		edit.AddedParts = &bridgev2.ConvertedMessage{
			ReplyTo:    converted.ReplyTo,
			Disappear:  converted.Disappear,
			ThreadRoot: converted.ThreadRoot,
			Parts:      converted.Parts[len(existing):],
		}
	}
	if len(existing) > len(converted.Parts) {
		edit.DeletedParts = existing[len(converted.Parts):]
	}
	return edit, nil
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
				ReactionDBMeta: &imessageid.ReactionMetadata{
					ReactionID:  reaction.ID,
					ReactionKey: reaction.ReactionKey,
				},
			})
		}
	case "delete":
		var ids []string
		if err := json.Unmarshal(evt.Entries, &ids); err != nil {
			return err
		}
		for _, id := range ids {
			reactionID := string(id)
			senderID, reactionKey := c.reactionSenderAndKey(context.Background(), targetMessageID, reactionID)
			c.UserLogin.QueueRemoteEvent(&simplevent.Reaction{
				EventMeta:     c.eventMeta(evt.ObjectIDs.ThreadID, imessage.Message{ThreadID: evt.ObjectIDs.ThreadID, SenderID: string(senderID)}),
				TargetMessage: targetMessageID,
				EmojiID:       networkid.EmojiID(id),
				Emoji:         reactionKey,
				ReactionDBMeta: &imessageid.ReactionMetadata{
					ReactionID:  reactionID,
					ReactionKey: reactionKey,
				},
			})
		}
	}
	return nil
}

var standardIMessageReactionKeys = []string{
	"emphasize",
	"question",
	"dislike",
	"sticker",
	"heart",
	"laugh",
	"like",
}

func backfillReactionFromIMessage(reaction imessage.Reaction) *bridgev2.BackfillReaction {
	return &bridgev2.BackfillReaction{
		Sender:     bridgev2.EventSender{Sender: imessageid.MakeUserID(reaction.ParticipantID)},
		EmojiID:    networkid.EmojiID(reaction.ID),
		Emoji:      reaction.ReactionKey,
		DBMetadata: reactionDBMetadata(reaction.ID, reaction.ReactionKey),
	}
}

func reactionDBMetadata(reactionID, reactionKey string) *imessageid.ReactionMetadata {
	return &imessageid.ReactionMetadata{
		ReactionID:  reactionID,
		ReactionKey: reactionKey,
	}
}

func splitStandardIMessageReactionID(reactionID string) (senderID networkid.UserID, reactionKey string) {
	for _, key := range standardIMessageReactionKeys {
		if strings.HasSuffix(reactionID, key) && len(reactionID) > len(key) {
			return imessageid.MakeUserID(strings.TrimSuffix(reactionID, key)), key
		}
	}
	return "", ""
}

func (c *Client) reactionSenderAndKey(ctx context.Context, targetMessageID networkid.MessageID, reactionID string) (networkid.UserID, string) {
	if c.Main != nil && c.Main.Bridge != nil && c.Main.Bridge.DB != nil && c.Main.Bridge.DB.Reaction != nil {
		reactions, err := c.Main.Bridge.DB.Reaction.GetAllToMessage(ctx, receiver(c.UserLogin), targetMessageID)
		if err == nil {
			for _, reaction := range reactions {
				if reaction.EmojiID != networkid.EmojiID(reactionID) {
					continue
				}
				reactionKey := reaction.Emoji
				if meta, ok := reaction.Metadata.(*imessageid.ReactionMetadata); ok && meta.ReactionKey != "" {
					reactionKey = meta.ReactionKey
				}
				return reaction.SenderID, reactionKey
			}
		}
	}
	return splitStandardIMessageReactionID(reactionID)
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
		c.queueThreadReadState(thread)
		c.UserLogin.QueueRemoteEvent(&simplevent.ChatResync{
			EventMeta: c.baseEventMeta(thread.ID).WithType(bridgev2.RemoteEventChatResync),
			ChatInfo:  c.chatInfoFromThread(thread),
		})
	}
	return nil
}

func (c *Client) queueThreadReadState(thread imessage.Thread) {
	unread := thread.IsUnread
	if thread.IsMarkedUnread != nil {
		unread = *thread.IsMarkedUnread
	}
	c.UserLogin.QueueRemoteEvent(&simplevent.MarkUnread{
		EventMeta: c.baseEventMeta(thread.ID).WithType(bridgev2.RemoteEventMarkUnread),
		Unread:    unread,
	})
	if thread.LastReadMessageID != "" && !unread {
		readUpTo := messageTimestamp(imessage.Message{Timestamp: thread.Timestamp})
		if thread.LastReadMessageSortKey > 0 {
			readUpTo = messageTimestamp(imessage.Message{Timestamp: thread.LastReadMessageSortKey})
		}
		c.UserLogin.QueueRemoteEvent(&simplevent.Receipt{
			EventMeta:  c.baseEventMeta(thread.ID).WithType(bridgev2.RemoteEventReadReceipt),
			LastTarget: imessageid.MakeMessageID(thread.LastReadMessageID),
			Targets:    []networkid.MessageID{imessageid.MakeMessageID(thread.LastReadMessageID)},
			ReadUpTo:   readUpTo,
		})
	}
}

func (c *Client) queueMessageActionChange(ctx context.Context, message imessage.Message) {
	if message.Action == nil || message.ThreadID == "" {
		return
	}
	if message.Action.Type == "thread_img_changed" {
		c.queueThreadResync(ctx, message.ThreadID)
		return
	}
	change := c.chatInfoChangeFromAction(*message.Action)
	if change == nil {
		return
	}
	c.UserLogin.QueueRemoteEvent(&simplevent.ChatInfoChange{
		EventMeta:      c.eventMeta(message.ThreadID, message).WithType(bridgev2.RemoteEventChatInfoChange),
		ChatInfoChange: change,
	})
}

func (c *Client) chatInfoChangeFromAction(action imessage.MessageAction) *bridgev2.ChatInfoChange {
	switch action.Type {
	case "thread_title_updated", "group_thread_created":
		return &bridgev2.ChatInfoChange{
			ChatInfo: &bridgev2.ChatInfo{Name: &action.Title},
		}
	case "thread_participants_added", "thread_participants_removed":
		membership := event.MembershipJoin
		prevMembership := event.MembershipLeave
		if action.Type == "thread_participants_removed" {
			membership = event.MembershipLeave
			prevMembership = event.MembershipJoin
		}
		members := bridgev2.ChatMemberMap{}
		participants := map[string]imessage.User{}
		for _, participant := range action.Participants {
			participants[participant.ID] = participant
		}
		for _, participantID := range action.ParticipantIDs {
			if participantID == "" {
				continue
			}
			user := participants[participantID]
			if user.ID == "" {
				user = imessage.User{ID: participantID, Username: participantID}
			}
			userID := imessageid.MakeUserID(participantID)
			members.Set(bridgev2.ChatMember{
				EventSender:    bridgev2.EventSender{Sender: userID},
				Membership:     membership,
				PrevMembership: prevMembership,
				UserInfo:       c.userInfoFromUser(user),
				MemberSender:   bridgev2.EventSender{Sender: imessageid.MakeUserID(action.ActorParticipantID)},
			})
		}
		if len(members) == 0 {
			return nil
		}
		return &bridgev2.ChatInfoChange{
			MemberChanges: &bridgev2.ChatMemberList{MemberMap: members},
		}
	default:
		return nil
	}
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
